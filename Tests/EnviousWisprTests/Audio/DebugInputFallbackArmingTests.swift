@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import Testing

@testable import EnviousWisprAudio
@testable import EnviousWisprCore

// #1714 — the DEBUG seam that lets Live UAT reach the list-fallback rung.
//
// Why a seam at all: on a machine with a working default microphone, resolution
// returns at the unchanged default rung and the new code never runs. A "normal
// dictation worked" UAT would report a pass having exercised the OLD path. This
// is the only way the acceptance check can reach its own subject.
//
// The two invariants that make it trustworthy, both of which fail silently:
//   - it must REFUSE while capture is active, so a live take is never disturbed;
//   - it must tear down any idle WARM source before acknowledging, because
//     `warmReuseBind` returns before resolution — an armed-but-warm source would
//     skip the branch and the UAT would pass having tested nothing.
//
// Hardware-free: every test drives the manager with stubs or inspects the
// factory's topology. Nothing opens a real device.
#if DEBUG

  @MainActor
  @Suite("DEBUG input-fallback arming — #1714")
  struct DebugInputFallbackArmingTests {

    /// An inert source. This suite is about what the MANAGER does around the
    /// factory, not about capture.
    private final class StubSource: AudioInputSource {
      var onSamples: (@Sendable ([Float], Float) -> Void)?
      var onBufferCaptured: (@Sendable (AVAudioPCMBuffer) -> Void)?
      var onInterrupted: ((EngineInterruptionCause) -> Void)?
      var onLifecycleSignal: (@Sendable (String) -> Void)?
      var onCaptureStalled: ((CaptureStallContext) -> Void)?
      var onInputResolutionAttemptFinalized: ((FinalizedInputResolutionAttempt) -> Void)?
      var captureGeneration: UInt64 = 0

      /// #1810: stubs drain no pre-roll. A stored var rather than a literal so a
      /// test can set a value — including a negative, to prove the clamp.
      var drainedPreRollSampleCount: Int = 0
      let captureSourceType = "stub"
      var isCapturing = false
      var isRunning = false
      private(set) var rebuildCount = 0
      #if DEBUG
        var debugZeroFillController: DebugZeroFillController?
        var wakeDiagnostic: (firstNonZeroRoutedIndex: Int?, routedCountAtActivation: Int?) {
          (nil, nil)
        }
      #endif

      func prepare() async throws -> BoundInputDevice {
        BoundInputDevice(
          deviceID: 1, deviceUID: "stub", transportLabel: "built_in",
          resolutionSource: "system_default")
      }
      func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
        AsyncStream { $0.finish() }
      }
      func stop() async -> [Float] { [] }
      func deactivateCapture() {}
      func waitForFormatStabilization(maxWait: TimeInterval, pollInterval: TimeInterval) async
        -> Bool
      { true }
      func abortPrepare() {}
      func rebuild() { rebuildCount += 1 }
      var captureStopMetadata: CaptureStopMetadata? { nil }
      var lastBindOK: Bool { true }
      var actualBoundTransport: String? { nil }
    }

    /// Installs a warm source through the SAME seam the retire-fence tests use,
    /// so this suite exercises real manager state rather than a parallel fake.
    private func managerWithWarmSource(_ source: StubSource) -> AudioCaptureManager {
      let manager = AudioCaptureManager()
      manager.installCapturedSourceForTesting(source, sessionID: 1)
      return manager
    }

    /// A route decision supplied by the test, so construction can be exercised
    /// without `CaptureRouteResolver.resolve()` reading live output hardware.
    private static func decision(uid: String? = nil) -> CaptureRouteDecision {
      CaptureRouteDecision(
        sourceType: .halDeviceInput,
        reason: uid == nil ? .noBTAutoInput : .noBTUserSelectedDevice,
        rationale: "test",
        effectiveDeviceUID: uid
      )
    }

    private static func armedHALSource(
      _ manager: AudioCaptureManager, uid: String? = nil
    ) -> HALDeviceInputSource? {
      manager.buildSourceForTesting(decision(uid: uid)) as? HALDeviceInputSource
    }

    /// Is this manager armed? Asked by EFFECT — does the built source have its
    /// default lookup forced? — so the factory is proven consumed rather than
    /// merely stored. Only called on a source already proven to be a HAL source.
    private static func defaultIsForcedNil(_ manager: AudioCaptureManager) -> Bool {
      guard let hal = armedHALSource(manager) else { return false }
      return hal.inputDeviceResolver.defaultInputDeviceID() == nil
    }

    // MARK: - Refusal while capture is active

    @Test("arming is REFUSED while capture is active")
    func armRefusedDuringCapture() {
      let manager = AudioCaptureManager()
      manager.isCapturing = true

      #expect(manager.debugSetDefaultInputAbsent(true) == false)
    }

    @Test("disarming is REFUSED while capture is active")
    func disarmRefusedDuringCapture() {
      let manager = AudioCaptureManager()
      manager.isCapturing = true

      #expect(manager.debugSetDefaultInputAbsent(false) == false)
    }

    @Test("a refused change leaves the previously installed factory untouched")
    func refusalPreservesFactory() {
      let manager = AudioCaptureManager()
      // Arm while idle, then start capturing and try to disarm.
      #expect(manager.debugSetDefaultInputAbsent(true))
      manager.isCapturing = true

      #expect(manager.debugSetDefaultInputAbsent(false) == false)
      // Observed through the REAL consumption path: a still-armed manager builds
      // a HAL source whose default lookup is forced nil.
      manager.isCapturing = false
      #expect(Self.defaultIsForcedNil(manager), "the armed factory must survive a refusal")
    }

    @Test("a refused change does NOT rebuild the active source")
    func refusalDoesNotRebuild() {
      let stub = StubSource()
      let manager = managerWithWarmSource(stub)
      manager.isCapturing = true

      #expect(manager.debugSetDefaultInputAbsent(true) == false)
      #expect(stub.rebuildCount == 0, "a live take must never be disturbed by arming")
    }

    // MARK: - Idle arming tears the warm source down

    @Test("arming while idle rebuilds the warm source exactly once")
    func armRebuildsWarmSourceOnce() {
      let stub = StubSource()
      let manager = managerWithWarmSource(stub)

      #expect(manager.debugSetDefaultInputAbsent(true))
      // Without this, the next take would reuse the warm bind and return before
      // resolution ever ran — the branch under test would be skipped.
      #expect(stub.rebuildCount == 1)
    }

    @Test("disarming while idle also rebuilds the warm source exactly once")
    func disarmRebuildsWarmSourceOnce() {
      let stub = StubSource()
      let manager = managerWithWarmSource(stub)

      #expect(manager.debugSetDefaultInputAbsent(false))
      // The negative control needs this too: otherwise it would run against a
      // source still built by the armed factory and report the right answer for
      // the wrong reason.
      #expect(stub.rebuildCount == 1)
    }

    @Test("arming and disarming succeed with no active source")
    func succeedsWithNoActiveSource() {
      let manager = AudioCaptureManager()

      #expect(manager.debugSetDefaultInputAbsent(true))
      #expect(Self.defaultIsForcedNil(manager))
      #expect(manager.debugSetDefaultInputAbsent(false))
      // The disarmed side is proven by `disarmedInstallsNothing`, which uses a
      // sentinel. Asserting it here would call the PRODUCTION default provider
      // and read real hardware.
    }

    // MARK: - The armed factory's topology

    @Test("the armed factory builds a REAL HAL source with only the default forced nil")
    func armedFactoryTopology() {
      let manager = AudioCaptureManager()
      #expect(manager.debugSetDefaultInputAbsent(true))

      // Built through the same construction authority production uses.
      let hal = Self.armedHALSource(manager, uid: "chosen-mic")

      // A REAL source, not a stub: real enumeration and real AUHAL binding are
      // the point. Only the "what is the default?" question is forced.
      #expect(hal != nil, "the armed factory must build a real HAL source")
      // The route decision is honoured rather than re-read from settings inside
      // the factory, which would be the stale-selection defect this issue avoids.
      #expect(hal?.targetDeviceUID == "chosen-mic")
      // The forced default — the whole point of the seam.
      #expect(hal?.inputDeviceResolver.defaultInputDeviceID() == nil)
    }

    @Test("a disarmed manager clears the installed factory")
    func disarmedInstallsNothing() {
      // A sentinel proves the factory is GONE rather than merely returning
      // something HAL-shaped, and it needs no hardware read to do it.
      let manager = AudioCaptureManager()
      let sentinel = StubSource()
      manager.installSourceFactoryForTesting { _ in sentinel }

      #expect(manager.debugSetDefaultInputAbsent(false))

      let built = manager.buildSourceForTesting(Self.decision())
      #expect(built is HALDeviceInputSource)
      #expect(ObjectIdentifier(built) != ObjectIdentifier(sentinel))
    }

    @Test("the armed factory keeps the LIVE input snapshot provider")
    func armedFactoryKeepsLiveSnapshotProvider() throws {
      // `armedFactoryTopology` proves the default is forced. It cannot prove the
      // SNAPSHOT provider was left alone: swapping it for `{ .success([]) }`
      // leaves that test green while silently disabling real enumeration, which
      // is the half of the seam that must stay real.
      let source = try String(
        contentsOf: RepoRoot.sourceURL("Sources/EnviousWisprAudio/AudioCaptureManager.swift"),
        encoding: .utf8
      )
      let start = try #require(source.range(of: "package func debugSetDefaultInputAbsent"))
      let end = try #require(
        source.range(of: "func buildSourceForTesting", range: start.upperBound..<source.endIndex))
      let armingSection = source[start.lowerBound..<end.lowerBound]

      #expect(
        armingSection.contains("inputDeviceSnapshot: AudioDeviceEnumerator.inputDeviceSnapshot"))
    }
  }

#endif
