import AppKit
import EnviousWisprServices
import SwiftUI

/// D5's standalone Setup screen. The caller reads and commits the existing record shortcut.
struct SetupShortcutScreen: View {
  let binding: ShortcutBinding
  let downloadsComplete: Bool
  let changeShortcut: (ShortcutBinding) -> ShortcutRefusal?
  let onContinue: () -> Void
  let onBack: () -> Void
  var monitor: (any SetupShortcutMonitoring)? = nil
  var suspendHotkeys: () -> Void = {}
  var resumeHotkeys: () -> Void = {}
  var reduceMotionOverride: Bool? = nil

  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.overlayReduceMotionOverride) private var inheritedReduceMotion
  @State private var input = SetupShortcutInput.WindowInput()
  @State private var rehearsal = SetupShortcutRehearsal()
  @State private var isCapturing = false
  @State private var refusal: ShortcutRefusal?

  private var headline: LocalizedStringKey {
    downloadsComplete ? "Ready to dictate!" : "Meet your dictation key"
  }

  private var captureHint: LocalizedStringKey {
    isCapturing ? "Press any key or shortcut. Esc cancels." : "Or pick one of these keys"
  }

  private var reduceMotion: Bool {
    reduceMotionOverride ?? inheritedReduceMotion ?? systemReduceMotion
  }

  private var keyCode: UInt16 {
    switch binding {
    case .keyboard(let keyCode, _): keyCode
    }
  }

  private var display: String {
    KeySymbols.format(keyCode: keyCode, modifiers: binding.requiredModifiers)
  }

  private var demoLabel: String {
    if binding.isBareModifier, let flag = ModifierKeyCodes.flag(for: keyCode) {
      if keyCode == ModifierKeyCodes.globe { return "fn" }
      return KeySymbols.symbolsForModifiers(flag)
    }
    return display
  }

  var body: some View {
    VStack(spacing: 0) {
      RainbowLipsView(
        animationState: rehearsal.isDown ? .equalizer : .ready, size: SetupMetrics.heroLips
      )
      .environment(\.overlayReduceMotionOverride, reduceMotion)
      .accessibilityHidden(true)
      .padding(.bottom, DesignSpacing.lg)
      Text(headline)
        .font(.firstRunDisplay)
        .foregroundStyle(Color.obTextPrimary)
        .accessibilityAddTraits(.isHeader)
      Text("Tap the key to change it.\nHold it or double-press it to try it now.")
        .font(.firstRunBody)
        .foregroundStyle(Color.obTextSecondary)
        .multilineTextAlignment(.center)
        .padding(.top, DesignSpacing.md)
        .padding(.bottom, ShortcutLayout.cardInset)
      shortcutCard
      Spacer(minLength: 0)
      SetupFooter(title: "Try your first dictation", action: { leave(onContinue) }) {
        Text("You can change the key any time in Settings.")
          .font(.firstRunCaption)
          .foregroundStyle(Color.obTextSecondary)
      }
    }
    .background {
      SetupShortcutInput(
        windowInput: input, monitor: monitor, suspend: suspendHotkeys, resume: resumeHotkeys,
        onInterrupted: interrupt, onEvent: rehearse
      )
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
    }
    .background(alignment: .topLeading) {
      Button("Back", action: { leave(onBack) })
        .keyboardShortcut(.cancelAction)
        .disabled(isCapturing)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    .onChange(of: binding) {
      rehearsal = SetupShortcutRehearsal()
      refusal = nil
    }
  }

  private var shortcutCard: some View {
    VStack(spacing: DesignSpacing.xl) {
      mainKey
      Text(captureHint)
        .font(.firstRunCaption)
        .foregroundStyle(Color.obTextSecondary)
        .multilineTextAlignment(.center)
      if let refusal {
        Text(verbatim: HotkeyRecorderView.message(for: refusal))
          .font(.firstRunCaption)
          .foregroundStyle(Color.firstRunErrorText)
          .multilineTextAlignment(.center)
      }
      keyboardRow
      Rectangle().fill(Color.firstRunRule).frame(height: 1).accessibilityHidden(true)
      SetupShortcutDemos(label: demoLabel, rehearsal: rehearsal, reduceMotion: reduceMotion)
    }
    .padding(ShortcutLayout.cardInset)
    .frame(maxWidth: ShortcutLayout.cardWidth)
    .background(
      RoundedRectangle(cornerRadius: DesignRadius.xxl, style: .continuous).fill(Color.obCardBg)
    )
    .overlay {
      RoundedRectangle(cornerRadius: DesignRadius.xxl, style: .continuous)
        .strokeBorder(Color.firstRunRule, lineWidth: 1)
        .allowsHitTesting(false)
    }
  }

  private var mainKey: some View {
    Button(action: toggleCapture) {
      SetupShortcutKeycap(
        display: display, isCapturing: isCapturing, isDown: rehearsal.isDown)
    }
    .buttonStyle(.plain)
    .padding(.top, DesignSpacing.xs)
    .offset(y: rehearsal.isDown && !reduceMotion ? DesignSpacing.xxs : 0)
    .accessibilityLabel("Change dictation key")
    .accessibilityValue(
      isCapturing
        ? String(localized: "Press any key or shortcut. Esc cancels.")
        : KeySymbols.accessibilityDescription(
          keyCode: keyCode, modifiers: binding.requiredModifiers)
    )
    .background {
      KeyCaptureView(isRecording: isCapturing, onKeyEvent: capture)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
  }

  private var keyboardRow: some View {
    HStack(spacing: DesignSpacing.xs) {
      ForEach(SetupShortcutKey.allCases, id: \.self) { key in
        if let code = key.code {
          let candidate = ShortcutBinding.keyboard(keyCode: code, modifiers: [])
          Button {
            accept(candidate)
          } label: {
            key.face(selected: binding == candidate)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(key.name)
          .accessibilityAddTraits(binding == candidate ? .isSelected : [])
        } else {
          key.face(selected: false).accessibilityHidden(true)
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Popular dictation keys")
  }

  private func rehearse(_ event: NSEvent) -> Bool {
    guard !isCapturing else { return false }
    return rehearsal.handle(event, binding: binding)
  }

  private func toggleCapture() {
    rehearsal.interrupt()
    refusal = nil
    isCapturing.toggle()
  }

  private func interrupt() {
    rehearsal.interrupt()
    isCapturing = false
  }

  private func leave(_ action: () -> Void) {
    input.finish()
    action()
  }

  private func capture(_ event: NSEvent) {
    guard isCapturing else { return }
    if HotkeyCapture.isCancel(event) {
      isCapturing = false
    } else {
      let candidate = HotkeyCapture.binding(for: event)
      accept(.keyboard(keyCode: candidate.keyCode, modifiers: candidate.modifiers))
    }
  }

  private func accept(_ candidate: ShortcutBinding) {
    isCapturing = false
    rehearsal.interrupt()
    refusal = changeShortcut(candidate)
  }
}
