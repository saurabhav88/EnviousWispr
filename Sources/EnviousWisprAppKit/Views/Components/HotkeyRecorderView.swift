import AppKit
import EnviousWisprServices
import SwiftUI

// MARK: - KeyCaptureNSView

/// Custom NSView subclass that intercepts key events — including system key equivalents
/// (Command+Arrow, Option+Arrow, etc.) — before macOS consumes them.
final class KeyCaptureNSView: NSView {
  var onKeyEvent: ((NSEvent) -> Void)?

  override var acceptsFirstResponder: Bool { true }

  /// Called BEFORE the system handles key equivalents (e.g. Command+Left, Option+Arrow).
  /// Returning true tells AppKit this view handled the event, preventing system consumption.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    onKeyEvent?(event)
    return true
  }

  /// Called for regular key presses that are not key equivalents (plain letters, etc.).
  override func keyDown(with event: NSEvent) {
    onKeyEvent?(event)
  }

  /// Intercepts bare modifier key presses (e.g. Option alone, Command alone).
  ///
  /// A flagsChanged event fires on both press and release of a modifier key.
  /// We only forward it when the modifier count goes UP (a new modifier is added)
  /// so that releasing the key does not trigger a second recording action.
  override func flagsChanged(with event: NSEvent) {
    // Determine which device-independent modifier bits changed compared to the
    // previous event. NSEvent does not expose a "previous flags" property, so
    // we rely on the keyCode to identify the specific modifier key that changed
    // and the direction of the transition from the modifier flags themselves.
    let currentFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

    // Map the physical key code to the modifier flag it represents.
    let addedFlag = flagForModifierKeyCode(event.keyCode)
    guard addedFlag != [] else { return }  // not a recognised modifier key

    // Only forward the event when the modifier is being pressed (added), not released.
    if currentFlags.contains(addedFlag) {
      onKeyEvent?(event)
    }
  }

  /// Returns the NSEvent.ModifierFlags bit that corresponds to the given modifier key code.
  private func flagForModifierKeyCode(_ keyCode: UInt16) -> NSEvent.ModifierFlags {
    switch keyCode {
    case 55, 54: return .command
    case 58, 61: return .option
    case 59, 62: return .control
    case 56, 60: return .shift
    default: return []
    }
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
    return view
  }

  func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
    nsView.onKeyEvent = onKeyEvent
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
        .accessibilityLabel("Reset shortcut to default")
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
          .accessibilityLabel("Reset shortcut to default")
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
      valueDescription: KeySymbols.format(keyCode: keyCode, modifiers: modifiers),
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

  private func handleKeyEvent(_ event: NSEvent) {
    // Escape with no modifiers cancels recording (only from keyDown / performKeyEquivalent)
    if event.type != .flagsChanged
      && event.keyCode == 53
      && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
    {
      Task { @MainActor in
        stopRecording()
      }
      return
    }

    let newKeyCode = event.keyCode

    // Modifier-only hotkey: the keyCode IS the modifier key.
    // Store the key code as-is and clear modifiers — the modifier IS the key,
    // so there is no additional modifier to hold down.
    if event.type == .flagsChanged && ModifierKeyCodes.isModifierOnly(newKeyCode) {
      Task { @MainActor in
        keyCode = newKeyCode
        modifiers = []
        stopRecording()
      }
      return
    }

    let newModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

    Task { @MainActor in
      keyCode = newKeyCode
      modifiers = newModifiers
      stopRecording()
    }
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
