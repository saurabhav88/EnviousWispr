import Foundation
import Testing

struct DictationInvokedPipelineWiringTests {
  @Test("session config carries input mode into pipeline start")
  func sessionConfigCarriesInputMode() throws {
    let configSource = try Self.read("Sources/EnviousWisprCore/DictationSessionConfig.swift")
    // Per epic #763 PR5: the per-recording config snapshot moved into
    // DictationSessionConfigFactory. The factory now owns the
    // `inputMode: settings.recordingMode` plumbing.
    let factorySource = try Self.read(
      "Sources/EnviousWisprAppKit/App/DictationSessionConfigFactory.swift")

    #expect(configSource.contains("public let inputMode: RecordingMode"))
    #expect(factorySource.contains("inputMode: settings.recordingMode"))
  }

  @Test("Parakeet (kernel sink) emits dictation.invoked from recordingCommitted")
  func parakeetPipelineEmitsAfterRecordingStarts() throws {
    // PR-4b.4: Parakeet's dictation.invoked emit moved out of the deleted
    // Parakeet pipeline.swift into `KernelLifecycleTelemetrySink.swift`,
    // case `.recordingCommitted`. The kernel emits `.recordingCommitted` AFTER
    // the FSM transitions to `.recording` — that ordering is covered by
    // `RecordingSessionKernelScenarioTests`. This test verifies the sink
    // pulls trigger / mode / target from the per-session config and forwards
    // them via the `dictationInvoked` sink (default closure -> TelemetryService).
    let source = try Self.read(
      "Sources/EnviousWisprPipeline/KernelLifecycleTelemetrySink.swift")
    let body = try Self.slice(
      source,
      from: "case .recordingCommitted(let isStreaming):",
      to: "case .recordingStopped"
    )

    // #1846 added the take key as a fourth argument. Frozen with the key included
    // rather than loosened to a prefix match: the point of this assertion is that
    // the sink forwards EXACTLY these values, and a prefix match would stop
    // noticing if a later change dropped an argument.
    #expect(
      body.contains("dictationInvoked(triggerSource, inputMode, targetApp, telemetryState.takeID)")
    )
    // #723: trigger_source and input_mode are distinct schema slots; sink
    // must read them from distinct config fields.
    #expect(body.contains("context.config?.triggerSource.rawValue"))
    #expect(body.contains("context.config?.inputMode.rawValue"))
    #expect(body.contains("context.targetApp?.localizedName"))
  }

  /// #1846: the BRIDGE between two things that are each tested and neither of which
  /// covers the line joining them. `RecordingSessionKernelTests` proves the kernel
  /// freezes `lastTakeID`; `DictationCompletedRouteFieldsTests` proves a supplied
  /// `takeID` reaches all four completion events. Delete `takeID: driver.lastTakeID`
  /// and BOTH stay green while production emits no completion take keys at all —
  /// `a-guard-nothing-arms-is-not-a-guard`.
  ///
  /// Asserted by a narrow source scan because this is a pure forwarding bridge
  /// between two independently behaviour-tested endpoints. Unit tests can construct
  /// a driver, but driving full finalization here would duplicate both endpoint tests
  /// without isolating this one removable expression. The scan proves only that the
  /// accessor and forwarding wiring remain present.
  @Test("completion reporting uses the kernel's frozen concluded take key")
  func completionReportingUsesFrozenConcludedTakeKey() throws {
    let driverSource = try Self.read(
      "Sources/EnviousWisprPipeline/KernelDictationDriver.swift")
    let accessor = try Self.slice(
      driverSource,
      from: "public var lastStopReason",
      to: "public var lastRecordingDurationSeconds"
    )
    #expect(
      accessor.contains("public var lastTakeID: String? { kernel.lastTakeID }"),
      "the driver must expose the kernel's frozen concluded key, never the live in-flight key"
    )

    let reportingSource = try Self.read(
      "Sources/EnviousWisprAppKit/App/DictationRuntime/DictationCompletedReporting.swift")
    let reportCall = try Self.slice(
      reportingSource,
      from: "TelemetryService.shared.reportDictationCompleted(",
      to: "\n  }\n\n  private static func positive"
    )
    #expect(
      reportCall.contains("takeID: driver.lastTakeID)"),
      "the App completion bridge must forward the concluded key into the four-event fan-out"
    )
  }

  // PR-5 Rung 5 (#827) rewrite: WhisperKit now flows through the same kernel
  // sink as Parakeet — `parakeetPipelineEmitsAfterRecordingStarts` above
  // covers the shared dictation.invoked path for both engines. The legacy
  // WhisperKit-specific assertion (which read the deleted
  // `WhisperKitPipeline.startRecording(config:)` body) is replaced by two
  // engine-agnostic guards: (1) the factory's WhisperKit branch has exactly
  // one production caller, locked by
  // `EngineIdentityFreezeTests.makeForWhisperKitHasExactlyOneProductionCaller`;
  // (2) the constructed driver carries WhisperKit engine identity, locked by
  // `KernelDictationDriverFactoryWhisperKitTests
  // .makeForWhisperKitReturnsDriverWithWhisperKitIdentity`.

  /// #1846 chunk 7: the SECOND production bridge, written proactively because chunk 6
  /// shipped without its equivalent and the reviewer had to find it.
  ///
  /// `TextProcessingRunnerCaptureTests` proves the runner freezes a supplied key into
  /// the context and that both polish outcome events carry it. Nothing else covers the
  /// one expression that supplies it in production. Delete `takeID: telemetryState.takeID`
  /// and every polish test stays green while `llm.polish_failed` and
  /// `llm.polish_skipped` ship with no take key at all.
  ///
  /// It also freezes WHICH key: the live in-flight one. Polish runs before the session
  /// terminal, so `lastTakeID` is not yet stamped for this take — swapping in the
  /// concluded key here would silently label every polish event with the PREVIOUS
  /// dictation, or with nothing.
  @Test("live polish reporting uses the in-flight take key, not the concluded one")
  func polishReportingUsesInFlightTakeKey() throws {
    let wiringSource = try Self.read(
      "Sources/EnviousWisprPipeline/KernelFinalizationWiring.swift")
    let runCall = try Self.slice(
      wiringSource,
      from: "let result = try await textProcessingRunner.run(",
      to: "let ctx = result.context"
    )
    #expect(
      runCall.contains("takeID: telemetryState.takeID)"),
      "the live finalization path must supply the in-flight take key to the polish chain"
    )

    // The negative check runs over CODE ONLY. Its first version scanned the whole
    // slice and failed on the explanatory comment right above the argument, which
    // legitimately names `kernel.lastTakeID` to say why it is NOT used here. A
    // matcher that cannot tell an action from prose about the action is the
    // imprecise thing; the fix is the matcher, never rewording the comment to
    // appease it (`false-positives-not-gates-train-evasion`).
    let codeOnly =
      runCall
      .split(separator: "\n", omittingEmptySubsequences: false)
      .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
      .joined(separator: "\n")
    #expect(
      codeOnly.contains("lastTakeID") == false,
      """
      the concluded key is the WRONG one here — polish runs before the terminal that \
      stamps it, so this would label polish events with the previous dictation or nothing.
      """)
    // Prove the filter did not strip the line under test along with the comments.
    #expect(codeOnly.contains("takeID: telemetryState.takeID)"))
  }

  /// #1846 chunk 8: the dead-mic retire bridge. `HeartPathTelemetryEmitterTests`
  /// proves a supplied key reaches the payload; nothing else covers the expression
  /// that supplies it in production. Replace `telemetryState.takeID` with `nil` and
  /// that emitter test stays green while every real retire loses its take key.
  ///
  /// Also freezes WHICH key: live, not concluded. A retire fires mid-session, before
  /// any terminal stamps `lastTakeID`.
  @Test("dead mic retire supplies the in-flight take key from the kernel")
  func deadMicRetireSuppliesInFlightTakeKey() throws {
    let kernelSource = try Self.read(
      "Sources/EnviousWisprPipeline/RecordingSessionKernel.swift")
    let construction = try Self.slice(
      kernelSource,
      from: "DeadMicRetireAttemptContext(",
      to: "// Arm the recovery watch ONLY when teardown actually ran"
    )
    #expect(
      construction.contains("takeID: telemetryState.takeID))"),
      "the kernel must stamp the in-flight take key onto every dead-mic retire context"
    )

    // Code only — the comment above the argument names the concluded key to explain
    // why it is not used, and a matcher that cannot tell an action from prose about
    // it is the imprecise thing (`false-positives-not-gates-train-evasion`).
    let codeOnly =
      construction
      .split(separator: "\n", omittingEmptySubsequences: false)
      .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
      .joined(separator: "\n")
    #expect(codeOnly.contains("lastTakeID") == false)
    // Prove the filter did not strip the line under test along with the comments.
    #expect(codeOnly.contains("takeID: telemetryState.takeID))"))
  }

  private static func read(_ relativePath: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(contentsOf: root.appending(path: relativePath), encoding: .utf8)
  }

  private static func slice(_ source: String, from start: String, to end: String) throws -> String {
    guard let startRange = source.range(of: start) else {
      throw TestFailure("Missing start marker: \(start)")
    }
    guard let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex)
    else {
      throw TestFailure("Missing end marker: \(end)")
    }
    return String(source[startRange.lowerBound..<endRange.lowerBound])
  }

  @discardableResult
  private static func require(_ needle: String, in haystack: String) throws -> String.Index {
    guard let range = haystack.range(of: needle) else {
      throw TestFailure("Missing expected text: \(needle)")
    }
    return range.lowerBound
  }

  private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
      self.description = description
    }
  }
}
