import AppKit
import EnviousWisprServices
import SwiftUI

// MARK: - KeyCaptureNSView

/// Custom NSView subclass that intercepts key events — including system key equivalents
/// (Command+Arrow, Option+Arrow, etc.) — before macOS consumes them.
final class KeyCaptureNSView: NSView {
  var onKeyEvent: ((NSEvent) -> Void)?

  /// #1987 — whether the owner is actively recording a shortcut.
  ///
  /// All three handlers below and first-responder eligibility read this one flag,
  /// but they did NOT share the same history, and the difference matters to anyone
  /// tempted to relax one of them:
  ///
  /// - `keyDown` and `flagsChanged` relied on this hidden view never becoming first
  ///   responder outside recording, because the only `makeFirstResponder` call sat
  ///   in the recording branch. That is an absence of opportunity, not a guard.
  ///   #1987 removed the absence by making the enclosing control `.focusable()` so
  ///   the guidance popover could return focus to it, and the founder then hit the
  ///   consequence in live UAT (2026-08-09): landing on the Keybinds page and
  ///   typing rebound the shortcut with no click and no "press a key" prompt.
  /// - `performKeyEquivalent` was already unsafe before #1987 and for a different
  ///   reason. See its own note below.
  ///
  /// Gated here rather than in each owner because this view is the event SOURCE and
  /// both recording surfaces share it. A per-owner check would have to be repeated
  /// and could be forgotten by the next surface.
  var isRecording = false {
    didSet {
      // `updateNSView` assigns this on EVERY SwiftUI update pass, not only when it
      // changes, so an unguarded body would wipe an in-progress capture on any
      // unrelated redraw. #2613's state below only survives because of this guard.
      guard isRecording != oldValue else { return }
      resetCaptureState()

      // Stop holding focus the instant recording ends. `acceptsFirstResponder`
      // going false does not resign an existing first-responder status, so without
      // this the view keeps receiving keys until something else takes focus.
      guard !isRecording, let window, window.firstResponder === self else { return }
      window.makeFirstResponder(nil)
    }
  }

  override var acceptsFirstResponder: Bool { isRecording }

  /// #2613 — re-take the physically-held snapshot at the moment event delivery is
  /// actually OWNED, not when the box was armed.
  ///
  /// `updateNSView` arms this view and then defers `makeFirstResponder` into a
  /// `Task`, so there is a real gap in which the box is armed and someone else
  /// still owns the keyboard. A modifier pressed inside that gap is never seen
  /// going down, and its release is then read as a press — the same phantom the
  /// neutral boundary exists to prevent, arriving through a door the arming-time
  /// read cannot watch. If the phantom is Globe, every later key is refused as a
  /// Globe chord and the box goes silently dead.
  ///
  /// **This covers the FIRST acquisition only, and that is not the whole gap.**
  /// AppKit does not call this again when the user leaves the app and comes back,
  /// because the window keeps its stored first responder across losing key status —
  /// so no responder change happens and nothing here fires. Key events do go
  /// elsewhere while the window is not key, which is a second window of missed
  /// transitions with the same phantom outcome. `windowDidBecomeKey` below closes
  /// that one; neither is sufficient alone.
  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted, isRecording { resetCaptureState() }
    return accepted
  }

  /// #2613 — the SECOND gap: key events went to another application while this
  /// window was not key, so any modifier transition in that period was never seen.
  ///
  /// Failing sequence without this: click the box, hold Shift, click another app
  /// while still holding it, release Shift there, come back, press Shift. The
  /// release was missed, so Shift is still in `held`, and that press is read as a
  /// release — committing bare Shift on the way DOWN, with the user never having
  /// finished.
  ///
  /// **Re-syncing on RETURN is not the same action as ending a capture on focus
  /// LOSS, which this plan deliberately left alone (#2624).** That one can cancel
  /// work the user is in the middle of, and this repo measured it cancelling the
  /// Quick Add panel 339 ms after opening. This cannot cancel anything: it only
  /// replaces a stale belief about which keys are down with a fresh reading.
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    NotificationCenter.default.removeObserver(
      self, name: NSWindow.didBecomeKeyNotification, object: nil)
    guard let window else { return }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowDidBecomeKey),
      name: NSWindow.didBecomeKeyNotification,
      object: window)
  }

  @objc private func windowDidBecomeKey() {
    guard isRecording, window?.firstResponder === self else { return }
    resetCaptureState()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - #2613 capture state
  //
  // Until #2613 this view was stateless between events and forwarded the FIRST one
  // it saw. Because a bare modifier is a legal shortcut here (the default record key
  // is a bare right Option, and #1987 added Globe), a modifier press was already a
  // complete binding — so pressing Control as the first half of Control-Shift-W
  // saved Control and stopped listening, and no combination could be entered at all.
  //
  // `onKeyEvent` now means "this event COMPLETES a binding", not "a key happened".
  // Restoring unconditional forwarding reintroduces #2613.

  /// Known standalone modifier key codes currently DOWN.
  ///
  /// **Direction comes from membership here, never from the event's modifier flag.**
  /// Left and right Shift are two key codes sharing one `.shift` flag, so the flag
  /// cannot say which of them moved: releasing left while right is held reports the
  /// flag as still present. `HotkeyService.handleFlagsChangedValues` uses the flag
  /// test and carries a documented workaround for exactly that
  /// (`HotkeyService.swift:1205-1216`); this path does not repeat it.
  private var held: Set<UInt16> = []

  /// Every key code this capture has ADMITTED. Ambient modifiers rejected by
  /// `ModifierKeyCodes.flag(for:)` — Caps Lock, Help — never enter, so toggling
  /// Caps Lock mid-capture cannot change what commits.
  private var seen: Set<UInt16> = []

  /// A completion has already been forwarded. Idempotence only — it carries no
  /// policy. Both owners stop recording through a deferred `Task`, and this view
  /// only learns about it on the next SwiftUI update, so without this a held key's
  /// auto-repeat can forward a second binding inside that window.
  private var completed = false

  /// Set at arming when a supported modifier is ALREADY physically down, and
  /// cleared when every one of them is released.
  ///
  /// Without it, `held` starts empty while a key is really down, so that key's
  /// RELEASE is read as a press and the next physical press is read as a release.
  /// The phantom then never clears: if it is Globe, every later key takes the
  /// refusal path below and the box goes silently dead. Waiting for a neutral
  /// boundary is what makes "absent from `held` means a press" true rather than
  /// merely usual — and a key already held when the box was clicked could not have
  /// been part of the shortcut anyway. Founder decision, 2026-09-03.
  private var awaitingNeutralBoundary = false

  /// The union of every flag a standalone modifier key can set, derived from the
  /// one mapping in `ModifierKeyCodes` rather than restated, so a key added there
  /// is covered here with no second edit.
  private static let trackedModifierFlags: NSEvent.ModifierFlags =
    ModifierKeyCodes.all.reduce(into: NSEvent.ModifierFlags()) { union, keyCode in
      union.formUnion(ModifierKeyCodes.flag(for: keyCode) ?? [])
    }

  /// The one piece of GLOBAL state this view reads, behind a seam.
  ///
  /// Not a guard and not a policy switch: it answers "which modifiers are physically
  /// down right now", which no `NSEvent` handed to a unit test can describe. Without
  /// the seam a suite could only test the empty-keyboard case, and it would go flaky
  /// the moment the person running it had a finger on Shift. Production never
  /// overrides it.
  var modifierFlagsNow: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }

  private func trackedFlagsDown() -> NSEvent.ModifierFlags {
    modifierFlagsNow().intersection(Self.trackedModifierFlags)
  }

  private func resetCaptureState() {
    held = []
    seen = []
    completed = false
    awaitingNeutralBoundary = isRecording && !trackedFlagsDown().isEmpty
  }

  /// True while the capture is armed but deliberately not listening yet.
  /// Consumes the event either way: the box is armed, so a key equivalent reaching
  /// it must not also perform its own action.
  private func consumedWhileWaitingForNeutralBoundary() -> Bool {
    guard awaitingNeutralBoundary else { return false }
    if trackedFlagsDown().isEmpty { awaitingNeutralBoundary = false }
    return true
  }

  /// Called BEFORE the system handles key equivalents (e.g. Command+Left, Option+Arrow).
  /// Returning true tells AppKit this view handled the event, preventing system consumption.
  ///
  /// AppKit can route a key equivalent through the view tree rather than to the
  /// first responder, so this arm fires even when this view holds no focus at all.
  /// That is why it needed the gate independently of the focus story above, and why
  /// it was unsafe before #1987 rather than because of it. Returning `true`
  /// unconditionally also told AppKit that every key equivalent REACHING this view
  /// was handled, so an ordinary shortcut on the page could both rebind the hotkey
  /// and fail to perform its own action.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard isRecording else { return super.performKeyEquivalent(with: event) }
    forwardIfNonModifierCompletesTheBinding(event)
    return true
  }

  /// Called for regular key presses that are not key equivalents (plain letters, etc.).
  override func keyDown(with event: NSEvent) {
    guard isRecording else {
      super.keyDown(with: event)
      return
    }
    forwardIfNonModifierCompletesTheBinding(event)
  }

  /// The non-modifier arm of #2613's table, shared by `keyDown` and
  /// `performKeyEquivalent` so the two cannot disagree about what completes.
  private func forwardIfNonModifierCompletesTheBinding(_ event: NSEvent) {
    guard !completed else { return }
    guard !consumedWhileWaitingForNeutralBoundary() else { return }

    // Auto-repeat. `completed` cannot cover this case on its own, because the Globe
    // refusal below forwards nothing and so leaves `completed` false while the same
    // physical key keeps repeating.
    guard !seen.contains(where: { !ModifierKeyCodes.isModifierOnly($0) }) else { return }
    seen.insert(event.keyCode)

    // A Globe chord cannot be registered — `.function` is not a Carbon modifier, so
    // `carbonModifiers` drops it and `symbolsForModifiers` never renders it. Saving
    // one would store, display and fire as the bare key alone: Globe+W would make W
    // a global hotkey. Refusing is the honest answer, and because W is now in
    // `seen`, the later Globe release takes the reset arm rather than committing
    // Globe the user never asked for.
    //
    // Keyed on the Globe KEY being held, never on `.function` being present: arrow
    // keys carry that flag, and `arrowKeysNotAccepted` exists because matching on it
    // once bound the recorder to an arrow key.
    guard !held.contains(ModifierKeyCodes.globe) else { return }

    completed = true
    onKeyEvent?(event)
  }

  /// Intercepts bare modifier key presses (e.g. Option alone, Command alone).
  ///
  /// A flagsChanged event fires on both press and release of a modifier key.
  /// We only forward it when the modifier count goes UP (a new modifier is added)
  /// so that releasing the key does not trigger a second recording action.
  override func flagsChanged(with event: NSEvent) {
    guard isRecording else {
      super.flagsChanged(with: event)
      return
    }
    guard !completed else { return }
    guard !consumedWhileWaitingForNeutralBoundary() else { return }

    // Map the physical key code to the modifier flag it represents. One shared
    // authority with the dispatch path (#1987): nil means "not a standalone
    // modifier", which is distinguishable from a real flag in a way an empty
    // OptionSet is not. Ambient modifiers land here — Caps Lock and Help — and are
    // dropped without entering `seen`, so toggling Caps Lock mid-capture changes
    // nothing about what commits.
    guard ModifierKeyCodes.flag(for: event.keyCode) != nil else { return }

    // PRESS. `held` is authoritative rather than the event's flag, and the neutral
    // boundary at arming is what makes "absent from `held`" mean a press rather
    // than the release of a key we never saw go down.
    guard held.contains(event.keyCode) else {
      held.insert(event.keyCode)
      seen.insert(event.keyCode)
      return
    }

    // RELEASE.
    held.remove(event.keyCode)

    // A bare-modifier binding is ONE key, so it commits only if this key is the
    // only thing this capture ever admitted. #1991 settled that bare modifiers are
    // legal for every role, so this arm has to keep working — it is the reason the
    // commit point is the release at all, and #1987's Globe key rides on it.
    if seen == [event.keyCode] {
      completed = true
      onKeyEvent?(event)
      return
    }

    // Nothing committed and nothing left down: start over, so a user who fumbles
    // can simply let go and try again without reopening the box.
    if held.isEmpty {
      seen = []
    }
  }
}

// MARK: - HotkeyCapture

/// #1987 — the single authority for what a captured key event MEANS.
///
/// Two surfaces record shortcuts: Settings, through `HotkeyRecorderView`, and
/// onboarding, through `KeycapHotkeyView`. Both already shared `KeyCaptureNSView`
/// for what they RECEIVE, but each carried its own copy of what to ACCEPT, so the
/// same press could bind differently depending on where the user set it. That
/// duplication became load-bearing when accepting a binding started deciding
/// whether to present the Globe guidance, which must happen exactly once across
/// both surfaces.
///
/// Free of `@Environment` and of any view state on purpose: the decision is a
/// function of the event alone, so it is provable without a rendered hierarchy.
enum HotkeyCapture {
  /// True when the event cancels recording instead of binding: Escape pressed
  /// alone. Restricted to real key presses, since a modifier change never cancels.
  static func isCancel(_ event: NSEvent) -> Bool {
    event.type != .flagsChanged
      && event.keyCode == 53
      && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
  }

  /// The shortcut a non-cancelling event binds to.
  ///
  /// A standalone modifier reports its OWN flag in `modifierFlags`, so storing
  /// that flag would require the user to hold Globe while pressing Globe and the
  /// shortcut could never fire. Those come back with empty modifiers; an ordinary
  /// chord keeps its modifiers.
  ///
  /// #2613 — a chord's modifiers are narrowed to `ShortcutMatcher.carbonEffectiveModifiers`,
  /// and the reason is that this function had no reachable chord case until #2613.
  /// `.deviceIndependentFlagsMask` also carries Caps Lock, Numeric Pad, Help and
  /// Function, and NEITHER consumer keeps them: `KeySymbols.symbolsForModifiers`
  /// renders only these four, and `HotkeyService.carbonModifiers` maps only these
  /// four on the way to `RegisterEventHotKey`. Storing a bit both of them drop
  /// gives a binding that displays and fires as something other than what is
  /// saved — a Caps-Lock-contaminated default stops comparing equal to its own
  /// default, and Globe+W would store as W with an invisible `.function`.
  ///
  /// Narrowing HERE rather than at the capture view is deliberate: this is the one
  /// authority both recording surfaces ask what an event MEANS, so a value the
  /// view produced and this function disagreed with would be the #1987 drift all
  /// over again. The set is not redefined here either — `ShortcutMatcher` already
  /// owns it and already documents why those four are the whole answer.
  static func binding(for event: NSEvent) -> (keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
    let keyCode = event.keyCode
    if event.type == .flagsChanged && ModifierKeyCodes.isModifierOnly(keyCode) {
      return (keyCode, [])
    }
    return (keyCode, event.modifierFlags.intersection(ShortcutMatcher.carbonEffectiveModifiers))
  }
}

// MARK: - KeyCaptureView

/// SwiftUI wrapper around `KeyCaptureNSView`. When `isRecording` is true the underlying
/// NSView becomes first responder so it receives all key input ahead of the system.
struct KeyCaptureView: NSViewRepresentable {
  let isRecording: Bool
  let onKeyEvent: (NSEvent) -> Void

  func makeNSView(context: Context) -> KeyCaptureNSView {
    let view = KeyCaptureNSView()
    view.onKeyEvent = onKeyEvent
    view.isRecording = isRecording
    return view
  }

  func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
    nsView.onKeyEvent = onKeyEvent
    // Set BEFORE requesting first responder: `acceptsFirstResponder` reads this,
    // so assigning it after would have AppKit refuse the very request below.
    // Assigning it also resigns focus when recording ends (see its `didSet`).
    nsView.isRecording = isRecording
    if isRecording {
      // Defer making first responder so the window is ready
      Task { @MainActor in
        nsView.window?.makeFirstResponder(nsView)
      }
    }
  }
}

// MARK: - HotkeyRecorderColors

struct HotkeyRecorderColors {
  var label: Color = .primary
  var fieldText: Color = .primary
  var fieldBackground: Color = Color.secondary.opacity(0.1)
  var recordingBackground: Color = Color.accentColor.opacity(0.2)
  var recordingBorder: Color = Color.accentColor
  var placeholder: Color = Color.secondary
  var resetIcon: Color = Color.secondary

  static let system = HotkeyRecorderColors()
}

// MARK: - HotkeyRecorderView

/// A reusable view for recording keyboard shortcuts.
/// Click to start recording, press a key combo to set, click again or press Escape to cancel.
struct HotkeyRecorderView: View {
  /// Visual layout. `.compact` is the original inline label + small field row.
  /// `.prominent` renders a large edit button with no inline label (the caller
  /// supplies its own title column, mockup #26) — the key symbol reads big with a
  /// "Click to change" affordance line and a reset link below when non-default.
  enum Style {
    case compact
    case prominent

    /// The radius of the field each style draws.
    ///
    /// **One owner, because three places now need to agree.** The field's
    /// `background`, its border `overlay`, and the hover tint
    /// `KeyCaptureBehavior` applies all have to describe the same shape, and
    /// each was free to name its own number. That is the shape of both #2447
    /// review findings -- a decision made in one place that a second place can
    /// silently contradict -- so it does not get to survive in the change that
    /// introduced the third reader.
    var fieldRadius: CGFloat {
      switch self {
      case .compact: return 6
      case .prominent: return 10
      }
    }
  }

  @Binding var keyCode: UInt16
  @Binding var modifiers: NSEvent.ModifierFlags

  let defaultKeyCode: UInt16
  let defaultModifiers: NSEvent.ModifierFlags
  let label: String
  var colors: HotkeyRecorderColors = .system
  var style: Style = .compact
  /// #1987 — fires after a binding is ACCEPTED, so the owning surface can decide
  /// whether to present the Globe-key guidance. Settings and onboarding have
  /// separate completion handlers, so the decision cannot live in this view; it
  /// belongs to `SettingsManager.claimGlobeKeyGuidancePresentation`.
  var onBindingAccepted: (UInt16, NSEvent.ModifierFlags) -> Void = { _, _ in }

  // PR10 of #763: hotkey suspend/resume dispatch through DictationRuntime
  // façade; the shared HotkeyService is no longer accessible via the former root state.
  @Environment(DictationRuntime.self) private var dictationRuntime

  @State private var isRecording = false

  private var isDefault: Bool {
    keyCode == defaultKeyCode && modifiers == defaultModifiers
  }

  var body: some View {
    Group {
      switch style {
      case .compact: compactBody
      case .prominent: prominentBody
      }
    }
    .onDisappear {
      stopRecording()
    }
  }

  // MARK: - Compact (inline label + small field)

  private var compactBody: some View {
    HStack {
      Text(label)
        .foregroundStyle(colors.label)
        .accessibilityHidden(true)
      Spacer()

      // Use onTapGesture on a plain view to avoid Button stealing key events
      HStack(spacing: 4) {
        if isRecording {
          Text("Press keys...")
            .foregroundStyle(colors.placeholder)
        } else {
          Text(KeySymbols.format(keyCode: keyCode, modifiers: modifiers))
            .foregroundStyle(colors.fieldText)
        }
      }
      .frame(minWidth: 100)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(isRecording ? colors.recordingBackground : colors.fieldBackground)
      .cornerRadius(Style.compact.fieldRadius)
      .overlay(
        RoundedRectangle(cornerRadius: Style.compact.fieldRadius)
          .stroke(isRecording ? colors.recordingBorder : Color.clear, lineWidth: 1)
      )
      .modifier(keyCaptureBehavior)

      // Reset button
      if !isDefault {
        Button(action: resetToDefault) {
          Image(systemName: "arrow.counterclockwise")
            .foregroundStyle(colors.resetIcon)
        }
        .buttonStyle(.plain)
        .help("Reset to default")
        .accessibilityLabel("Reset keybind to default")
      }
    }
  }

  // MARK: - Prominent (big edit button)

  private var prominentBody: some View {
    VStack(alignment: .trailing, spacing: 6) {
      HStack(spacing: 12) {
        Image(systemName: "keyboard")
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(.stAccent)
          .accessibilityHidden(true)
        Spacer(minLength: 0)
        VStack(spacing: 2) {
          if isRecording {
            Text("Press keys...")
              .font(.system(size: 17, weight: .semibold))
              .foregroundStyle(.stAccent)
          } else {
            Text(KeySymbols.format(keyCode: keyCode, modifiers: modifiers))
              .font(.system(size: 17, weight: .semibold))
              .foregroundStyle(.stTextPrimary)
            Text("Click to change")
              .font(.stHelper)
              .foregroundStyle(.stTextTertiary)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 16)
      .frame(maxWidth: .infinity, minHeight: 62)
      .background(
        isRecording ? Color.stAccentLight : Color.stPageBg,
        in: RoundedRectangle(cornerRadius: Style.prominent.fieldRadius)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Style.prominent.fieldRadius)
          .strokeBorder(Color.stAccent, lineWidth: isRecording ? 2 : 1.5)
      )
      .modifier(keyCaptureBehavior)

      if !isDefault {
        Button("Reset to default", action: resetToDefault)
          .buttonStyle(.plain)
          .font(.stHelper)
          .foregroundStyle(.stAccent)
          .accessibilityLabel("Reset keybind to default")
      }
    }
  }

  // MARK: - Shared capture behaviour

  /// The first-responder capture overlay, tap-to-record, and accessibility that
  /// both styles share. Factored out so the two layouts stay in lockstep.
  private var keyCaptureBehavior: some ViewModifier {
    KeyCaptureBehavior(
      isRecording: isRecording,
      label: label,
      // Spoken projection, not the visible one (#1987): the visible label leads
      // with an emoji for the Globe key. Visible text is unchanged.
      valueDescription: KeySymbols.accessibilityDescription(
        keyCode: keyCode, modifiers: modifiers),
      cornerRadius: style.fieldRadius,
      onKeyEvent: handleKeyEvent,
      onToggle: toggleRecording
    )
  }

  private func toggleRecording() {
    if isRecording {
      stopRecording()
    } else {
      startRecording()
    }
  }

  private func startRecording() {
    isRecording = true
    // Suspend all Carbon hotkeys so they don't swallow key combos during recording
    dictationRuntime.suspendHotkeys()
  }

  private func stopRecording() {
    isRecording = false
    // Resume Carbon hotkeys
    dictationRuntime.resumeHotkeys()
  }

  /// Stays `private`: this method reads `dictationRuntime` from `@Environment` via
  /// `stopRecording()`, so it traps outside a rendered hierarchy and no test can
  /// drive it. The parts a test needs — what an event means, and what accepting it
  /// does — live in `HotkeyCapture` and `acceptBinding(from:)`, neither of which
  /// touches the environment.
  private func handleKeyEvent(_ event: NSEvent) {
    if HotkeyCapture.isCancel(event) {
      Task { @MainActor in
        stopRecording()
      }
      return
    }

    Task { @MainActor in
      acceptBinding(from: event)
      stopRecording()
    }
  }

  /// #1987 — the acceptance EFFECT, extracted from `handleKeyEvent` so it is
  /// reachable without a rendered view hierarchy. `internal` (not `package`) per
  /// the chunk contract: the test target already uses
  /// `@testable import EnviousWisprAppKit`, and an AppKit-local declaration must
  /// not widen beyond that.
  ///
  /// Two things this shape buys beyond testability. The callback would otherwise
  /// need one invocation per acceptance branch, so a later edit could update one
  /// and miss the other; there is exactly one. And the bindings are written BEFORE
  /// the owner is notified, which both surfaces depend on: `onBindingAccepted`
  /// presents the Globe guidance, and the popover anchors on a control whose label
  /// must already read the new key.
  func acceptBinding(from event: NSEvent) {
    let accepted = HotkeyCapture.binding(for: event)
    keyCode = accepted.keyCode
    modifiers = accepted.modifiers
    onBindingAccepted(accepted.keyCode, accepted.modifiers)
  }

  private func resetToDefault() {
    keyCode = defaultKeyCode
    modifiers = defaultModifiers
  }
}

// MARK: - KeyCaptureBehavior

/// The shared interaction layer for both `HotkeyRecorderView` styles: a zero-size
/// `KeyCaptureView` overlay that steals first responder while recording, plus
/// tap-to-toggle and the button accessibility. Applied to whatever visual field
/// each style draws so the two never drift apart.
private struct KeyCaptureBehavior: ViewModifier {
  let isRecording: Bool
  let label: String
  let valueDescription: String
  /// The radius of the visual field this behaviour is attached to, so the hover
  /// tint follows the same shape. The two styles draw 6 and 10; passing it in
  /// keeps the one interaction layer from having to guess which it is wrapping.
  let cornerRadius: CGFloat
  let onKeyEvent: (NSEvent) -> Void
  let onToggle: () -> Void

  func body(content: Content) -> some View {
    content
      // A keybind field is a plain view with `onTapGesture`, deliberately not a
      // `Button` so a Button cannot swallow the key events being recorded (see
      // `.focusable()` in `KeybindsSettingsView`). The cost of that choice is
      // that it inherits none of a control's affordances, which is why the
      // field looked like a text label showing a shortcut rather than something
      // to click. Suppressed while RECORDING, where the field already has a
      // loud active treatment and a hover tint would fight it.
      .settingsHoverRow(cornerRadius: cornerRadius, isEnabled: !isRecording)
      // Overlay a zero-size KeyCaptureView so it can steal first responder
      // without affecting visual layout.
      .overlay(
        KeyCaptureView(isRecording: isRecording, onKeyEvent: onKeyEvent)
          .frame(width: 0, height: 0)
          .allowsHitTesting(false),
        alignment: .center
      )
      .contentShape(Rectangle())
      .onTapGesture { onToggle() }
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isButton)
      .accessibilityLabel(label)
      .accessibilityValue(
        isRecording ? "Recording, press a key combination" : valueDescription
      )
      .accessibilityHint("Activates recording. Then press the key combination you want.")
      .accessibilityAction { onToggle() }
  }
}
