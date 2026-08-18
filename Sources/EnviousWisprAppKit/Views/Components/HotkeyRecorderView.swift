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
      // Stop holding focus the instant recording ends. `acceptsFirstResponder`
      // going false does not resign an existing first-responder status, so without
      // this the view keeps receiving keys until something else takes focus.
      guard !isRecording, oldValue, let window, window.firstResponder === self else { return }
      window.makeFirstResponder(nil)
    }
  }

  override var acceptsFirstResponder: Bool { isRecording }

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
    onKeyEvent?(event)
    return true
  }

  /// Called for regular key presses that are not key equivalents (plain letters, etc.).
  override func keyDown(with event: NSEvent) {
    guard isRecording else {
      super.keyDown(with: event)
      return
    }
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

    // Determine which device-independent modifier bits changed compared to the
    // previous event. NSEvent does not expose a "previous flags" property, so
    // we rely on the keyCode to identify the specific modifier key that changed
    // and the direction of the transition from the modifier flags themselves.
    let currentFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

    // Map the physical key code to the modifier flag it represents. One shared
    // authority with the dispatch path (#1987): nil means "not a standalone
    // modifier", which is distinguishable from a real flag in a way an empty
    // OptionSet is not.
    guard let addedFlag = ModifierKeyCodes.flag(for: event.keyCode) else { return }

    // Only forward the event when the modifier is being pressed (added), not released.
    if currentFlags.contains(addedFlag) {
      onKeyEvent?(event)
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
  static func binding(for event: NSEvent) -> (keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
    let keyCode = event.keyCode
    if event.type == .flagsChanged && ModifierKeyCodes.isModifierOnly(keyCode) {
      return (keyCode, [])
    }
    return (keyCode, event.modifierFlags.intersection(.deviceIndependentFlagsMask))
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
      .cornerRadius(6)
      .overlay(
        RoundedRectangle(cornerRadius: 6)
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
        in: RoundedRectangle(cornerRadius: 10)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10)
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
  let onKeyEvent: (NSEvent) -> Void
  let onToggle: () -> Void

  func body(content: Content) -> some View {
    content
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
