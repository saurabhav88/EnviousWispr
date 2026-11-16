#if DEBUG
  import CoreAudio
  import Foundation
  import Testing
  import os

  @testable import EnviousWisprAudio

  // #4601 §3.2: one owner per native microphone unit. When these fail, the user
  // sees a crash at microphone release (callback storage freed while a render
  // callback can still run) or a microphone left open after a failed start.
  // Native calls are injected; no hardware is touched.
  @Suite("HAL unit ownership — #4601", .tags(.productOutcome))
  struct HALUnitOwnershipTests {

    /// Records every native call in order, thread-safely.
    final class Recorder: Sendable {
      private let calls = OSAllocatedUnfairLock<[String]>(initialState: [])
      func record(_ call: String) { calls.withLock { $0.append(call) } }
      var log: [String] { calls.withLock { $0 } }
    }

    static func calls(
      _ recorder: Recorder, stop: OSStatus = noErr, dispose: OSStatus = noErr,
      beforeStop: @escaping @Sendable () -> Void = {}
    ) -> HALNativeCalls {
      HALNativeCalls(
        stop: { _ in
          recorder.record("stop")
          beforeStop()
          return stop
        },
        uninitialize: { _ in
          recorder.record("uninitialize")
          return noErr
        },
        dispose: { _ in
          recorder.record("dispose")
          return dispose
        },
        removeListener: { object, _, _, _ in
          recorder.record("removeListener(\(object))")
          return noErr
        },
        storageReleased: { recorder.record("storageReleased") })
    }

    @Test("a started unit retires in order and frees callback storage last")
    func startedUnitRetiresInOrder() {
      let recorder = Recorder()
      let resources = HALUnitResources.makeForTesting(
        stage: .started, native: Self.calls(recorder), listenerCount: 2)

      let report = resources.retire()

      #expect(
        recorder.log == [
          "removeListener(1)", "removeListener(2)", "stop", "uninitialize", "dispose",
          "storageReleased",
        ])
      #expect(report.storageReleased)
      #expect(report.stop == noErr && report.uninitialize == noErr && report.dispose == noErr)
      #expect(!resources.holdsCallbackStorage)
      #expect(resources.stoppedFlagIsSetForTesting)
    }

    @Test(
      "a failed open undoes only what it reached, and disposes before freeing storage",
      arguments: [
        (HALUnitResources.Stage.created, ["dispose", "storageReleased"]),
        (HALUnitResources.Stage.initialized, ["uninitialize", "dispose", "storageReleased"]),
      ])
    func failedOpenUndoesOnlyItsStage(stage: HALUnitResources.Stage, expected: [String]) {
      let recorder = Recorder()
      let resources = HALUnitResources.makeForTesting(stage: stage, native: Self.calls(recorder))

      let report = resources.retire()

      #expect(recorder.log == expected)
      #expect(report.stop == nil)
      #expect(report.storageReleased)
    }

    @Test("callback storage stays alive while a native stop is blocked")
    func storageHeldAcrossBlockedStop() {
      let recorder = Recorder()
      let stopEntered = DispatchSemaphore(value: 0)
      let gate = DispatchSemaphore(value: 0)
      let finished = DispatchSemaphore(value: 0)
      nonisolated(unsafe) let resources = HALUnitResources.makeForTesting(
        stage: .started,
        native: Self.calls(
          recorder,
          beforeStop: {
            stopEntered.signal()
            gate.wait()
          }))

      Thread {
        resources.retire()
        finished.signal()
      }.start()

      // settle: hang guard around the subject-fired stop signal, never a sleep.
      #expect(stopEntered.wait(timeout: .now() + 5) == .success, "stop was never called")
      // The retiring thread is parked inside stop: nothing after it has run.
      #expect(!recorder.log.contains("storageReleased"))
      #expect(!recorder.log.contains("dispose"))
      gate.signal()
      // settle: hang guard around the subject-fired completion signal.
      #expect(finished.wait(timeout: .now() + 5) == .success, "retirement never finished")
      #expect(recorder.log.last == "storageReleased")
      #expect(!resources.holdsCallbackStorage)
    }

    @Test(
      "a failed stop or dispose keeps callback storage instead of freeing it",
      arguments: [(stop: OSStatus(-50), dispose: noErr), (stop: noErr, dispose: OSStatus(-50))])
    func unsafeRetirementKeepsStorage(stop: OSStatus, dispose: OSStatus) {
      let recorder = Recorder()
      let resources = HALUnitResources.makeForTesting(
        stage: .started, native: Self.calls(recorder, stop: stop, dispose: dispose))

      let report = resources.retire()

      #expect(!report.storageReleased)
      #expect(resources.holdsCallbackStorage)
      #expect(!recorder.log.contains("storageReleased"))
      #expect(recorder.log.contains("dispose"), "dispose still runs after a failed stop")
    }

    @Test("retiring twice performs no second native teardown")
    func secondRetireIsInert() {
      let recorder = Recorder()
      let resources = HALUnitResources.makeForTesting(
        stage: .started, native: Self.calls(recorder), listenerCount: 1)

      let first = resources.retire()
      let callsAfterFirst = recorder.log
      let second = resources.retire()

      #expect(second == first)
      #expect(recorder.log == callsAfterFirst)
    }

    @Test("a failed open keeps its own setup step and status when cleanup also fails")
    func failedOpenKeepsSetupFailure() {
      let recorder = Recorder()
      let resources = HALUnitResources.makeForTesting(
        stage: .initialized, native: Self.calls(recorder, dispose: OSStatus(-50)))
      let original = AudioError.formatCreationFailed(
        source: "HALDeviceInputSource.prepare.start", osStatus: 60)

      let thrown = HALDeviceInputSource.failedOpenError(retiring: resources, failure: original)

      guard case .formatCreationFailed(let source, let status) = thrown else {
        Issue.record("expected formatCreationFailed, got \(thrown)")
        return
      }
      #expect(source == "HALDeviceInputSource.prepare.start")
      #expect(status == 60)
      #expect(
        resources.report?.dispose == -50, "the cleanup failure is in the report, not the error")
    }
  }
#endif
