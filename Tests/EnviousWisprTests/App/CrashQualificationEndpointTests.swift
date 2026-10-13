import AppKit
import EnviousWisprCore
import EnviousWisprLLM
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit
@testable import EnviousWisprAudio
@testable import EnviousWisprPipeline

#if DEBUG
  @MainActor
  @Suite("Crash qualification endpoint", .tags(.harnessContract))
  struct CrashQualificationEndpointTests {
    private func makeEndpoint(action: @escaping (DebugFaultEndpoint.QualificationAction) -> Void)
      -> DebugFaultEndpoint
    {
      let clock = FakeClock()
      let engine = FakeEngine(behavior: .batchSuccess(text: "x"), clock: clock)
      let steps = LimbSteps(
        snippetExpansion: SnippetExpansionStep(),
        wordCorrection: WordCorrectionStep(),
        learnedWordCheck: LearnedWordCheckStep(),
        fillerRemoval: FillerRemovalStep(),
        emojiFormatter: EmojiFormatterStep(),
        inverseTextNormalization: InverseTextNormalizationStep(),
        englishSpelling: EnglishSpellingStep(target: .text),
        llmPolish: LLMPolishStep(keychainManager: KeychainManager()),
        englishSpellingAfterPolish: EnglishSpellingStep(target: .polishedText),
        emojiRestore: EmojiRestoreStep())
      func makeDriver() -> KernelDictationDriver {
        let kernel = RecordingSessionKernel(
          adapter: engine,
          audioCapture: FakeAudioCapture(),
          vad: FakeVADSignalSource(),
          currentTick: { 0 }, sleepTicks: { _ in },
          processText: { raw, _ in raw },
          store: { _, _, _ in }, deliver: { _, _ in .pasted },
          engineMutationScope: .alwaysAllowedForTesting,
          minimumRecordingTicks: 0)
        let observer = KernelHeartPathTelemetryObserver(
          kernel: kernel, audioCapture: FakeAudioCapture(),
          emitter: HeartPathTelemetryEmitter(
            backend: .parakeet, captureTelemetry: CaptureTelemetryState()),
          emitLifecycleEvent: { _ in })
        return KernelDictationDriver(
          kernel: kernel, observer: observer,
          outcome: KernelFinalizationOutcome(), context: KernelSessionContext(),
          steps: steps, adapter: engine,
          engineMutationScope: .alwaysAllowedForTesting)
      }
      return DebugFaultEndpoint(
        audioCapture: nil,
        kernelDriver: makeDriver(),
        whisperKitKernelDriver: makeDriver(),
        activeBackend: { .parakeet }, qualificationAction: action)
    }

    @Test(arguments: ["qualification_trap", "qualification_abort"])
    func actionWaitsForSuccessfulReply(command: String) async {
      var actions: [DebugFaultEndpoint.QualificationAction] = []
      let endpoint = makeEndpoint { actions.append($0) }
      let request = await endpoint.qualificationRequestForTesting(command: command)
      #expect(request.reply == "OK qualification_armed")
      #expect(request.armID != nil)
      #expect(actions.isEmpty)
      endpoint.completeQualificationReply(id: request.armID, succeeded: true)
      #expect(actions == [command == "qualification_trap" ? .trap : .abort])
      endpoint.completeQualificationReply(id: request.armID, succeeded: true)
      #expect(actions.count == 1)
      #expect(
        await endpoint.handleForTesting(command: command) == "ERR qualification_already_armed")
    }

    @Test func failedReplyCancelsOnlyItsArm() async {
      var actions: [DebugFaultEndpoint.QualificationAction] = []
      let endpoint = makeEndpoint { actions.append($0) }
      let first = await endpoint.qualificationRequestForTesting(command: "qualification_trap")
      endpoint.completeQualificationReply(id: first.armID, succeeded: false)
      #expect(actions.isEmpty)
      let second = await endpoint.qualificationRequestForTesting(command: "qualification_abort")
      #expect(second.reply == "OK qualification_armed")
      #expect(second.armID != first.armID)
      endpoint.completeQualificationReply(id: first.armID, succeeded: true)
      #expect(actions.isEmpty)
      endpoint.completeQualificationReply(id: second.armID, succeeded: true)
      #expect(actions == [.abort])
    }

    @Test func rejectedRequestsCannotStealPendingAction() async {
      var actions: [DebugFaultEndpoint.QualificationAction] = []
      let endpoint = makeEndpoint { actions.append($0) }
      let first = await endpoint.qualificationRequestForTesting(command: "qualification_trap")
      let duplicate = await endpoint.qualificationRequestForTesting(command: "qualification_abort")
      let unknown = await endpoint.qualificationRequestForTesting(command: "qualification_typo")
      let unauthenticated = await endpoint.qualificationRequestForTesting(
        command: "qualification_abort", authenticated: false)
      #expect(duplicate.reply == "ERR qualification_already_armed")
      #expect(unknown.reply == "ERR unknown_command")
      #expect(unauthenticated.reply == "ERR auth")
      for rejected in [duplicate, unknown, unauthenticated] {
        #expect(rejected.armID == nil)
        endpoint.completeQualificationReply(id: rejected.armID, succeeded: false)
      }
      #expect(actions.isEmpty)
      endpoint.completeQualificationReply(id: first.armID, succeeded: true)
      #expect(actions == [.trap])
    }

    @Test func unauthenticatedAndUnknownRequestsCannotArm() async {
      var actions: [DebugFaultEndpoint.QualificationAction] = []
      let endpoint = makeEndpoint { actions.append($0) }
      let wrongToken = await endpoint.qualificationRequestForTesting(
        command: "qualification_trap", authenticated: false)
      let unknown = await endpoint.qualificationRequestForTesting(command: "qualification_trapp")
      #expect(wrongToken.reply == "ERR auth")
      #expect(unknown.reply == "ERR unknown_command")
      #expect(wrongToken.armID == nil)
      #expect(unknown.armID == nil)
      endpoint.completeQualificationReply(id: wrongToken.armID, succeeded: true)
      endpoint.completeQualificationReply(id: unknown.armID, succeeded: true)
      #expect(actions.isEmpty)
    }

    @Test func stopCancelsPendingReply() async {
      var actions: [DebugFaultEndpoint.QualificationAction] = []
      let endpoint = makeEndpoint { actions.append($0) }
      let request = await endpoint.qualificationRequestForTesting(command: "qualification_trap")
      #expect(request.reply == "OK qualification_armed")
      #expect(request.armID != nil)
      #expect(actions.isEmpty)
      endpoint.stop()
      endpoint.completeQualificationReply(id: request.armID, succeeded: true)
      #expect(actions.isEmpty)
    }
  }
#endif
