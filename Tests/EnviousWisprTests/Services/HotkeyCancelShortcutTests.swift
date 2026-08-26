import AppKit
import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

/// #1991 — a bare modifier set as the CANCEL key must actually cancel.
///
/// Six production users are in this state right now. The key they chose is
/// stored, displayed, and completely inert, which is worse than a refusal
/// because nothing tells them it is dead.
///
/// TWO INDEPENDENT BLOCKERS, and a suite that exercised only one would pass a
/// build that is still broken for every real user:
///
/// 1. **Dispatch.** `handleFlagsChangedValues` compared the incoming key code
///    against the *record* key only, so a modifier bound to cancel returned
///    early and no cancel ever fired.
/// 2. **Installation.** The `NSEvent` modifier monitors were installed only when
///    the RECORD key was modifier-only. The affected users pair a bare-modifier
///    cancel with a chord record key — the default shape — so no monitor existed
///    to observe the cancel key in the first place. Fixing (1) alone would leave
///    them exactly as broken, and every test that drives the dispatch seam
///    directly would still pass.
///
/// So the install cases below go through `shouldInstallModifierMonitors`, the
/// same expression the installer guards on, rather than the dispatch seam.
///
/// Every dispatch case drives the REAL seam, `handleFlagsChangedValues`, with
/// the physical event shape a modifier produces: the flag is PRESENT on press
/// and ABSENT on release (measured on hardware for #1987). Asserting on set
/// membership instead would prove the key is accepted and nothing about what
/// pressing it does.
@MainActor
@Suite struct HotkeyCancelShortcutTests {

  private let rightCommand = ModifierKeyCodes.rightCommand
  private let rightOption = ModifierKeyCodes.rightOption
  /// A plain chord record key — the DEFAULT shape for the affected users, and
  /// the one that hides blocker 2. `kVK_ANSI_D`.
  private let chordKeyCode: UInt16 = 2

  /// Records which callbacks the service invoked.
  @MainActor final class Sink {
    var cancels = 0
    var toggles = 0
  }

  /// Signal-based wait: the callback IS the signal. The deadline is a fallback
  /// AROUND that signal, never the wait itself, and it exists only so a
  /// regression fails with a test name instead of hanging.
  ///
  /// The deadline is not decoration. The first version of this helper had no
  /// timeout, and the mutation control for the dispatch fix — removing the
  /// cancel branch from the matcher, which IS the #1991 bug — made the suite
  /// hang rather than fail. A test that hangs on the regression it exists to
  /// catch reports nothing at all, which is worse than a red test and much
  /// harder to read in CI.
  @MainActor final class Waiter {
    private var fired = false
    private var pending: (id: UUID, continuation: CheckedContinuation<Void, Never>)?

    func note() {
      fired = true
      guard let pending else { return }
      self.pending = nil
      pending.continuation.resume()
    }

    func wait(timeout: Duration = .seconds(5)) async {
      if fired { return }
      let id = UUID()
      let timeoutTask = Task { @MainActor [weak self] in
        // settle: deadline fallback around the callback signal; the callback resumes and cancels this
        try? await Task.sleep(for: timeout)
        self?.expire(id: id)
      }
      await withCheckedContinuation { continuation in
        pending = (id, continuation)
      }
      timeoutTask.cancel()
    }

    private func expire(id: UUID) {
      guard let pending, pending.id == id else { return }
      self.pending = nil
      Issue.record(Comment(rawValue: "timed out waiting for the callback"))
      pending.continuation.resume()
    }
  }

  private func makeService(
    recordKey: UInt16,
    cancelKey: UInt16,
    mode: RecordingMode = .toggle
  ) -> (HotkeyService, Sink, Waiter, Waiter) {
    let sink = Sink()
    let cancelWaiter = Waiter()
    let toggleWaiter = Waiter()
    let service = HotkeyService(onDeniedDesktopEffect: DesktopEffectDenial.recordOnly)
    service.recordingMode = mode
    service.toggleKeyCode = recordKey
    service.toggleModifiers = []
    service.cancelKeyCode = cancelKey
    service.cancelModifiers = []
    service.onCancelRecording = {
      sink.cancels += 1
      cancelWaiter.note()
    }
    service.onToggleRecording = {
      sink.toggles += 1
      toggleWaiter.note()
    }
    return (service, sink, cancelWaiter, toggleWaiter)
  }

  // MARK: - Blocker 1: dispatch

  @Test("a bare-modifier cancel key cancels while cancel is armed")
  func bareModifierCancelFires() async {
    let (service, sink, cancelWaiter, _) = makeService(
      recordKey: chordKeyCode, cancelKey: rightCommand)
    // Cancel is armed only during a recording, exactly as the lifecycle does it.
    service.registerCancelHotkey()

    service.handleFlagsChangedValues(keyCode: rightCommand, flags: [.command])
    await cancelWaiter.wait()

    #expect(sink.cancels == 1)
    #expect(sink.toggles == 0)
  }

  /// The other half of the arming contract. Without this, a build that cancels
  /// on every press of the key — including while idle — passes the case above.
  @Test("a bare-modifier cancel key does nothing while cancel is NOT armed")
  func bareModifierCancelSilentWhenUnarmed() async {
    let (service, sink, _, _) = makeService(recordKey: chordKeyCode, cancelKey: rightCommand)
    // No registerCancelHotkey: no recording is in flight.

    service.handleFlagsChangedValues(keyCode: rightCommand, flags: [.command])
    await Task.yield()

    #expect(sink.cancels == 0)
  }

  @Test("cancel stops firing once the recording ends")
  func cancelDisarmsAfterRecording() async {
    let (service, sink, cancelWaiter, _) = makeService(
      recordKey: chordKeyCode, cancelKey: rightCommand)
    service.registerCancelHotkey()
    service.handleFlagsChangedValues(keyCode: rightCommand, flags: [.command])
    await cancelWaiter.wait()
    #expect(sink.cancels == 1)

    service.unregisterCancelHotkey()
    service.handleFlagsChangedValues(keyCode: rightCommand, flags: [.command])
    await Task.yield()

    #expect(sink.cancels == 1, "a disarmed cancel key must not fire again")
  }

  /// A modifier RELEASE is not a press. Without this, an implementation that
  /// ignores the flag would cancel twice per physical press.
  @Test("releasing the cancel modifier does not cancel")
  func cancelIgnoresRelease() async {
    let (service, sink, _, _) = makeService(recordKey: chordKeyCode, cancelKey: rightCommand)
    service.registerCancelHotkey()

    // Release: the key code arrives with its flag ABSENT.
    service.handleFlagsChangedValues(keyCode: rightCommand, flags: [])
    await Task.yield()

    #expect(sink.cancels == 0)
  }

  /// The record key must keep working unchanged while a cancel binding exists.
  @Test("a bare-modifier record key still toggles when cancel is also a modifier")
  func recordStillWorksAlongsideModifierCancel() async {
    let (service, sink, _, toggleWaiter) = makeService(
      recordKey: rightOption, cancelKey: rightCommand)

    service.handleFlagsChangedValues(keyCode: rightOption, flags: [.option])
    await toggleWaiter.wait()

    #expect(sink.toggles == 1)
    #expect(sink.cancels == 0)
  }

  /// An unrelated modifier must reach neither role.
  @Test("an unbound modifier does nothing")
  func unboundModifierIsInert() async {
    let (service, sink, _, _) = makeService(recordKey: chordKeyCode, cancelKey: rightCommand)
    service.registerCancelHotkey()

    service.handleFlagsChangedValues(
      keyCode: ModifierKeyCodes.leftControl, flags: [.control])
    await Task.yield()

    #expect(sink.cancels == 0)
    #expect(sink.toggles == 0)
  }

  // MARK: - Blocker 2: installation

  /// This is the case the six affected users are actually in, and the one a
  /// dispatch-only suite cannot see.
  @Test("monitors install when only the CANCEL key is a bare modifier")
  func installsForModifierCancelWithChordRecord() {
    let (service, _, _, _) = makeService(recordKey: chordKeyCode, cancelKey: rightCommand)
    #expect(service.shouldInstallModifierMonitors)
  }

  @Test("monitors install when only the RECORD key is a bare modifier")
  func installsForModifierRecordWithChordCancel() {
    let (service, _, _, _) = makeService(recordKey: rightOption, cancelKey: 53)
    #expect(service.shouldInstallModifierMonitors)
  }

  @Test("monitors install when BOTH keys are bare modifiers")
  func installsForBothModifiers() {
    let (service, _, _, _) = makeService(recordKey: rightOption, cancelKey: rightCommand)
    #expect(service.shouldInstallModifierMonitors)
  }

  /// The negative control. Without it, an implementation that always installs
  /// passes all three cases above while doing unnecessary work on every launch.
  @Test("monitors do NOT install when neither key is a bare modifier")
  func doesNotInstallForTwoChords() {
    let (service, _, _, _) = makeService(recordKey: chordKeyCode, cancelKey: 53)
    #expect(!service.shouldInstallModifierMonitors)
  }

  // MARK: - Arming across suspend / resume

  /// Opening the shortcut recorder mid-recording must not disarm that
  /// recording's cancel key. `resume()` used to restore the record hotkey and
  /// the monitors only, so the user lost cancel for the rest of the recording
  /// and nothing said so.
  @Test("cancel survives the recorder opening and closing mid-recording")
  func cancelSurvivesSuspendResume() async {
    let (service, sink, cancelWaiter, _) = makeService(
      recordKey: chordKeyCode, cancelKey: rightCommand)
    service.start()
    service.registerCancelHotkey()

    service.suspend()
    service.resume()

    service.handleFlagsChangedValues(keyCode: rightCommand, flags: [.command])
    await cancelWaiter.wait()

    #expect(sink.cancels == 1)
    service.stop()
  }

  /// The negative control for the case above. Without it, a `resume()` that
  /// unconditionally arms cancel — rather than restoring what was armed — passes
  /// the previous test while arming cancel for a recording that never started.
  @Test("resume does NOT arm cancel when no recording was in flight")
  func resumeDoesNotArmCancelWhenIdle() async {
    let (service, sink, _, _) = makeService(recordKey: chordKeyCode, cancelKey: rightCommand)
    service.start()
    // No registerCancelHotkey: nothing is recording.

    service.suspend()
    service.resume()

    service.handleFlagsChangedValues(keyCode: rightCommand, flags: [.command])
    await Task.yield()

    #expect(sink.cancels == 0)
    service.stop()
  }

  /// Changing the cancel key WHILE the recorder is open is the real sequence:
  /// the recorder suspends the service, the new binding is written, then resume
  /// runs. `reapplyCancelBinding()` deliberately no-ops while suspended, so this
  /// asserts that `resume()` picks up the new key rather than restoring the old
  /// one — a stale-snapshot bug that would look exactly like #1991 all over
  /// again to the one user most likely to hit it.
  @Test("a cancel key changed during suspension takes effect on resume")
  func cancelKeyChangedWhileSuspendedTakesEffect() async {
    let (service, sink, cancelWaiter, _) = makeService(
      recordKey: chordKeyCode, cancelKey: rightCommand)
    service.start()
    service.registerCancelHotkey()

    service.suspend()
    service.cancelKeyCode = ModifierKeyCodes.rightControl
    service.reapplyCancelBinding()  // no-op while suspended, by design
    service.resume()

    // The OLD key must be inert.
    service.handleFlagsChangedValues(keyCode: rightCommand, flags: [.command])
    await Task.yield()
    #expect(sink.cancels == 0, "the previous cancel key must stop working")

    // The NEW key must cancel.
    service.handleFlagsChangedValues(
      keyCode: ModifierKeyCodes.rightControl, flags: [.control])
    await cancelWaiter.wait()
    #expect(sink.cancels == 1)
    service.stop()
  }

  /// A recording can END while the recorder is still open — VAD auto-stop, the
  /// duration cap, or the window's Cancel button. The saved arming snapshot must
  /// die with it, or `resume()` arms cancel onto an idle app and nothing later
  /// disarms it, because the recording that owned it already finished.
  ///
  /// Found by review, not by me: the two suspend/resume tests above both end
  /// their recording AFTER resume, so neither could reach this ordering.
  @Test("a recording ending during suspension does not leave cancel armed")
  func recordingEndingWhileSuspendedDoesNotRearmCancel() async {
    let (service, sink, _, _) = makeService(recordKey: chordKeyCode, cancelKey: rightCommand)
    service.start()
    service.registerCancelHotkey()

    service.suspend()
    // The recording ends while the recorder is still open.
    service.unregisterCancelHotkey()
    service.resume()

    service.handleFlagsChangedValues(keyCode: rightCommand, flags: [.command])
    await Task.yield()

    #expect(sink.cancels == 0, "cancel must not be armed once its recording has ended")
    service.stop()
  }

  /// Changing the RECORD key while the shortcut editor is open is the single
  /// most likely way to reach this code, because changing the record key IS what
  /// the editor does — and the editor suspends first.
  ///
  /// While suspended the armed state lives in the snapshot and `isCancelArmed`
  /// reads false, so a restart here would preserve `false` and `stop()` would
  /// clear the real snapshot on its way through, leaving cancel dead for the rest
  /// of the recording. That is the #1991 bug itself, reintroduced by its own fix
  /// in a neighbouring branch; review caught it, not me.
  @Test("changing the record key while the editor is open keeps cancel alive")
  func recordKeyChangedWhileSuspendedKeepsCancelArmed() async {
    let (service, sink, cancelWaiter, _) = makeService(
      recordKey: chordKeyCode, cancelKey: rightCommand)
    service.start()
    service.registerCancelHotkey()

    service.suspend()
    // The editor writes a new record binding, which drives a re-registration.
    service.toggleKeyCode = ModifierKeyCodes.rightOption
    service.restartPreservingCancelArming()
    service.resume()

    service.handleFlagsChangedValues(keyCode: rightCommand, flags: [.command])
    await cancelWaiter.wait()

    #expect(sink.cancels == 1, "cancel must survive a record-key change made in the editor")
    service.stop()
  }

  /// The same call while NOT suspended must still do its job, or the guard has
  /// simply disabled the path rather than scoped it.
  @Test("changing the record key while idle still preserves cancel arming")
  func recordKeyChangedWhileRunningKeepsCancelArmed() async {
    let (service, sink, cancelWaiter, _) = makeService(
      recordKey: chordKeyCode, cancelKey: rightCommand)
    service.start()
    service.registerCancelHotkey()

    service.toggleKeyCode = ModifierKeyCodes.rightOption
    service.restartPreservingCancelArming()

    service.handleFlagsChangedValues(keyCode: rightCommand, flags: [.command])
    await cancelWaiter.wait()

    #expect(sink.cancels == 1)
    service.stop()
  }

  /// `.command` is an AGGREGATE device-independent flag: with Left Command held,
  /// releasing Right Command leaves `.command` set, so the release reads as a
  /// press and the same physical tap cancels twice. The `guard isPress` alone
  /// does not stop it — an earlier comment claimed it did, and cloud review
  /// showed the two-key case defeats it.
  @Test("a cancel modifier released while its twin is held does not cancel twice")
  func cancelDoesNotFireTwiceWhenOppositeSideKeyIsHeld() async {
    let (service, sink, cancelWaiter, _) = makeService(
      recordKey: chordKeyCode, cancelKey: rightCommand)
    service.registerCancelHotkey()

    // Down: Right Command pressed while Left Command is already held.
    service.handleFlagsChangedValues(keyCode: rightCommand, flags: [.command])
    await cancelWaiter.wait()
    #expect(sink.cancels == 1)

    // Up: Right Command released, but Left Command still holds `.command` set,
    // so the aggregate flag still reads as pressed.
    service.handleFlagsChangedValues(keyCode: rightCommand, flags: [.command])
    await Task.yield()

    #expect(sink.cancels == 1, "one physical tap must cancel exactly once")
  }

  // MARK: - Cancel modifier shadowing the record chord

  /// Cancel on bare Right Command, record on Command+D. Pressing Command to STOP
  /// the recording arrives as a bare Command press that matches the cancel
  /// binding exactly, so without a guard the recording is discarded before D is
  /// ever pressed — the user loses everything they just said while trying to
  /// stop, deterministically.
  ///
  /// A regression this change introduced: the pre-fix dispatch compared against
  /// the record key alone and returned early here. Found by review.
  @Test("a cancel modifier required by the record chord does not cancel")
  func cancelModifierShadowedByRecordChordIsRefused() async {
    let sink = Sink()
    let service = HotkeyService(onDeniedDesktopEffect: DesktopEffectDenial.recordOnly)
    service.recordingMode = .toggle
    service.toggleKeyCode = chordKeyCode  // D
    service.toggleModifiers = [.command]  // record is ⌘D
    service.cancelKeyCode = rightCommand
    service.cancelModifiers = []
    service.onCancelRecording = { sink.cancels += 1 }
    service.registerCancelHotkey()

    service.handleFlagsChangedValues(keyCode: rightCommand, flags: [.command])
    await Task.yield()

    #expect(sink.cancels == 0, "pressing ⌘ to stop must not discard the recording")
  }

  /// The control that keeps the guard SCOPED. A cancel modifier the record chord
  /// does not require is unambiguous and must still cancel — otherwise the fix
  /// above has simply disabled bare-modifier cancel for every chord user.
  @Test("a cancel modifier NOT required by the record chord still cancels")
  func cancelModifierUnrelatedToRecordChordStillWorks() async {
    let sink = Sink()
    let waiter = Waiter()
    let service = HotkeyService(onDeniedDesktopEffect: DesktopEffectDenial.recordOnly)
    service.recordingMode = .toggle
    service.toggleKeyCode = chordKeyCode
    service.toggleModifiers = [.command]  // record is ⌘D
    service.cancelKeyCode = ModifierKeyCodes.rightOption  // cancel is bare ⌥
    service.cancelModifiers = []
    service.onCancelRecording = {
      sink.cancels += 1
      waiter.note()
    }
    service.registerCancelHotkey()

    service.handleFlagsChangedValues(keyCode: ModifierKeyCodes.rightOption, flags: [.option])
    await waiter.wait()

    #expect(sink.cancels == 1)
  }

  // MARK: - Conflicting pair

  /// A pre-existing user may ALREADY have both roles on one key, because no
  /// conflict check has ever existed at either capture surface. Dispatch must
  /// stay deterministic for them and keep doing what it does today, which is to
  /// treat the press as the record key — the old dispatch compared against the
  /// record key alone, so record won there too. Refusing the pair belongs at
  /// capture time with user-visible copy, and is the next slice's work.
  @Test("a conflicting pair still dispatches to record, not cancel")
  func conflictingPairPrefersRecord() async {
    let (service, sink, _, toggleWaiter) = makeService(
      recordKey: rightCommand, cancelKey: rightCommand)
    service.registerCancelHotkey()

    service.handleFlagsChangedValues(keyCode: rightCommand, flags: [.command])
    await toggleWaiter.wait()

    #expect(sink.toggles == 1)
    #expect(sink.cancels == 0)
  }
}
