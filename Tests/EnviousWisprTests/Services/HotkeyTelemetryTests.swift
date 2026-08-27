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
// `.serialized` (#1987): the wire-payload case installs and restores the
// process-global `testEventHook`, so no sibling case may run beside it.
@Suite(.serialized) struct HotkeyTelemetryTests {

  /// Synchronous spy — records every sink call on the main actor. `@MainActor`
  /// per swift-patterns `mainactor-fntype-implicitly-sendable`.
  @MainActor final class Spy {
    struct Press: Equatable {
      let triggerSource: String
      let inputMode: String
      let keyShape: String
      /// #1987 — content-free class of the key that produced this press. Captured
      /// so the widened sink cannot silently drop it; every existing assertion in
      /// this suite is unchanged.
      let keyIdentity: String
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
        pressed: { [weak self] ts, im, ks, ki, pa in
          self?.presses.append(
            Press(
              triggerSource: ts, inputMode: im, keyShape: ks, keyIdentity: ki, pressAction: pa))
        })
    }
  }

  // `HotkeyID` raw values are private to `HotkeyService`; mirror them here.
  private let toggleID: UInt32 = 1
  private let cancelID: UInt32 = 3

  private func makeService(
    _ spy: Spy, mode: RecordingMode, modifierOnly: Bool = false
  ) -> HotkeyService {
    let service = HotkeyService(effects: RecordingDesktopHotkeyEffects(), telemetry: spy.sink)
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
          keyIdentity: "chord", pressAction: "start")
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
          keyIdentity: "chord", pressAction: "toggle")
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
          keyIdentity: "chord", pressAction: "cancel")
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
    // #2455 C2: an opaque `DesktopEffectToken` rather than a raw `NSObject`
    // monitor. The chokepoint's contract is unchanged — report a nil install,
    // pass anything else through untouched — but no `NSEvent` value reaches this
    // module any more.
    let token = DesktopEffectToken()
    let returned = service.recordMonitorInstall(token, scope: "local")
    #expect(spy.registrations.isEmpty)
    #expect(returned == token)
  }

  @Test("default .noop sink stays inert — press still processed, nothing emitted")
  func defaultNoopIsInert() {
    // Codex r3: the default `HotkeyService()` (no telemetry param) must stay inert
    // so the existing `HotkeyService()` construction sites are behaviorally
    // unchanged. The press still flows through the state machine (isModifierHeld
    // flips) but the no-op closures swallow every emit.
    let service = HotkeyService(effects: RecordingDesktopHotkeyEffects())  // `.noop` default
    service.recordingMode = .pushToTalk
    service.toggleKeyCode = 0
    service.handleCarbonHotkey(id: toggleID, isRelease: false)
    _ = service.recordMonitorInstall(nil, scope: "global")
    #expect(service.isModifierHeld)  // press was processed normally
  }

  // MARK: - #1987 key identity

  @Test("The two keys we report on by name classify as themselves")
  func namedKeys() {
    #expect(HotkeyKeyIdentity.classify(keyCode: ModifierKeyCodes.globe) == .globe)
    #expect(HotkeyKeyIdentity.classify(keyCode: ModifierKeyCodes.rightOption) == .rightOption)
  }

  @Test(
    "Every other standalone modifier classifies as other_modifier",
    arguments: [UInt16(55), 54, 58, 56, 60, 59, 62])
  func otherModifiers(code: UInt16) {
    #expect(HotkeyKeyIdentity.classify(keyCode: code) == .otherModifier)
  }

  @Test(
    "Non-modifier keys classify as chord",
    arguments: [UInt16(0), 49, 53, 123, 122])
  func chordKeys(code: UInt16) {
    #expect(HotkeyKeyIdentity.classify(keyCode: code) == .chord)
  }

  /// These strings land in PostHog and get written into saved queries, so a rename
  /// silently returns zero rows forever rather than failing. Frozen deliberately.
  @Test("Raw values are frozen, because dashboards are built on them")
  func rawValuesAreStable() {
    #expect(HotkeyKeyIdentity.globe.rawValue == "globe")
    #expect(HotkeyKeyIdentity.rightOption.rawValue == "right_option")
    #expect(HotkeyKeyIdentity.otherModifier.rawValue == "other_modifier")
    #expect(HotkeyKeyIdentity.chord.rawValue == "chord")
  }

  /// The privacy boundary in test form: no case may ever carry a key code.
  @Test("No classification value contains a digit, so no key code can leak")
  func neverEmitsAKeyCode() {
    for identity in [
      HotkeyKeyIdentity.globe, .rightOption, .otherModifier, .chord,
    ] {
      #expect(
        identity.rawValue.rangeOfCharacter(from: .decimalDigits) == nil,
        "\(identity.rawValue) contains a digit; key codes must never reach telemetry")
    }
  }

  #if DEBUG
    /// Proves the REAL `hotkey.pressed` payload carries `key_identity`, not just a
    /// test-only projection of it. Before this chunk the DEBUG projection was built
    /// independently of `props`, so a projection test could have passed while the
    /// shipped event carried nothing; the projection is now derived from the same
    /// dictionary PostHog receives.
    final class EventBox: @unchecked Sendable {
      private let lock = NSLock()
      private var stored: CapturedTelemetryEvent?

      func set(_ event: CapturedTelemetryEvent) {
        lock.withLock { stored = event }
      }

      var value: CapturedTelemetryEvent? {
        lock.withLock { stored }
      }
    }

    @Test("hotkey.pressed wire payload carries key_identity without a raw key code")
    func wirePayloadCarriesIdentity() {
      let box = EventBox()
      let previousHook = TelemetryService.shared.testEventHook
      TelemetryService.shared.testEventHook = { event in
        if event.name == "hotkey.pressed" { box.set(event) }
      }
      defer { TelemetryService.shared.testEventHook = previousHook }

      TelemetryService.shared.hotkeyPressed(
        triggerSource: "ptt_hotkey", inputMode: "pushToTalk", keyShape: "modifier_only",
        keyIdentity: "globe", pressAction: "start")

      #expect(
        box.value?.stringProps == [
          "trigger_source": "ptt_hotkey", "input_mode": "pushToTalk",
          "key_shape": "modifier_only", "key_identity": "globe", "press_action": "start",
        ])

      // The privacy assertion has to span EVERY typed bucket, not just strings.
      // A raw key code would arrive as an Int, so checking `stringProps["key_code"]`
      // asks the one bucket that cannot hold the thing being looked for: the check
      // would pass while PostHog received the code. Reading the union means a leak
      // in any bucket fails this test whatever its type.
      let event = box.value
      let allKeys =
        Set(event?.stringProps.keys ?? [:].keys)
        .union(event?.intProps.keys ?? [:].keys)
        .union(event?.doubleProps.keys ?? [:].keys)
        .union(event?.boolProps.keys ?? [:].keys)

      #expect(
        allKeys == [
          "trigger_source", "input_mode", "key_shape", "key_identity", "press_action",
        ],
        "hotkey.pressed carries an unexpected property: \(allKeys.sorted())")
      #expect(event?.intProps.isEmpty == true)
      #expect(event?.doubleProps.isEmpty == true)
      #expect(event?.boolProps.isEmpty == true)
    }
  #endif

}
