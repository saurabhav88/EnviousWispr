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
      "Sources/EnviousWispr/App/DictationSessionConfigFactory.swift")

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

    #expect(body.contains("dictationInvoked(triggerSource, inputMode, targetApp)"))
    // #723: trigger_source and input_mode are distinct schema slots; sink
    // must read them from distinct config fields.
    #expect(body.contains("context.config?.triggerSource.rawValue"))
    #expect(body.contains("context.config?.inputMode.rawValue"))
    #expect(body.contains("context.targetApp?.localizedName"))
  }

  @Test("WhisperKit emits dictation.invoked after capture enters recording")
  func whisperKitPipelineEmitsAfterRecordingStarts() throws {
    let source = try Self.read("Sources/EnviousWisprPipeline/WhisperKitPipeline.swift")
    let body = try Self.slice(
      source,
      from: "public func startRecording(config: DictationSessionConfig) async {",
      to: "public func requestStop() async {"
    )

    let stateIndex = try Self.require("state = .recording", in: body)
    let telemetryIndex = try Self.require("TelemetryService.shared.dictationInvoked(", in: body)

    #expect(stateIndex < telemetryIndex)
    // #723: trigger_source and input_mode are distinct schema slots; pipeline
    // must read them from distinct config fields.
    #expect(body.contains("triggerSource: config.triggerSource.rawValue"))
    #expect(body.contains("inputMode: config.inputMode.rawValue"))
    #expect(body.contains("targetApp: targetApp?.localizedName"))
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
