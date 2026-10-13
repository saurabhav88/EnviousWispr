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
    private func makeEndpoint(
      action: @escaping (DebugFaultEndpoint.QualificationAction) -> Void = { _ in },
      child: (@MainActor () async -> EGOneServerManager.QualificationChildSignal?)? = nil
    ) -> DebugFaultEndpoint {
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
        activeBackend: { .parakeet }, qualificationAction: action, qualificationChildTrap: child)
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

    @Test func ownedChildSignalDispatchesOnceWithFixedFacts() async {
      var calls = 0
      let endpoint = makeEndpoint(child: {
        calls += 1
        return EGOneServerManager.QualificationChildSignal(pid: 4242, generation: 7)
      })
      let request = await endpoint.qualificationRequestForTesting(
        command: "qualification_child_trap")
      #expect(
        request.reply
          == "OK qualification_child_signal pid=4242 generation=7 role=local_polish_server")
      #expect(request.armID == nil)
      #expect(calls == 1)
    }

    @Test func ownedChildMissingDependencyAndRefusalAreDistinct() async {
      let absent = makeEndpoint()
      #expect(
        await absent.handleForTesting(command: "qualification_child_trap") == "ERR no_dependency")
      var calls = 0
      let refused = makeEndpoint(child: {
        calls += 1
        return nil
      })
      #expect(
        await refused.handleForTesting(command: "qualification_child_trap")
          == "ERR no_owned_ready_process")
      #expect(calls == 1)
    }

    @Test func ownedChildUnauthenticatedAndUnknownRequestsCannotDispatch() async {
      var calls = 0
      let endpoint = makeEndpoint(child: {
        calls += 1
        return EGOneServerManager.QualificationChildSignal(pid: 4242, generation: 7)
      })
      let unauthorized = await endpoint.qualificationRequestForTesting(
        command: "qualification_child_trap", authenticated: false)
      #expect(unauthorized.reply == "ERR auth")
      #expect(
        await endpoint.handleForTesting(command: "qualification_child_trap pid=99")
          == "ERR unknown_command")
      #expect(calls == 0)
      #expect(
        await endpoint.handleForTesting(command: "qualification_child_trap")
          == "OK qualification_child_signal pid=4242 generation=7 role=local_polish_server")
      #expect(calls == 1)
    }

    @Test func delayedChildReplyCannotClaimHostFatalArm() async throws {
      var actions: [DebugFaultEndpoint.QualificationAction] = []
      let signals = SignalPipelineLogger()
      var release: CheckedContinuation<Void, Never>?
      var finished = false
      var childResult: (reply: String, armID: UUID?)?
      var currentFact = EGOneServerManager.QualificationChildSignal(pid: 4242, generation: 7)
      let endpoint = makeEndpoint(
        action: { actions.append($0) },
        child: {
          guard finished == false else { return nil }
          let observed = currentFact
          await withCheckedContinuation { continuation in
            release = continuation
            // Publish the releasable gate before announcing entry.
            Task { @MainActor in
              await signals.log("child entered", level: .info, category: "Qualification")
            }
          }
          return observed
        })
      let childTask = Task { @MainActor in
        guard Task.isCancelled == false else { return }
        childResult = await endpoint.qualificationRequestForTesting(
          command: "qualification_child_trap")
        // Completion belongs to the actual subject, not the injected stub.
        await signals.log("child completed", level: .info, category: "Qualification")
      }
      defer {
        finished = true
        let pending = release
        release = nil
        pending?.resume()
        childTask.cancel()
      }
      _ = try await signals.waitForEntry(matching: { $0.message == "child entered" })
      let continuation = try #require(release)
      let host = await endpoint.qualificationRequestForTesting(command: "qualification_trap")
      #expect(host.reply == "OK qualification_armed")
      #expect(host.armID != nil)
      currentFact = EGOneServerManager.QualificationChildSignal(pid: 4343, generation: 8)
      release = nil
      continuation.resume()
      _ = try await signals.waitForEntry(matching: { $0.message == "child completed" })
      let child = try #require(childResult)
      #expect(
        child.reply
          == "OK qualification_child_signal pid=4242 generation=7 role=local_polish_server")
      #expect(child.armID == nil)
      endpoint.completeQualificationReply(id: child.armID, succeeded: true)
      #expect(actions.isEmpty)
      endpoint.completeQualificationReply(id: host.armID, succeeded: true)
      #expect(actions == [.trap])
    }

    @Test func missingChildEntryDeadlineFailsFast() async {
      let signals = SignalPipelineLogger()
      do {
        // test-fixture-timer: exercise the existing waiter's no-signal deadline.
        _ = try await signals.waitForEntry(
          matching: { $0.message == "never sent" }, timeout: .milliseconds(10))
        Issue.record("A missing child entry unexpectedly satisfied the waiter")
      } catch {
        #expect(error is TimeoutError)
      }
    }

  }
#endif
