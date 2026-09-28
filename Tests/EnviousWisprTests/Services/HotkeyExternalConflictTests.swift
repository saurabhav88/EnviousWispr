import AppKit
import Foundation
import Observation
import Testing

@testable import EnviousWisprServices

/// #3273 (issue #3266): Carbon returned `eventHotKeyExistsErr` (OSStatus -9878) for a
/// registration attempt. The underlying cause is unknown. The refusal is surfaced as
/// `HotkeyService.isCurrentBindingConflicted(_:)`, read by the Keybinds row.
///
/// Drives `HotkeyService.registerCancelHotkey()` against `RecordingDesktopHotkeyEffects`'
/// programmable `nextResults` queue — the one seam the suite already uses for "the service's
/// reaction to a Carbon refusal it did not choose," per that fake's own header comment.
@MainActor
@Suite(.tags(.productOutcome))
struct HotkeyExternalConflictTests {

  private static let hotKeyExistsStatus: Int32 = -9878

  @Test("A Carbon eventHotKeyExistsErr refusal marks the role's current binding conflicted")
  func refusalMarksConflicted() {
    let (service, effects) = makeHotkeyService()
    effects.nextResults = [.refused(status: Self.hotKeyExistsStatus)]
    service.registerCancelHotkey()
    #expect(service.isCurrentBindingConflicted(.cancel))
  }

  @Test(
    "A role whose removal Carbon refused is excluded from the external-conflict claim on its next refusal"
  )
  func retainedOwnRegistrationIsNotShownAsExternal() {
    // Cloud review finding (PR #3277): `forgetHotkey` drops the local token even when Carbon
    // refuses the removal (#3108's known, pre-existing gap), so a later `eventHotKeyExistsErr`
    // for the same role can mean "I am still holding my own old chord," not "something else is."
    let (service, effects) = makeHotkeyService()
    effects.nextResults = [.registered(DesktopEffectToken())]
    service.registerCancelHotkey()

    effects.refuseRemovals = true
    service.unregisterCancelHotkey()  // forgetHotkey's removal is refused
    effects.refuseRemovals = false

    effects.nextResults = [.refused(status: Self.hotKeyExistsStatus)]
    service.registerCancelHotkey()
    #expect(
      !service.isCurrentBindingConflicted(.cancel),
      "a role that may still hold its own old chord must not be shown as externally conflicted")
  }

  @Test("A chord retained after a refused removal stays excluded after another chord is removed")
  func retainedChordSurvivesAnotherChordsSuccessfulRemoval() {
    let (service, effects) = makeHotkeyService()
    service.registerCancelHotkey()  // chord A (Escape) registered
    effects.refuseRemovals = true
    service.unregisterCancelHotkey()  // A's removal refused: A may still be ours
    effects.refuseRemovals = false

    service.cancelKeyCode = 1  // chord B
    service.registerCancelHotkey()
    service.unregisterCancelHotkey()  // B removed cleanly; says nothing about A

    service.cancelKeyCode = ShortcutRole.cancel.defaultKeyCode  // back to A
    effects.nextResults = [.refused(status: Self.hotKeyExistsStatus)]
    service.registerCancelHotkey()
    #expect(
      !service.isCurrentBindingConflicted(.cancel),
      "chord A is still possibly held by this app, so -9878 for it is not another app's")
  }

  @Test("A chord another role of this app already holds is not shown as external")
  func chordHeldByAnotherRoleIsNotShownAsExternal() {
    let (service, effects) = makeHotkeyService()
    let mods: NSEvent.ModifierFlags = [.control, .option]
    service.toggleKeyCode = 49
    service.toggleModifiers = mods
    service.start()  // Record registers chord 49+control+option

    service.cancelKeyCode = 49
    service.cancelModifiers = mods
    effects.nextResults = [.refused(status: Self.hotKeyExistsStatus)]
    service.registerCancelHotkey()

    // Carbon id 3 is Cancel (`HotkeyID.cancel`, private to the service).
    #expect(effects.registrations.last?.id == 3, "the scripted refusal must reach Cancel")
    #expect(
      !service.isCurrentBindingConflicted(.cancel),
      "Record holds this chord in this process, so it is not another app's")
  }

  @Test("A chord accepted without a token is excluded from a later external claim")
  func acceptedWithoutTokenChordIsNotShownAsExternalLater() {
    let (service, effects) = makeHotkeyService()
    effects.nextResults = [.acceptedWithoutToken]
    service.registerCancelHotkey()  // registered with nothing to release it

    effects.nextResults = [.refused(status: Self.hotKeyExistsStatus)]
    service.registerCancelHotkey()  // token still nil, so it asks Carbon again
    #expect(!service.isCurrentBindingConflicted(.cancel))
  }

  @Test("A successful registration clears a prior conflict")
  func successClearsConflict() {
    let (service, effects) = makeHotkeyService()
    effects.nextResults = [.refused(status: Self.hotKeyExistsStatus)]
    service.registerCancelHotkey()
    #expect(service.isCurrentBindingConflicted(.cancel))

    service.unregisterCancelHotkey()
    effects.nextResults = [.registered(DesktopEffectToken())]
    service.registerCancelHotkey()
    #expect(!service.isCurrentBindingConflicted(.cancel))
  }

  @Test("A DIFFERENT refusal status does not trigger the conflict and clears a stale one")
  func differentStatusClearsStaleConflict() {
    let (service, effects) = makeHotkeyService()
    effects.nextResults = [.refused(status: Self.hotKeyExistsStatus)]
    service.registerCancelHotkey()
    #expect(service.isCurrentBindingConflicted(.cancel))

    service.unregisterCancelHotkey()
    effects.nextResults = [.refused(status: -9879)]  // eventHotKeyInvalidErr, a different cause
    service.registerCancelHotkey()
    #expect(!service.isCurrentBindingConflicted(.cancel))
  }

  @Test("acceptedWithoutToken clears a stale conflict")
  func acceptedWithoutTokenClearsStaleConflict() {
    let (service, effects) = makeHotkeyService()
    effects.nextResults = [.refused(status: Self.hotKeyExistsStatus)]
    service.registerCancelHotkey()
    #expect(service.isCurrentBindingConflicted(.cancel))

    service.unregisterCancelHotkey()
    effects.nextResults = [.acceptedWithoutToken]
    service.registerCancelHotkey()
    #expect(!service.isCurrentBindingConflicted(.cancel))
  }

  @Test("A conflict on the OLD binding does not survive a change to a different combo")
  func staleBindingDoesNotSurviveChange() {
    let (service, effects) = makeHotkeyService()
    effects.nextResults = [.refused(status: Self.hotKeyExistsStatus)]
    service.registerCancelHotkey()
    #expect(service.isCurrentBindingConflicted(.cancel))

    // Change Cancel's binding without ever re-attempting registration (Cancel while idle is
    // exactly this: the next real attempt is deferred until the next recording, #3273 §1).
    service.cancelKeyCode = 1
    #expect(!service.isCurrentBindingConflicted(.cancel))
  }

  @Test("An identical repeated refusal does not re-notify observers")
  func repeatedIdenticalRefusalDoesNotRenotify() async {
    let (service, effects) = makeHotkeyService()
    effects.nextResults = [.refused(status: Self.hotKeyExistsStatus)]
    service.registerCancelHotkey()
    #expect(service.isCurrentBindingConflicted(.cancel))

    let fired = ObservationFlag(false)
    withObservationTracking {
      _ = service.conflictedBindings
    } onChange: {
      fired.value = true
    }

    service.unregisterCancelHotkey()
    effects.nextResults = [.refused(status: Self.hotKeyExistsStatus)]  // identical binding, identical status
    service.registerCancelHotkey()
    await Task.yield()

    #expect(!fired.value, "an identical refusal must not write, and so must not notify")
  }

  @Test("A registration success with no prior conflict does not notify observers")
  func successWithNoPriorConflictDoesNotNotify() async {
    let (service, effects) = makeHotkeyService()

    let fired = ObservationFlag(false)
    withObservationTracking {
      _ = service.conflictedBindings
    } onChange: {
      fired.value = true
    }

    effects.nextResults = [.registered(DesktopEffectToken())]
    service.registerCancelHotkey()
    await Task.yield()

    #expect(
      !fired.value, "clearing an already-empty conflict set must not write, and so must not notify")
  }
}

/// Reference box so the `withObservationTracking` `onChange` callback (`@Sendable`, not
/// `@MainActor`) can flip a flag the test reads afterward. Same shape as `LiveRecordingStateTests`'
/// private `LockBox`, kept local to this file rather than shared, since both are single-test
/// fixtures with no shared owner.
private final class ObservationFlag: @unchecked Sendable {
  nonisolated(unsafe) var value: Bool
  init(_ initial: Bool) { self.value = initial }
}
