import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import EnviousWisprStorage
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprPipeline

/// Unit tests for `TranscriptWorkflowCoordinator` (PR6 of epic #763).
///
/// Scope is narrow on purpose. `TranscriptPolishService` constructs
/// `LLMPolishStep` internally and the real polish flow needs a configured
/// LLM provider; success-path validation is Live UAT territory (see plan
/// §11.1). These tests cover what is unit-reachable:
///
/// 1. TWC initializes with the two required references.
/// 2. Fresh TPS state pass-throughs return nil.
/// 3. When TPS throws (no LLM provider configured), TWC's `polishTranscript`
///    fails closed: no transcript mutation, no selection change, no crash.
///    The catch block's `AppLogger.shared.log` call is exercised but its
///    parity (verbatim message + category) is asserted at code-review time
///    against `Sources/EnviousWisprAppKit/App/the former root-state file` not by an
///    AppLogger sink seam (the seam would require a refactor outside PR6
///    scope; Codex grounded review accepted the narrowing).
@MainActor
@Suite("TranscriptWorkflowCoordinator")
struct TranscriptWorkflowCoordinatorTests {

  @Test("init wires both references; fresh-TPS pass-throughs are nil")
  func initialStatePassThroughs() async throws {
    let twc = makeCoordinator()
    #expect(twc.lastEnhancementError == nil)
    #expect(twc.polishingTranscriptID == nil)
  }

  @Test("polishTranscript on disabled-polish TPS fails closed: TC untouched")
  func polishWithDisabledServiceLeavesTranscriptsUntouched() async throws {
    let twc = makeCoordinator()
    let originalTranscript = Transcript(
      text: "hello world",
      duration: 1.0,
      backendType: .parakeet
    )
    twc.transcriptCoordinator.transcripts = [originalTranscript]
    twc.transcriptCoordinator.selectedTranscriptID = originalTranscript.id
    let priorIDs = twc.transcriptCoordinator.transcripts.map(\.id)
    let priorTexts = twc.transcriptCoordinator.transcripts.map(\.text)
    let priorSelection = twc.transcriptCoordinator.selectedTranscriptID

    // No LLM provider is configured, so TPS throws `LLMError.providerUnavailable`.
    // TWC's catch block swallows the error and logs via AppLogger.shared. The
    // logger Task is fire-and-forget; we do not await it. The contract this
    // test enforces: TC array + selection are NOT mutated on failure.
    await twc.polishTranscript(originalTranscript)

    #expect(twc.transcriptCoordinator.transcripts.map(\.id) == priorIDs)
    #expect(twc.transcriptCoordinator.transcripts.map(\.text) == priorTexts)
    #expect(twc.transcriptCoordinator.selectedTranscriptID == priorSelection)
    // lastEnhancementError state is not asserted here: TPS only sets it on
    // *runtime* polish errors (LLMPolishStep failure), not on the early-exit
    // `providerUnavailable` throw. That branch is exercised by Live UAT with
    // a configured provider that's then forced to fail.
  }

  // MARK: - Fixture

  private func makeCoordinator() -> TranscriptWorkflowCoordinator {
    let transcriptStore = TranscriptStore()
    let keychain = KeychainManager()
    let polishService = TranscriptPolishService(
      keychainManager: keychain,
      transcriptStore: transcriptStore
    )
    let transcriptCoordinator = TranscriptCoordinator(store: transcriptStore)
    return TranscriptWorkflowCoordinator(
      transcriptCoordinator: transcriptCoordinator,
      polishService: polishService
    )
  }
}
