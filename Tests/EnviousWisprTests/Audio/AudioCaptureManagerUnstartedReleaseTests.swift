import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAudio

// Uses AudioCaptureManager's `#if DEBUG` test seams, so the Release test lane must not compile it.
#if DEBUG

  /// #3878: a take that ends before capture starts (mic access off, a released press, a failed
  /// model) must hand its prepared source back to the Keep engine warm policy.
  ///
  /// **Product Outcome.** When this fails, the user sees the mic indicator stay on, and a
  /// Bluetooth headset stays in call quality, after one failed dictation.
  @MainActor
  @Suite(.tags(.productOutcome))
  struct AudioCaptureManagerUnstartedReleaseTests {
    typealias StubSource = AudioCaptureManagerStopFenceTests.StubSource

    private func makeManager(_ policy: WarmEnginePolicy) -> (AudioCaptureManager, StubSource) {
      let manager = AudioCaptureManager()
      manager.warmEnginePolicy = policy  // set first: with no source, the setter changes nothing
      let stub = StubSource()
      manager.installCapturedSourceForTesting(stub, sessionID: 1)
      return (manager, stub)
    }

    @Test("Keep engine warm Off: the prepared source is detached now and then stopped")
    func offTearsDownNow() async {
      let (manager, stub) = makeManager(.off)
      manager.releaseUnstartedCapture()
      #expect(!manager.hasActiveSourceForTesting, "the source must be detached synchronously")
      await manager.awaitEngineStopForTesting()
      #expect(stub.stopCallCount == 1)
    }

    @Test("A timed policy restarts its countdown and keeps the source until it ends")
    func timedPolicyRearmsTheTimer() {
      let (manager, stub) = makeManager(.seconds30)
      #expect(!manager.hasPendingWarmTeardownForTesting, "precondition: no countdown running")
      manager.releaseUnstartedCapture()
      #expect(manager.hasPendingWarmTeardownForTesting)
      #expect(manager.isIdleTrackedForTesting)
      #expect(manager.hasActiveSourceForTesting)
      #expect(stub.stopCallCount == 0)
    }

    @Test("Always keeps the source and records when it went idle")
    func alwaysKeepsTheSource() {
      let (manager, _) = makeManager(.always)
      manager.releaseUnstartedCapture()
      #expect(manager.hasActiveSourceForTesting)
      #expect(!manager.hasPendingWarmTeardownForTesting)
      #expect(manager.isIdleTrackedForTesting)
    }

    @Test("No source, or a source capturing for a newer take: nothing changes")
    func noSourceAndCapturingAreNoOps() {
      let idle = AudioCaptureManager()
      idle.warmEnginePolicy = .seconds30
      idle.releaseUnstartedCapture()
      #expect(!idle.hasPendingWarmTeardownForTesting)
      #expect(!idle.isIdleTrackedForTesting)

      let (capturing, stub) = makeManager(.off)
      capturing.isCapturing = true
      capturing.releaseUnstartedCapture()
      #expect(capturing.hasActiveSourceForTesting, "a newer take's source was torn down")
      #expect(stub.stopCallCount == 0)
    }
  }

#endif
