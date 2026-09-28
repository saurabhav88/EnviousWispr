import Foundation
import Observation
import Testing

@testable import EnviousWisprServices

/// #3273 (issue #3266): a Carbon registration refusal caused by `eventHotKeyExistsErr`
/// (OSStatus -9878, "these keys are already claimed by something outside this app") is
/// surfaced as `HotkeyService.isCurrentBindingConflicted(_:)`, read by the Keybinds row.
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
