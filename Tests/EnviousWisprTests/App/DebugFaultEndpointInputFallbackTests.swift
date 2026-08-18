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

// #1714 — freezes the two DEBUG commands the Live UAT drives.
//
// These are the only way the fallback branch can be reached on a real build, so
// the exact command strings, the boolean each one passes, and all three replies
// are frozen here. A typo in a command string would otherwise surface as a
// confusing UAT failure hours later, on a rebuilt app, with no obvious cause.
//
// Hardware-free: the endpoint is driven through its own handler seam, no socket
// and no real device.
#if DEBUG

  @MainActor
  @Suite("DebugFaultEndpoint input-fallback commands — #1714")
  struct DebugFaultEndpointInputFallbackTests {

    /// An explicit decision, so construction is exercised without
    /// `CaptureRouteResolver.resolve()` reading live output hardware.
    private static func decision() -> CaptureRouteDecision {
      CaptureRouteDecision(
        sourceType: .halDeviceInput, reason: .noBTAutoInput, rationale: "test")
    }

    private func makeEndpoint(audioCapture: AudioCaptureManager?) -> DebugFaultEndpoint {
      let clock = FakeClock()
      let engine = FakeEngine(behavior: .batchSuccess(text: "x"), clock: clock)
      let steps = LimbSteps(
        wordCorrection: WordCorrectionStep(),
        fillerRemoval: FillerRemovalStep(),
        emojiFormatter: EmojiFormatterStep(),
        inverseTextNormalization: InverseTextNormalizationStep(),
        llmPolish: LLMPolishStep(keychainManager: KeychainManager()),
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
        audioCapture: audioCapture,
        asrProxy: nil,
        kernelDriver: makeDriver(),
        whisperKitKernelDriver: makeDriver(),
        activeBackend: { .parakeet })
    }

    // MARK: - The happy path, both directions

    @Test("force_default_input_absent arms the manager and replies OK")
    func forceCommandArms() async {
      let manager = AudioCaptureManager()
      let endpoint = makeEndpoint(audioCapture: manager)

      let reply = await endpoint.handleForTesting(command: "force_default_input_absent")

      #expect(reply == "OK")
      // Observed by effect through the real construction authority, not by
      // peeking at a stored closure.
      let source = manager.buildSourceForTesting(Self.decision()) as? HALDeviceInputSource
      #expect(source?.inputDeviceResolver.defaultInputDeviceID() == nil)
    }

    @Test("clear_default_input_absent disarms the manager and replies OK")
    func clearCommandDisarms() async {
      let manager = AudioCaptureManager()
      let endpoint = makeEndpoint(audioCapture: manager)
      #expect(await endpoint.handleForTesting(command: "force_default_input_absent") == "OK")

      let reply = await endpoint.handleForTesting(command: "clear_default_input_absent")

      #expect(reply == "OK")
      // Disarmed: the manager builds its ordinary source again.
      let source = manager.buildSourceForTesting(Self.decision()) as? HALDeviceInputSource
      #expect(source != nil)
    }

    // MARK: - Refusals

    @Test("both commands refuse while capture is active")
    func bothRefuseDuringCapture() async {
      let manager = AudioCaptureManager()
      let endpoint = makeEndpoint(audioCapture: manager)
      manager.isCapturing = true

      #expect(
        await endpoint.handleForTesting(command: "force_default_input_absent")
          == "ERR capture_active")
      #expect(
        await endpoint.handleForTesting(command: "clear_default_input_absent")
          == "ERR capture_active")
    }

    @Test("both commands report a missing manager rather than silently succeeding")
    func bothReportMissingDependency() async {
      let endpoint = makeEndpoint(audioCapture: nil)

      #expect(
        await endpoint.handleForTesting(command: "force_default_input_absent")
          == "ERR no_dependency")
      #expect(
        await endpoint.handleForTesting(command: "clear_default_input_absent")
          == "ERR no_dependency")
    }

    // MARK: - The command strings themselves

    @Test("the exact command strings are frozen")
    func commandStringsFrozen() async {
      // A typo here surfaces hours later as a confusing UAT failure on a
      // rebuilt app, so the literals are pinned rather than inferred.
      let endpoint = makeEndpoint(audioCapture: AudioCaptureManager())

      #expect(await endpoint.handleForTesting(command: "force_default_input_absent") == "OK")
      #expect(await endpoint.handleForTesting(command: "clear_default_input_absent") == "OK")
      // Near-misses must NOT route.
      #expect(await endpoint.handleForTesting(command: "force_default_input") != "OK")
      #expect(await endpoint.handleForTesting(command: "default_input_absent") != "OK")
    }

    @Test("an unknown command does not reach the arming seam")
    func unknownCommandDoesNotArm() async {
      // The previous version asserted a tautology against live hardware. The
      // dispatcher's own reply is the real evidence.
      let endpoint = makeEndpoint(audioCapture: AudioCaptureManager())

      let reply = await endpoint.handleForTesting(command: "force_default_input_absent_typo")

      #expect(reply == "ERR unknown_command")
    }
  }

#endif
