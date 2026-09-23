import AppKit
import Testing

@testable import EnviousWisprServices

/// Paste Last and Copy Last as the hotkey service registers and dispatches them (#3106).
///
/// When one of these fails, the user presses Control-Command-V and nothing happens, it pastes twice
/// while held, it fires with their fingers still on the modifiers, or the chord is taken away from
/// the frontmost app in a build where nothing answers it.
@MainActor
@Suite("Paste and Copy Last Dictation: registration and presses (#3106)", .tags(.productOutcome))
struct LastDictationHotkeyTests {

  private let pasteID: UInt32 = 5
  private let copyID: UInt32 = 6
  private let quickAddID: UInt32 = 4

  /// Counts callbacks and resumes a waiter the moment the expected count is reached. The deadline
  /// is a fail-fast fallback only: a callback that never arrives fails the test instead of hanging.
  @MainActor private final class Spy {
    var pastes = 0
    var copies = 0
    var presses: [(trigger: String, keyShape: String, action: String)] = []
    private var waiting:
      (id: UUID, target: () -> Bool, continuation: CheckedContinuation<Bool, Never>)?

    func noteCallback() {
      guard let waiting, waiting.target() else { return }
      self.waiting = nil
      waiting.continuation.resume(returning: true)
    }

    /// Waits until `condition` holds, driven by the callbacks themselves.
    ///
    /// The deadline expires only ITS OWN wait (matched by id), and only if it was not cancelled:
    /// `try? Task.sleep` returns at once on cancellation, so without both checks a finished wait's
    /// deadline would fail the NEXT wait a moment later.
    func wait(until condition: @escaping () -> Bool, timeout: Duration = .seconds(5)) async -> Bool
    {
      if condition() { return true }
      let id = UUID()
      let deadline = Task { @MainActor [weak self] in
        // deadline-fallback: resumes the waiter only if the callback never arrives
        try? await Task.sleep(for: timeout)
        guard !Task.isCancelled, let self, let waiting = self.waiting, waiting.id == id else {
          return
        }
        self.waiting = nil
        waiting.continuation.resume(returning: false)
      }
      let met = await withCheckedContinuation { continuation in
        waiting = (id, condition, continuation)
      }
      deadline.cancel()
      return met
    }
  }

  /// A running service on shipped bindings. Callbacks are installed unless asked not to.
  private func makeService(installCallbacks: Bool = true) -> (
    HotkeyService, RecordingDesktopHotkeyEffects, Spy
  ) {
    let spy = Spy()
    let (service, effects) = makeHotkeyService(
      telemetry: HotkeyTelemetrySink(
        registrationFailed: { _, _, _, _ in },
        pressed: { trigger, _, keyShape, _, action in
          spy.presses.append((trigger, keyShape, action))
        }))
    if installCallbacks {
      service.onPasteLast = {
        spy.pastes += 1
        spy.noteCallback()
      }
      service.onCopyLast = {
        spy.copies += 1
        spy.noteCallback()
      }
    }
    service.start()
    return (service, effects, spy)
  }

  /// Accepted fires, read synchronously: `hotkey.pressed` is emitted on the same turn as the
  /// decision to fire.
  private func fired(_ spy: Spy, _ action: String) -> Int {
    spy.presses.filter { $0.action == action }.count
  }

  // MARK: Registration

  @Test("With no action installed, neither chord is taken from the frontmost app")
  func noCallbackNoRegistration() {
    let (service, effects, _) = makeService(installCallbacks: false)
    #expect(!effects.didRegister(id: pasteID))
    #expect(!effects.didRegister(id: copyID))

    // Installing the actions registers them on the running service.
    service.onPasteLast = {}
    service.onCopyLast = {}
    #expect(effects.didRegister(id: pasteID))
    #expect(effects.didRegister(id: copyID))
    service.stop()
  }

  @Test("Shipped defaults register both chords under ids 5 and 6")
  func shippedDefaultsRegister() {
    let (service, effects, _) = makeService()
    let paste = effects.registrations.first { $0.id == pasteID }
    let copy = effects.registrations.first { $0.id == copyID }
    #expect(paste?.keyCode == 9)
    #expect(copy?.keyCode == 8)
    service.stop()
  }

  @Test("A higher shortcut moved onto Paste Last's chord takes it; moving it away gives it back")
  func higherRoleTakesAndReturnsTheChord() {
    let (service, effects, _) = makeService()
    let pasteRegistrationsBefore = effects.registrations.filter { $0.id == pasteID }.count

    service.quickAddKeyCode = 9
    service.quickAddModifiers = [.control, .command]
    service.reapplyAppShortcutBinding(.quickAdd)
    let quickAddNow = effects.registrations.last { $0.id == quickAddID }
    #expect(quickAddNow?.keyCode == 9, "Quick Add now holds Control-Command-V")
    #expect(effects.removed.count >= 1, "Paste Last released its registration first")

    service.quickAddKeyCode = 13
    service.quickAddModifiers = [.control, .shift]
    service.reapplyAppShortcutBinding(.quickAdd)
    #expect(
      effects.registrations.filter { $0.id == pasteID }.count == pasteRegistrationsBefore + 1,
      "Paste Last registered again once the conflict ended")
    service.stop()
  }

  @Test("An armed Cancel on Paste Last's chord takes it for the recording, then gives it back")
  func armedCancelTakesTheChord() {
    let (service, effects, _) = makeService()
    service.cancelKeyCode = 9
    service.cancelModifiers = [.control, .command]
    let pasteBefore = effects.registrations.filter { $0.id == pasteID }.count
    let removedBefore = effects.removed.count

    service.registerCancelHotkey()
    #expect(effects.removed.count == removedBefore + 1, "Paste Last yields before Cancel registers")
    #expect(effects.registrations.last?.id == 3, "Cancel registered after Paste Last let go")

    service.unregisterCancelHotkey()
    #expect(effects.registrations.filter { $0.id == pasteID }.count == pasteBefore + 1)
    service.stop()
  }

  // MARK: Presses

  @Test("Paste fires on release, once, however many press events arrive while held")
  func pasteFiresOnReleaseOnce() async {
    let (service, _, spy) = makeService()
    service.handleCarbonHotkey(id: pasteID, isRelease: false)
    service.handleCarbonHotkey(id: pasteID, isRelease: false)  // auto-repeat or a stray re-press
    #expect(fired(spy, "paste_last") == 0, "nothing on the press: fingers are still on the keys")

    service.handleCarbonHotkey(id: pasteID, isRelease: true)
    #expect(fired(spy, "paste_last") == 1)
    #expect(await spy.wait(until: { spy.pastes == 1 }))

    // A release with no press seen does nothing.
    service.handleCarbonHotkey(id: pasteID, isRelease: true)
    #expect(fired(spy, "paste_last") == 1)
    #expect(spy.presses.last?.trigger == "paste_last_hotkey")
    #expect(spy.presses.last?.keyShape == "chord")
    service.stop()
  }

  @Test("Copy fires on the press, once per hold, and rearms on release")
  func copyFiresOnPressOnce() async {
    let (service, _, spy) = makeService()
    service.handleCarbonHotkey(id: copyID, isRelease: false)
    service.handleCarbonHotkey(id: copyID, isRelease: false)
    #expect(fired(spy, "copy_last") == 1)
    #expect(await spy.wait(until: { spy.copies == 1 }))

    service.handleCarbonHotkey(id: copyID, isRelease: true)
    service.handleCarbonHotkey(id: copyID, isRelease: false)
    #expect(fired(spy, "copy_last") == 2)
    #expect(await spy.wait(until: { spy.copies == 2 }))
    #expect(spy.presses.last?.trigger == "copy_last_hotkey")
    service.stop()
  }

  @Test("When Carbon refuses to drop the old chord on a rebind, the old chord fires nothing")
  func refusedRemovalLeavesTheOldChordInert() {
    let (service, effects, spy) = makeService()
    effects.refuseRemovals = true
    service.copyLastKeyCode = 7  // X
    service.copyLastModifiers = [.control, .command]
    service.reapplyAppShortcutBinding(.copyLast)
    // Carbon still delivers the OLD Control-Command-C under Copy Last's id.
    service.handleCarbonHotkey(id: copyID, isRelease: false)
    #expect(fired(spy, "copy_last") == 0, "the chord that fired is not the one the user set")
    service.handleCarbonHotkey(id: copyID, isRelease: true)

    // Paired: once the removal goes through, the new chord registers and fires.
    effects.refuseRemovals = false
    service.reapplyAppShortcutBinding(.copyLast)
    #expect(effects.registrations.last { $0.id == copyID }?.keyCode == 7)
    service.handleCarbonHotkey(id: copyID, isRelease: false)
    #expect(fired(spy, "copy_last") == 1)
    service.stop()
  }

  @Test("After a refused removal, the next recording's reconcile recovers the new chord unasked")
  func refusedRemovalRecoversOnTheNextReconcile() {
    let (service, effects, spy) = makeService()
    effects.refuseRemovals = true
    service.copyLastKeyCode = 7  // X
    service.copyLastModifiers = [.control, .command]
    service.reapplyAppShortcutBinding(.copyLast)
    #expect(effects.registrations.last { $0.id == copyID }?.keyCode != 7, "still blocked")

    // No reapply: a recording starting and ending is the ordinary reconcile that retries.
    effects.refuseRemovals = false
    service.registerCancelHotkey()
    service.unregisterCancelHotkey()
    #expect(effects.registrations.last { $0.id == copyID }?.keyCode == 7)
    service.handleCarbonHotkey(id: copyID, isRelease: false)
    #expect(fired(spy, "copy_last") == 1)
    service.stop()
  }

  @Test("Quick Add and Cancel keep their old behaviour on a refused removal: the new chord registers (#3108)")
  func refusedRemovalLeavesOtherRolesAsBefore() {
    let (service, effects, _) = makeService()
    effects.refuseRemovals = true
    let quickAddBefore = effects.registrations.filter { $0.id == quickAddID }.count
    service.quickAddKeyCode = 13  // W
    service.quickAddModifiers = [.control, .shift]
    service.reapplyAppShortcutBinding(.quickAdd)
    #expect(effects.registrations.filter { $0.id == quickAddID }.count == quickAddBefore + 1)
    #expect(effects.registrations.last { $0.id == quickAddID }?.keyCode == 13)

    let cancelID = UInt32(3)
    service.registerCancelHotkey()
    service.unregisterCancelHotkey()
    service.registerCancelHotkey()
    #expect(effects.registrations.filter { $0.id == cancelID }.count == 2,
            "a refused Cancel removal does not stop the next recording's Cancel registering")
    service.unregisterCancelHotkey()
    effects.refuseRemovals = false
    service.stop()
  }

  @Test("A hold interrupted by stop does not fire on a release that arrives afterwards")
  func stopClearsTheHold() {
    let (service, _, spy) = makeService()
    service.handleCarbonHotkey(id: pasteID, isRelease: false)
    service.stop()
    service.start()
    service.handleCarbonHotkey(id: pasteID, isRelease: true)
    #expect(fired(spy, "paste_last") == 0)
    service.stop()
  }

  @Test("A Carbon event arriving after stop or suspend fires nothing")
  func lateEventsAfterStopOrSuspend() {
    let (service, _, spy) = makeService()
    service.stop()
    service.handleCarbonHotkey(id: copyID, isRelease: false)
    #expect(fired(spy, "copy_last") == 0, "stopped")

    service.start()
    service.suspend()
    service.handleCarbonHotkey(id: copyID, isRelease: false)
    #expect(fired(spy, "copy_last") == 0, "suspended: the shortcut recorder is open")
    service.resume()
    service.handleCarbonHotkey(id: copyID, isRelease: false)
    #expect(fired(spy, "copy_last") == 1, "paired: live again after resume")
    service.stop()
  }

  @Test("A Paste press whose chord Cancel takes before the release does not fire")
  func releaseAfterCancelTakesTheChord() {
    let (service, _, spy) = makeService()
    service.cancelKeyCode = 9
    service.cancelModifiers = [.control, .command]
    service.handleCarbonHotkey(id: pasteID, isRelease: false)
    service.registerCancelHotkey()  // a recording starts while the chord is held
    service.handleCarbonHotkey(id: pasteID, isRelease: true)
    #expect(fired(spy, "paste_last") == 0)

    // Paired: after the recording, a fresh press and release pastes.
    service.unregisterCancelHotkey()
    service.handleCarbonHotkey(id: pasteID, isRelease: false)
    service.handleCarbonHotkey(id: pasteID, isRelease: true)
    #expect(fired(spy, "paste_last") == 1)
    service.stop()
  }

  @Test("Rebound to a bare modifier, Paste fires on that key's release")
  func bareModifierPaste() async {
    let (service, _, spy) = makeService()
    service.pasteLastKeyCode = ModifierKeyCodes.rightCommand
    service.pasteLastModifiers = []
    service.reapplyAppShortcutBinding(.pasteLast)

    service.handleFlagsChangedValues(keyCode: ModifierKeyCodes.rightCommand, flags: [.command])
    #expect(fired(spy, "paste_last") == 0)
    service.handleFlagsChangedValues(keyCode: ModifierKeyCodes.rightCommand, flags: [])
    #expect(fired(spy, "paste_last") == 1)
    #expect(await spy.wait(until: { spy.pastes == 1 }))
    service.stop()
  }

  /// The physical sequence the aggregate flag hides: Left Command held throughout, Right Command
  /// pressed and released. Right Command's release still carries `.command`, so a reading of the
  /// flag alone calls it a second press and Paste never fires.
  @Test("Bare Right Command Paste still fires on its release while Left Command is held")
  func bareModifierReleaseWithOtherSideHeld() async {
    let (service, _, spy) = makeService()
    service.pasteLastKeyCode = ModifierKeyCodes.rightCommand
    service.pasteLastModifiers = []
    service.reapplyAppShortcutBinding(.pasteLast)

    service.handleFlagsChangedValues(keyCode: ModifierKeyCodes.leftCommand, flags: [.command])
    service.handleFlagsChangedValues(keyCode: ModifierKeyCodes.rightCommand, flags: [.command])
    #expect(fired(spy, "paste_last") == 0)
    service.handleFlagsChangedValues(keyCode: ModifierKeyCodes.rightCommand, flags: [.command])
    #expect(fired(spy, "paste_last") == 1, "Right Command's release, read as a transition")
    service.handleFlagsChangedValues(keyCode: ModifierKeyCodes.leftCommand, flags: [])
    #expect(fired(spy, "paste_last") == 1, "Left Command coming up is not this shortcut")
    #expect(await spy.wait(until: { spy.pastes == 1 }))

    // And the next ordinary press and release still works: nothing was left latched.
    service.handleFlagsChangedValues(keyCode: ModifierKeyCodes.rightCommand, flags: [.command])
    service.handleFlagsChangedValues(keyCode: ModifierKeyCodes.rightCommand, flags: [])
    #expect(fired(spy, "paste_last") == 2)
    service.stop()
  }
}
