import EnviousWisprServices
import Foundation
import Testing
import os

/// #3544 P2: the keyboard listener seam and the fake every listener suite drives.
///
/// Harness Contract: when this fails, the listener suites built on the fake deliver on the wrong
/// thread, deliver events after removal, or keep a callback a failed install never owned.
/// No user sees it directly; the listener suites would lie.
@Suite(.tags(.harnessContract), .timeLimit(.minutes(1)))
@MainActor
struct KeyboardListenerSeamTests {

  private let press = KeyEventValue(
    kind: .flagsChanged, keyCode: 61, rawFlags: 0x80040, timestamp: 1000.25)

  /// Calls the sink on a worker thread, as the listener's own thread will, and returns whether it
  /// ran on main. The continuation always resumes: the dispatched block runs unconditionally.
  private func deliverFromWorker(
    _ sink: @escaping @Sendable (KeyEventValue) -> KeyboardEventDisposition, _ event: KeyEventValue
  ) async -> Bool {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInteractive).async {
        _ = sink(event)
        continuation.resume(returning: Thread.isMainThread)
      }
    }
  }

  @Test("a worker delivery runs the sink off main")
  func workerDeliveryRunsTheSinkOffMain() async throws {
    let effects = RecordingDesktopHotkeyEffects()
    let seen = OSAllocatedUnfairLock<[KeyEventValue]>(initialState: [])
    let token = effects.installKeyboardListener { event in
      seen.withLock { $0.append(event) }
      return .pass
    }
    #expect(token != nil)
    let sink = try #require(effects.keyboardListenerDispositionSink)

    let firstOnMain = await deliverFromWorker(sink, press)
    let other = KeyEventValue(kind: .keyDown, keyCode: 14, rawFlags: 0, timestamp: 1000.5)
    let secondOnMain = await deliverFromWorker(sink, other)

    #expect(firstOnMain == false)
    #expect(secondOnMain == false)
    #expect(seen.withLock { $0 } == [press, other])
  }

  @Test("the sink's answer reaches the caller, and the void sink still delivers (#3517)")
  func sinkAnswerReachesTheCaller() async throws {
    let effects = RecordingDesktopHotkeyEffects()
    let answers = OSAllocatedUnfairLock<[KeyboardEventDisposition]>(
      initialState: [.consume, .pass])
    _ = effects.installKeyboardListener { _ in
      answers.withLock { $0.isEmpty ? .pass : $0.removeFirst() }
    }
    let sink = try #require(effects.keyboardListenerDispositionSink)
    #expect(sink(press) == .consume)
    #expect(sink(press) == .pass)
    // The ignoring sink most suites use runs the same policy and discards the answer.
    answers.withLock { $0 = [.consume] }
    let ignoring = try #require(effects.keyboardListenerSink)
    ignoring(press)
    #expect(answers.withLock { $0.isEmpty }, "the void sink did not reach the policy")
  }

  @Test("removing the listener's token stops delivery")
  func removalDropsTheSink() throws {
    let effects = RecordingDesktopHotkeyEffects()
    let token = effects.installKeyboardListener { _ in .pass }
    #expect(effects.keyboardListenerSink != nil)

    #expect(effects.remove(try #require(token)) == true)

    #expect(effects.keyboardListenerSink == nil)
    #expect(effects.keyboardListenerToken == nil)
  }

  @Test("a refused removal keeps the listener and its sink")
  func refusedRemovalKeepsOwnership() throws {
    let effects = RecordingDesktopHotkeyEffects()
    effects.refuseRemovals = true
    let token = effects.installKeyboardListener { _ in .pass }

    #expect(effects.remove(try #require(token)) == false)

    #expect(effects.keyboardListenerToken == token)
    #expect(effects.keyboardListenerSink != nil)
  }

  @Test("removing another token leaves the listener installed")
  func unrelatedRemovalKeepsTheListener() {
    let effects = RecordingDesktopHotkeyEffects()
    let token = effects.installKeyboardListener { _ in .pass }

    #expect(effects.remove(DesktopEffectToken()) == true)

    #expect(effects.keyboardListenerToken == token)
    #expect(effects.keyboardListenerSink != nil)
  }

  @Test("a failed install owns no callback and returns no token")
  func failedInstallOwnsNothing() {
    let effects = RecordingDesktopHotkeyEffects()
    effects.failKeyboardListenerInstall = true

    let token = effects.installKeyboardListener { _ in .pass }

    #expect(token == nil)
    #expect(effects.keyboardListenerInstalls == 1)
    #expect(effects.keyboardListenerSink == nil)
    #expect(effects.keyboardListenerToken == nil)
  }

  @Test("lifecycle values permit an unknown timestamp")
  func lifecycleValuesPermitUnknownTime() {
    for kind in [KeyEventValue.Kind.tapReenabled, .secureInputChanged] {
      let value = KeyEventValue(kind: kind, keyCode: 0, rawFlags: 0, timestamp: nil)
      #expect(value.kind == kind)
      #expect(value.timestamp == nil)
      #expect(value.isAutorepeat == false)
      #expect(value.isOurs == false)
    }
  }
}
