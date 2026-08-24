import AppKit
import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

/// #2381 — the Quick Add shortcut, on both mechanisms.
///
/// When this fails the user presses their Quick Add key and one of three things happens, all of
/// them silent: nothing at all, a RECORDING STARTS instead of the panel opening, or the shortcut is
/// stored and displayed while being completely inert. The third is #1991 verbatim, which is why
/// this suite exercises a bare modifier at all — the default is a chord, and a suite that only
/// tested the default would pass a build that is dead for anyone who rebinds.
///
/// **The dangerous shape is the fall-through.** Before this change the bare-modifier dispatch read
/// `if role == .cancel { … return }` and then ran the record path, so a role the matcher resolved
/// and the dispatch did not name started a recording. An `if` over an enum asserts nothing about
/// the members it omits, and it compiles perfectly.
@MainActor
@Suite("Quick Add shortcut — #2381", .tags(.productOutcome))
struct HotkeyQuickAddShortcutTests {

  private let rightCommand = ModifierKeyCodes.rightCommand
  private let rightOption = ModifierKeyCodes.rightOption
  /// `kVK_ANSI_D` — a plain chord record key, the shape that hid #1991's second blocker.
  private let chordKeyCode: UInt16 = 2
  /// `kVK_ANSI_W`, the Quick Add default.
  private let wKeyCode: UInt16 = 13

  /// The Carbon id Quick Add registers under.
  ///
  /// A literal because `handleCarbonHotkey(id:isRelease:)` takes a raw `UInt32` — the id IS the
  /// wire contract with Carbon, not an internal detail, so a test that could not name it would be
  /// testing something other than what the OS delivers.
  private let quickAddCarbonID: UInt32 = 4

  @MainActor final class Sink {
    var quickAdds = 0
    var cancels = 0
    var toggles = 0
    var presses: [(trigger: String, keyShape: String, action: String)] = []
  }

  /// Signal-based wait: the callback IS the signal, with a deadline only so a regression fails with
  /// a test name instead of hanging. A test that hangs on the defect it exists to catch reports
  /// nothing at all.
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
        // settle: deadline fallback around the callback signal; the callback cancels this
        try? await Task.sleep(for: timeout)
        self?.expire(id: id)
      }
      await withCheckedContinuation { continuation in pending = (id, continuation) }
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
    recordModifiers: NSEvent.ModifierFlags = [],
    cancelKey: UInt16,
    quickAddKey: UInt16,
    quickAddModifiers: NSEvent.ModifierFlags = []
  ) -> (HotkeyService, Sink, Waiter, Waiter, Waiter) {
    let sink = Sink()
    let quickAddWaiter = Waiter()
    let cancelWaiter = Waiter()
    let toggleWaiter = Waiter()
    let service = HotkeyService(
      telemetry: HotkeyTelemetrySink(
        registrationFailed: { _, _, _, _ in },
        pressed: { trigger, _, keyShape, _, action in
          sink.presses.append((trigger, keyShape, action))
        }))
    service.recordingMode = .toggle
    service.toggleKeyCode = recordKey
    service.toggleModifiers = recordModifiers
    service.cancelKeyCode = cancelKey
    service.cancelModifiers = []
    service.quickAddKeyCode = quickAddKey
    service.quickAddModifiers = quickAddModifiers
    service.onQuickAdd = {
      sink.quickAdds += 1
      quickAddWaiter.note()
    }
    service.onCancelRecording = {
      sink.cancels += 1
      cancelWaiter.note()
    }
    service.onToggleRecording = {
      sink.toggles += 1
      toggleWaiter.note()
    }
    return (service, sink, quickAddWaiter, cancelWaiter, toggleWaiter)
  }

  /// A modifier press: the flag is PRESENT on press and ABSENT on release, the shape real hardware
  /// produces (measured for #1987). Asserting on set membership instead would prove the key is
  /// accepted and nothing about what pressing it does.
  private func press(_ service: HotkeyService, _ keyCode: UInt16) {
    guard let flag = ModifierKeyCodes.flag(for: keyCode) else {
      Issue.record("\(keyCode) is not a modifier key code")
      return
    }
    service.handleFlagsChangedValues(keyCode: keyCode, flags: flag)
  }

  private func release(_ service: HotkeyService, _ keyCode: UInt16) {
    service.handleFlagsChangedValues(keyCode: keyCode, flags: [])
  }

  // MARK: - The fall-through

  @Test("A bare-modifier Quick Add opens Quick Add and does NOT start a recording")
  func bareModifierQuickAddDoesNotStartARecording() async {
    // The defect this suite exists for. With the dispatch written as `if role == .cancel`, this
    // press fell through to the record path and began dictating.
    let (service, sink, quickAdd, _, _) = makeService(
      recordKey: chordKeyCode, cancelKey: 53, quickAddKey: rightCommand)

    press(service, rightCommand)
    await quickAdd.wait()

    #expect(sink.quickAdds == 1)
    #expect(sink.toggles == 0, "a Quick Add press must never start a recording")
    #expect(sink.cancels == 0)
  }

  @Test("A modifier RELEASE is not a Quick Add gesture")
  func releaseDoesNotFireQuickAdd() async {
    let (service, sink, _, _, _) = makeService(
      recordKey: chordKeyCode, cancelKey: 53, quickAddKey: rightCommand)

    release(service, rightCommand)
    await Task.yield()

    #expect(sink.quickAdds == 0)
  }

  // MARK: - Ordering against cancel

  @Test("While a recording is running, a shared binding cancels rather than opening Quick Add")
  func cancelOutranksQuickAddWhileArmed() async {
    // Quick Add is armed at ALL times and cancel only during a recording, so ordering Quick Add
    // first would take the stop key away for the whole of every recording.
    let (service, sink, _, cancel, _) = makeService(
      recordKey: chordKeyCode, cancelKey: rightCommand, quickAddKey: rightCommand)
    service.registerCancelHotkey()

    press(service, rightCommand)
    await cancel.wait()

    #expect(sink.cancels == 1)
    #expect(sink.quickAdds == 0, "cancel must win while it is armed")
  }

  @Test("With no recording running, the same shared binding opens Quick Add")
  func quickAddWinsWhenCancelIsNotArmed() async {
    // The other half of the ordering: behind cancel, Quick Add still gets every moment cancel is
    // not armed, so a shared binding costs the user nothing they had before.
    let (service, sink, quickAdd, _, _) = makeService(
      recordKey: chordKeyCode, cancelKey: rightCommand, quickAddKey: rightCommand)

    press(service, rightCommand)
    await quickAdd.wait()

    #expect(sink.quickAdds == 1)
    #expect(sink.cancels == 0)
  }

  @Test("A Quick Add modifier that is part of the record chord is refused, not accepted")
  func quickAddSharingTheRecordChordIsRefused() async {
    // Accepting would open a panel that TAKES KEY FOCUS the instant the user pressed the first
    // half of their record chord, so the rest of the chord lands in the panel and the recording
    // never happens. The same refusal cancel makes, for the same reason one step over.
    let (service, sink, _, _, _) = makeService(
      recordKey: chordKeyCode, recordModifiers: [.command], cancelKey: 53,
      quickAddKey: rightCommand)

    press(service, rightCommand)
    await Task.yield()

    #expect(sink.quickAdds == 0, "ambiguous with starting the record chord")
    #expect(sink.toggles == 0)
  }

  // MARK: - The Carbon path, which the DEFAULT chord takes

  @Test("The Carbon hotkey fires Quick Add on press and not on release")
  func carbonDispatchFiresQuickAdd() async {
    let (service, sink, quickAdd, _, _) = makeService(
      recordKey: rightOption, cancelKey: 53, quickAddKey: wKeyCode,
      quickAddModifiers: [.control, .option])

    service.handleCarbonHotkey(id: quickAddCarbonID, isRelease: true)
    await Task.yield()
    #expect(sink.quickAdds == 0, "a key release is not a gesture")

    service.handleCarbonHotkey(id: quickAddCarbonID, isRelease: false)
    await quickAdd.wait()
    #expect(sink.quickAdds == 1)
    #expect(sink.toggles == 0)
    #expect(sink.cancels == 0)
  }

  // MARK: - Telemetry names the right subject

  @Test("A Quick Add press reports ITS OWN key shape, not the record key's")
  func telemetryReportsTheQuickAddKeyShape() async {
    // The binary collapse this change removed: `trigger == .cancel ? cancelKeyCode : toggleKeyCode`
    // absorbed any new member into the toggle branch, so a Quick Add press reported the RECORD
    // key's shape. Record is modifier-only here and Quick Add is a chord, so the two disagree.
    let (service, sink, quickAdd, _, _) = makeService(
      recordKey: rightOption, cancelKey: 53, quickAddKey: wKeyCode,
      quickAddModifiers: [.control, .option])

    service.handleCarbonHotkey(id: quickAddCarbonID, isRelease: false)
    await quickAdd.wait()

    let press = sink.presses.last
    #expect(press?.trigger == "quick_add_hotkey")
    #expect(press?.action == "quick_add")
    #expect(press?.keyShape == "chord", "reported the record key's modifier_only shape")
  }

  @Test("A record press still reports the record key's shape")
  func telemetryStillReportsTheRecordKeyShape() async {
    // The paired case. A switch that answered "chord" for everything would satisfy the test above.
    let (service, sink, _, _, toggle) = makeService(
      recordKey: rightOption, cancelKey: 53, quickAddKey: wKeyCode,
      quickAddModifiers: [.control, .option])

    press(service, rightOption)
    await toggle.wait()

    #expect(sink.presses.last?.trigger == "toggle_hotkey")
    #expect(sink.presses.last?.keyShape == "modifier_only")
  }
}
