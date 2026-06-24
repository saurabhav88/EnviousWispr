import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// #1175 (Telemetry Bible Phase 6) — hotkey/input-silence telemetry.
///
/// Drives `HotkeyService` through its public `handleCarbonHotkey` entry with a
/// SYNCHRONOUS spy `HotkeyTelemetrySink` (no process-global hook, no async) and
/// asserts the emitted `press_action` / `trigger_source` / `key_shape` and the
/// registration-failure path. `press_action` is derived entirely from
/// HotkeyService's own state — no pipeline read — so every value is reachable
/// here. The modifier-only `handleFlagsChangedValues` toggle site shares the same
/// helper and is covered by Live UAT (the shipped default).
@MainActor
@Suite struct HotkeyTelemetryTests {

  /// Synchronous spy — records every sink call on the main actor. `@MainActor`
  /// per swift-patterns `mainactor-fntype-implicitly-sendable`.
  @MainActor final class Spy {
    struct Press: Equatable {
      let triggerSource: String
      let inputMode: String
      let keyShape: String
      let pressAction: String
    }
    struct Registration: Equatable {
      let mechanism: String
      let hotkeyKind: String
      let osStatus: Int32?
      let keyShape: String
    }
    var presses: [Press] = []
    var registrations: [Registration] = []

    var sink: HotkeyTelemetrySink {
      HotkeyTelemetrySink(
        registrationFailed: { [weak self] mechanism, kind, status, shape in
          self?.registrations.append(
            Registration(mechanism: mechanism, hotkeyKind: kind, osStatus: status, keyShape: shape))
        },
        pressed: { [weak self] ts, im, ks, pa in
          self?.presses.append(
            Press(triggerSource: ts, inputMode: im, keyShape: ks, pressAction: pa))
        })
    }
  }

  // `HotkeyID` raw values are private to `HotkeyService`; mirror them here.
  private let toggleID: UInt32 = 1
  private let cancelID: UInt32 = 3

  private func makeService(
    _ spy: Spy, mode: RecordingMode, modifierOnly: Bool = false
  ) -> HotkeyService {
    let service = HotkeyService(telemetry: spy.sink)
    service.recordingMode = mode
    // keyCode 0 ('A') is a chord key; right Option (61) is modifier-only.
    service.toggleKeyCode = modifierOnly ? ModifierKeyCodes.rightOption : 0
    return service
  }

  @Test("PTT start press emits hotkey.pressed press_action=start")
  func pttStartEmits() {
    let spy = Spy()
    let service = makeService(spy, mode: .pushToTalk)
    service.handleCarbonHotkey(id: toggleID, isRelease: false)
    #expect(
      spy.presses == [
        .init(
          triggerSource: "ptt_hotkey", inputMode: "pushToTalk", keyShape: "chord",
          pressAction: "start")
      ])
  }

  @Test("toggle tap emits press_action=toggle, trigger=toggle_hotkey")
  func toggleEmits() {
    let spy = Spy()
    let service = makeService(spy, mode: .toggle)
    service.handleCarbonHotkey(id: toggleID, isRelease: false)
    #expect(
      spy.presses == [
        .init(
          triggerSource: "toggle_hotkey", inputMode: "toggle", keyShape: "chord",
          pressAction: "toggle")
      ])
  }

  @Test("cancel press emits press_action=cancel, trigger=cancel_hotkey")
  func cancelEmits() {
    let spy = Spy()
    let service = makeService(spy, mode: .pushToTalk)
    service.handleCarbonHotkey(id: cancelID, isRelease: false)
    #expect(
      spy.presses == [
        .init(
          triggerSource: "cancel_hotkey", inputMode: "pushToTalk", keyShape: "chord",
          pressAction: "cancel")
      ])
  }

  @Test("press blocked by processing emits press_action=ignored_processing")
  func processingBlockedEmits() {
    let spy = Spy()
    let service = makeService(spy, mode: .pushToTalk)
    service.onIsProcessing = { true }
    service.handleCarbonHotkey(id: toggleID, isRelease: false)
    #expect(spy.presses.count == 1)
    #expect(spy.presses.first?.pressAction == "ignored_processing")
  }

  @Test("key_shape reflects a modifier-only toggle key")
  func keyShapeModifierOnly() {
    let spy = Spy()
    let service = makeService(spy, mode: .toggle, modifierOnly: true)
    service.handleCarbonHotkey(id: toggleID, isRelease: false)
    #expect(spy.presses.first?.keyShape == "modifier_only")
  }

  @Test("cancel key_shape comes from the cancel key, not the toggle key (Codex #1)")
  func cancelKeyShapeFromCancelKey() {
    // Toggle is modifier-only (right Option); cancel is the default Escape (a
    // chord). A cancel press must report key_shape from the CANCEL key.
    let spy = Spy()
    let service = makeService(spy, mode: .pushToTalk, modifierOnly: true)
    // cancelKeyCode keeps its default (53 = Escape, a chord key).
    service.handleCarbonHotkey(id: cancelID, isRelease: false)
    #expect(spy.presses.first?.pressAction == "cancel")
    #expect(spy.presses.first?.keyShape == "chord")
  }

  @Test("hands-free double-press emits start then lock (Codex #2)")
  func doublePressLockEmits() {
    let spy = Spy()
    let service = makeService(spy, mode: .pushToTalk)
    service.handleCarbonHotkey(id: toggleID, isRelease: false)  // down 1 → start
    service.handleCarbonHotkey(id: toggleID, isRelease: true)  // up 1
    service.handleCarbonHotkey(id: toggleID, isRelease: false)  // down 2 (<500ms) → lock
    #expect(spy.presses.map(\.pressAction) == ["start", "lock"])
    #expect(spy.presses.allSatisfy { $0.triggerSource == "ptt_hotkey" })
  }

  @Test("hands-free triple-press emits start, lock, cancel (Codex #2)")
  func triplePressCancelEmits() {
    let spy = Spy()
    let service = makeService(spy, mode: .pushToTalk)
    service.handleCarbonHotkey(id: toggleID, isRelease: false)  // down 1 → start
    service.handleCarbonHotkey(id: toggleID, isRelease: true)  // up 1
    service.handleCarbonHotkey(id: toggleID, isRelease: false)  // down 2 → lock
    service.handleCarbonHotkey(id: toggleID, isRelease: true)  // up 2 (suppressed)
    service.handleCarbonHotkey(id: toggleID, isRelease: false)  // down 3 → triple cancel
    #expect(spy.presses.map(\.pressAction) == ["start", "lock", "cancel"])
    // The triple-press cancel is a PTT keydown, told apart from Escape by trigger.
    #expect(spy.presses.last?.triggerSource == "ptt_hotkey")
  }

  @Test("duplicate held press (no intervening release) emits only once")
  func dedupHeldEmitsOnce() {
    let spy = Spy()
    let service = makeService(spy, mode: .pushToTalk)
    service.handleCarbonHotkey(id: toggleID, isRelease: false)
    service.handleCarbonHotkey(id: toggleID, isRelease: false)  // held re-fire, ignored
    #expect(spy.presses.count == 1)
    #expect(spy.presses.first?.pressAction == "start")
  }

  @Test("monitor nil-install reports a registration failure")
  func monitorNilReportsFailure() {
    let spy = Spy()
    let service = makeService(spy, mode: .toggle, modifierOnly: true)
    _ = service.recordMonitorInstall(nil, scope: "global")
    #expect(
      spy.registrations == [
        .init(
          mechanism: "nsevent_global", hotkeyKind: "toggle", osStatus: nil,
          keyShape: "modifier_only")
      ])
  }

  @Test("non-nil monitor install reports nothing and returns the token")
  func monitorOkReportsNothing() {
    let spy = Spy()
    let service = makeService(spy, mode: .toggle, modifierOnly: true)
    let token = NSObject()
    let returned = service.recordMonitorInstall(token, scope: "local")
    #expect(spy.registrations.isEmpty)
    #expect((returned as? NSObject) === token)
  }

  @Test("default .noop sink stays inert — press still processed, nothing emitted")
  func defaultNoopIsInert() {
    // Codex r3: the default `HotkeyService()` (no telemetry param) must stay inert
    // so the existing `HotkeyService()` construction sites are behaviorally
    // unchanged. The press still flows through the state machine (isModifierHeld
    // flips) but the no-op closures swallow every emit.
    let service = HotkeyService()  // `.noop` default
    service.recordingMode = .pushToTalk
    service.toggleKeyCode = 0
    service.handleCarbonHotkey(id: toggleID, isRelease: false)
    _ = service.recordMonitorInstall(nil, scope: "global")
    #expect(service.isModifierHeld)  // press was processed normally
  }
}
