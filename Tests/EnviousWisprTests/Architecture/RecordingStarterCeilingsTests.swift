import Foundation
import Testing

/// PR10 of #763 — locks `RecordingStarter`'s initial shape so the start-path
/// home does not silently accrete domain state. Owns `start()` (hotkey PTT
/// path: prewarm + dispatch + post-condition wedge guard) and
/// `toggle(source:)` (lighter UI/menu path: no prewarm).
///
/// Bible-changelog (ratchet history):
/// - PR10 (#776): baseline = 7 collaborators (audioCapture, asrManager,
///   pipeline, whisperKitKernelDriver, settings, permissions, recordingOverlay),
///   2 non-private methods (start, toggle — `isProcessing` is a `var` and
///   is NOT counted), ≤ 250 lines.
@Suite struct RecordingStarterCeilingsTests {
  private static let sourcePath =
    "Sources/EnviousWisprAppKit/App/DictationRuntime/RecordingStarter.swift"

  @Test func collaboratorCount() throws {
    let body = try RouterCeilingParser.classBody(
      named: "RecordingStarter", at: Self.sourcePath)
    let count = RouterCeilingParser.collaboratorCount(in: body)
    // #2068: this measures 6, not the 7 the PR10 baseline names. Two
    // corrections, and neither is a removed dependency. `permissions` is not a
    // stored property of this type and has not been one for some time, so the
    // allowed list was carrying a name the file does not have. And the seventh
    // slot was being occupied by `ensureSelectedReadyForPress`, an `async`
    // closure that the parser could not recognise as a closure and therefore
    // filed as a collaborator — fixed in `RouterCeilingParser.isClosureTyped`,
    // which moved it to `closureInjectedCount` below where it belongs.
    //
    // Cap deliberately left at 7 rather than ratcheted to 6: the two changes
    // above are a measurement correction, not a shrink anyone performed, and
    // tightening a cap on the back of a counter fix would fail the next PR for
    // a reason that has nothing to do with it. Ratchet when a real removal
    // lands.
    #expect(
      count <= 7,
      """
      RecordingStarter collaborator ceiling exceeded: \(count) > 7. \
      Allowed: audioCapture, asrManager, kernelDriver, whisperKitKernelDriver, \
      settings, recordingOverlay. Note the closure cap below — a dependency \
      added as a bare closure does not land here, which is the point of having \
      both. Raising the ceiling requires a Bible §30 entry.
      """)
  }

  /// #2068: the closure cap this home never had.
  ///
  /// `collaboratorCount` excludes closure-typed properties by construction, and
  /// this file's own comments name the workaround three times — ":35 A bare
  /// closure so it stays off this start-path home's collaborator count", and
  /// twice more as "Bare closure (off the collaborator cap)". A sibling counter
  /// exists and is asserted by six other ceiling tests; it was simply never
  /// applied to the home that documents using the hatch. Until now a dependency
  /// could be added here indefinitely, in the shape the code comments describe,
  /// and no gate would fire.
  ///
  /// **10 is a FREEZE, not a target.** It is the measured value on the day the
  /// assertion landed, set deliberately at the current count so this stops
  /// silent growth without becoming a refactor ticket. Whether this home should
  /// hold ten closures at all is a real question and explicitly not this one's;
  /// it is refactor-tier and belongs to a dedicated inspection pass. Ratchet
  /// DOWN freely if any are removed.
  ///
  /// Why 10 and not the 9 the issue estimated: 9 was a hand count of the source.
  /// The parser measured 8, and the gap was itself a defect — `async` closures
  /// matched neither the closure predicate nor the primitive one, so
  /// `makeRecoveryDirective` and `ensureSelectedReadyForPress` were counted as
  /// COLLABORATORS instead. Fixed in `RouterCeilingParser.isClosureTyped` in the
  /// same change, which is also why `collaboratorCount` above now measures 6
  /// rather than 7. The scoped-out homes, measured the same way: AppWindowCoord-
  /// inator 2, BulkImportEnrichmentCoordinator 2, AudioEventRouter 1,
  /// BackendMetadata 1, SparkleUpdateController 1, everything else 0 — the issue
  /// asked for assertions only where the hatch is genuinely in use, and a cap on
  /// a home holding one closure is noise.
  @Test func closureInjectedCount() throws {
    let body = try RouterCeilingParser.classBody(
      named: "RecordingStarter", at: Self.sourcePath)
    let count = RouterCeilingParser.closureInjectedCount(in: body)
    #expect(
      count <= 10,
      """
      RecordingStarter closure-injected-dependency ceiling exceeded: \(count) > 10. \
      This home's collaborator cap is bypassable with a bare closure and this is \
      the gate that notices. A new closure dependency is a real dependency: \
      justify it, or put it behind an existing seam. Raising this cap requires a \
      Bible §30 changelog entry, same as any other ceiling.
      """)
  }

  /// The gate that does not depend on getting the classification right.
  ///
  /// The two caps above split stored dependencies into bins, and the split is
  /// **syntactically undecidable**. `RouterCeilingParser` reads one file with no
  /// type resolution, so a closure behind a `typealias` is an
  /// `IdentifierTypeSyntax` and lands in `collaboratorCount`. That is not exotic
  /// here — it is the house style: `ProgressCallback`, `ShowOverlay`,
  /// `EvictOllamaModel`, `HostedPullStarter` and six more are function aliases
  /// in `Sources/`. A locally declared type shadowing `Optional` is undecidable
  /// the same way, and in the other direction.
  ///
  /// That makes the two caps individually bypassable whenever either has
  /// headroom. Measured when this landed: 6/7 collaborators and 10/10 closures,
  /// so `let progress: ProgressCallback` — a genuine eleventh closure seam —
  /// reads as the seventh collaborator, and BOTH caps pass. Found by cloud
  /// review on PR #2070, against the very cap #2068 added to stop this.
  ///
  /// The sum cannot be bypassed by moving a property between bins, because it
  /// does not care which bin the property is in. Resolving aliases would mean
  /// re-implementing type resolution on top of the parser, which is the
  /// approximation business this parser was rewritten to leave.
  ///
  /// 16 is a FREEZE at the measured 6 + 10, on the same terms as the caps above:
  /// it stops silent growth and is not a judgement that sixteen is right.
  /// Ratchet DOWN freely.
  @Test func totalStoredDependencyCount() throws {
    let body = try RouterCeilingParser.classBody(
      named: "RecordingStarter", at: Self.sourcePath)
    let collaborators = RouterCeilingParser.collaboratorCount(in: body)
    let closures = RouterCeilingParser.closureInjectedCount(in: body)
    let total = collaborators + closures
    #expect(
      total <= 16,
      """
      RecordingStarter total stored-dependency ceiling exceeded: \(total) > 16 \
      (\(collaborators) collaborators + \(closures) closures). This is the cap \
      that a `typealias` cannot walk around: whichever bin a new dependency \
      lands in, it lands here. If the two caps above still pass, that is the \
      bypass this exists to catch, not evidence the dependency is free. \
      Raising it requires a Bible §30 entry.
      """)
  }

  @Test func nonPrivateMethodCount() throws {
    let body = try RouterCeilingParser.classBody(
      named: "RecordingStarter", at: Self.sourcePath)
    let count = RouterCeilingParser.nonPrivateMethodCount(in: body)
    #expect(
      count <= 3,
      """
      RecordingStarter non-private method ceiling exceeded: \(count) > 3 \
      non-private `func` declarations. PR10 baseline: start, toggle. \
      #1925 added `shouldStampPostConditionWedge` — the postcondition's actual \
      decision, extracted as a pure `nonisolated static func` so the four-case \
      wedge-detection truth table is directly testable rather than requiring a \
      live driver/kernel; it must stay reachable from the test target, so it \
      cannot be `private`. `isProcessing` is a `var` (computed) and is not \
      counted.
      """)
  }

  @Test func noPolishServiceReference() throws {
    // Hard constraint from epic comment 4483335497 and migration plan §PR10.
    // PR11 owns the polish-service rehoming; PR10 must not introduce a
    // dependency on it. Filters comment lines so doc text that NAMES the
    // forbidden symbol (to explain the constraint) does not trigger.
    let source = try String(
      contentsOf: RepoRoot.sourceURL(Self.sourcePath), encoding: .utf8)
    let code = source.split(separator: "\n", omittingEmptySubsequences: false)
      .filter { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.hasPrefix("//")
      }
      .joined(separator: "\n")
      .lowercased()
    #expect(
      !code.contains("polishservice") && !code.contains("transcriptpolishservice"),
      """
      RecordingStarter must not reference polishService / TranscriptPolishService. \
      PR11 owns polish-service rehoming (epic comment 4483335497).
      """)
  }

  @Test func allowedImports() throws {
    let source = try String(
      contentsOf: RepoRoot.sourceURL(Self.sourcePath), encoding: .utf8)
    let actual = RouterCeilingParser.imports(in: source)
    let allowed: Set<String> = [
      "Foundation", "EnviousWisprASR", "EnviousWisprAudio", "EnviousWisprCore",
      "EnviousWisprPipeline", "EnviousWisprServices",
    ]
    let extras = actual.subtracting(allowed)
    #expect(
      extras.isEmpty,
      """
      RecordingStarter imports outside allowed set: \(extras.sorted()). \
      Allowed: \(allowed.sorted()).
      """)
  }
}
