import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline
@testable import EnviousWisprStorage

/// #1022: manual Enhance on a too-short transcript hits the same quality gate
/// as live polish (the gate exists because LLMs answer 1-3 word inputs instead
/// of cleaning them). The service must surface that bypass — record a
/// plain-English enhancement error and throw — instead of saving a raw copy
/// stamped as polished (llm-contract: "Re-polish must surface live
/// silent-skips, or transcripts get mislabeled as polished").
@MainActor
@Suite("TranscriptPolishService bypass surfacing")
struct TranscriptPolishServiceBypassTests {

  @MainActor
  private final class IdleDictationActivity: DictationActivityProviding {
    var isDictationActive: Bool { false }
  }

  /// A polisher that fails the test if the gate ever lets a short input through.
  private struct ForbiddenPolisher: TranscriptPolisher {
    func polish(
      text: String,
      instructions: PolishInstructions,
      config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      Issue.record("polisher must not be invoked for a too-short transcript")
      return LLMResult(polishedText: "should never happen")
    }
  }

  private func makeTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("tps-bypass-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  @Test(
    "Enhance on a 2-word transcript: throws, records a too-short message, saves nothing",
    .bug(
      "https://github.com/saurabhav88/EnviousWispr/issues/1022",
      "manual Enhance would save a raw copy stamped as polished"
    )
  )
  func enhanceOnShortTranscriptSurfacesBypass() async throws {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TranscriptStore(directory: dir)
    let activity = IdleDictationActivity()
    let service = TranscriptPolishService(
      keychainManager: KeychainManager(),
      transcriptStore: store,
      dictationActivity: activity
    )
    service.llmPolishStep.llmProvider = .openAI
    service.llmPolishStep.llmModel = "gpt-4o-mini"
    service.llmPolishStep.makePolisher = { _, _, _ in ForbiddenPolisher() }

    let transcript = Transcript(text: "Other apps.", language: "en")
    try store.save(transcript)

    await #expect(throws: LLMError.self) {
      _ = try await service.polish(transcript)
    }

    let message = try #require(service.lastEnhancementError?.message)
    #expect(message.localizedCaseInsensitiveContains("too short"))
    #expect(service.lastEnhancementError?.transcriptID == transcript.id)
    #expect(service.polishingTranscriptID == nil, "in-flight guard resets via defer")

    // The persisted transcript is untouched: no fake polished copy, no stamp.
    let onDisk = try await store.loadAll()
    let reloaded = try #require(onDisk.first { $0.id == transcript.id })
    #expect(reloaded.polishedText == nil)
    #expect(reloaded.llmProvider == nil)
    #expect(reloaded.llmModel == nil)
  }

  /// #1055: throws the too-long-for-on-device signal so the service's HONEST
  /// "too long" path is exercised instead of the misleading "too short" message
  /// the nil-output guard would otherwise show.
  private struct ContextWindowThrowingPolisher: TranscriptPolisher {
    func polish(
      text: String,
      instructions: PolishInstructions,
      config: LLMProviderConfig,
      onToken: (@Sendable (String) -> Void)?
    ) async throws -> LLMResult {
      throw AFMContextWindowExceeded(stage: .predicted)
    }
  }

  @Test("Re-polish a too-long transcript: honest 'too long' message, not 'too short'")
  func enhanceOnTooLongSurfacesContextWindow() async throws {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TranscriptStore(directory: dir)
    let activity = IdleDictationActivity()
    let service = TranscriptPolishService(
      keychainManager: KeychainManager(),
      transcriptStore: store,
      dictationActivity: activity
    )
    service.llmPolishStep.llmProvider = .openAI
    service.llmPolishStep.llmModel = "gpt-4o-mini"
    service.llmPolishStep.makePolisher = { _, _, _ in ContextWindowThrowingPolisher() }

    // Long enough to clear the too-short gate and reach the polisher.
    let transcript = Transcript(
      text:
        "this is a sufficiently long dictation that clears the short-input gate and reaches the polisher",
      language: "en")
    try store.save(transcript)

    await #expect(throws: LLMError.self) {
      _ = try await service.polish(transcript)
    }

    let message = try #require(service.lastEnhancementError?.message)
    #expect(message.localizedCaseInsensitiveContains("too long"))
    #expect(!message.localizedCaseInsensitiveContains("too short"))
    #expect(service.lastEnhancementError?.transcriptID == transcript.id)

    // Persisted transcript untouched — no fake polished copy stamped as polished.
    let onDisk = try await store.loadAll()
    let reloaded = try #require(onDisk.first { $0.id == transcript.id })
    #expect(reloaded.polishedText == nil)
  }
}
