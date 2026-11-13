import SwiftUI

/// Setup's Permissions screen (#4528 D4b, plan M81; mockup `isPermissions`, copy verbatim).
///
/// Plain inputs only: the two live permission states, the injected actions, the dictation key's
/// name and `onContinue`/`onBack`. It reads and sends no flow event and writes no setting; the
/// router hooks it to the `.permissions` step, and the flow's own auto-advance moves on once both
/// permissions are on. Reduce Motion comes from `overlayReduceMotionOverride`, like its siblings.
struct SetupPermissionsScreen: View {
  let microphone: SetupPermissions.Microphone
  let accessibilityAllowed: Bool
  /// The dictation key's name for the Accessibility card ("such as Right Option").
  let dictationKey: String
  let actions: SetupPermissionsActions
  let onContinue: () -> Void
  let onBack: () -> Void

  /// Rows waiting for the switch in System Settings after Open Settings (view-local; cleared once
  /// that permission is on).
  @State private var waiting: SetupPermissions.Waiting
  /// The mockup's grant bounce: bumped each time a permission turns on while the screen is shown.
  @State private var burst = 0

  /// `waiting` seeds the view-local waiting rows (render checks); a live screen starts with none.
  init(
    microphone: SetupPermissions.Microphone, accessibilityAllowed: Bool, dictationKey: String,
    actions: SetupPermissionsActions, onContinue: @escaping () -> Void,
    onBack: @escaping () -> Void, waiting: SetupPermissions.Waiting = .init()
  ) {
    self.microphone = microphone
    self.accessibilityAllowed = accessibilityAllowed
    self.dictationKey = dictationKey
    self.actions = actions
    self.onContinue = onContinue
    self.onBack = onBack
    var seeded = waiting
    seeded.sync(microphone: microphone, accessibilityAllowed: accessibilityAllowed)
    _waiting = State(initialValue: seeded)
  }

  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.overlayReduceMotionOverride) private var reduceMotionOverride
  private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

  private var both: Bool { SetupPermissions.bothAllowed(microphone, accessibilityAllowed) }
  private var isWaiting: Bool { waiting.isEmpty == false }

  var body: some View {
    VStack(spacing: 0) {
      RainbowLipsView(
        animationState: SetupPermissions.mood(
          microphone, accessibilityAllowed: accessibilityAllowed),
        size: SetupMetrics.screenLips, burst: burst
      )
      .padding(.bottom, DesignSpacing.lg)
      .accessibilityHidden(true)
      Text(SetupPermissions.title(microphone, accessibilityAllowed: accessibilityAllowed))
        .font(.firstRunDisplay)
        .multilineTextAlignment(.center)
        .foregroundStyle(Color.obTextPrimary)
        .accessibilityAddTraits(.isHeader)
      Text(SetupPermissions.subtitle(microphone, accessibilityAllowed: accessibilityAllowed))
        .font(.firstRunBody)
        .fixedSize(horizontal: false, vertical: true)
        .multilineTextAlignment(.center)
        .foregroundStyle(Color.obTextSecondary)
        .padding(.top, DesignSpacing.md)
        .padding(.bottom, DesignSpacing.xxxl - DesignSpacing.xs)
      VStack(spacing: DesignSpacing.md) {
        microphoneRow
        accessibilityRow
      }
      Spacer(minLength: 0)
      footer
      // Visible way back (D6, orchestrator D4b r0): a mouse-only person on a Mac whose
      // microphone is restricted by management cannot turn it on and must not be stuck here.
      // Escape triggers the same link.
      SetupLinkButton(title: "Back", quiet: true, action: onBack)
        .keyboardShortcut(.cancelAction)
        .padding(.top, DesignSpacing.xs)
    }
    .padding(.top, DesignSpacing.xs)
    .onChange(of: microphone) { old, new in
      if new == .allowed, old != .allowed { granted() }
    }
    .onChange(of: accessibilityAllowed) { old, new in
      if new, !old { granted() }
    }
  }

  private func granted() {
    waiting.sync(microphone: microphone, accessibilityAllowed: accessibilityAllowed)
    if !reduceMotion { burst += 1 }
  }

  // MARK: - Rows

  @ViewBuilder private var microphoneRow: some View {
    switch SetupPermissions.microphoneRow(microphone) {
    case .allowed:
      SetupPermissionAllowedRow(
        symbol: "mic.fill", title: "Microphone", detail: "Allowed. Your audio stays on this Mac.",
        reduceMotion: reduceMotion)
    case .ask:
      SetupCard {
        VStack(alignment: .leading, spacing: DesignSpacing.xl) {
          header(
            .microphone, symbol: "mic.fill", title: "Microphone",
            detail: "So EnviousWispr can hear you.")
          Text("macOS will ask you once. Choose Allow.")
            .font(.firstRunBody)
            .foregroundStyle(Color.obTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
          HStack(spacing: DesignSpacing.md) {
            Image(systemName: "lock.fill")
              .font(.firstRunCaption)
              .foregroundStyle(Color.firstRunSuccessText)
              .accessibilityHidden(true)
            Text("Your audio never leaves this Mac.")
              .font(.firstRunCaption)
              .foregroundStyle(Color.obTextSecondary)
          }
        }
      }
    case .fix:
      SetupCard {
        VStack(alignment: .leading, spacing: DesignSpacing.xl) {
          header(
            .microphone, symbol: "mic.fill", title: "Turn the microphone on",
            detail: "macOS has it switched off for EnviousWispr. One switch fixes it.")
          SetupSettingsPreview(pane: "Privacy & Security › Microphone", reduceMotion: reduceMotion)
          Text(
            "Flip this switch on. EnviousWispr notices by itself. If it still shows off, quit and reopen EnviousWispr."
          )
          .font(.firstRunCaption)
          .foregroundStyle(Color.obTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  @ViewBuilder private var accessibilityRow: some View {
    switch SetupPermissions.accessibilityRow(
      microphone: microphone, accessibilityAllowed: accessibilityAllowed)
    {
    case .allowed:
      SetupPermissionAllowedRow(
        symbol: "accessibility", title: "Accessibility",
        detail: "Allowed. Your words can land in any app.", reduceMotion: reduceMotion)
    case .later:
      HStack(spacing: DesignSpacing.xl) {
        SetupPermissionTile(symbol: "accessibility", allowed: false)
        rowText(title: "Accessibility", detail: "So your words land in any app.")
        Text("Step 2 of 2")
          .textCase(.uppercase)
          .font(.firstRunEyebrow)
          .tracking(0.8)
          .foregroundStyle(Color.firstRunTextTertiary)
          .fixedSize()
      }
      .padding(.vertical, DesignSpacing.xl)
      .padding(.horizontal, DesignSpacing.xxl)
      .background(
        RoundedRectangle(cornerRadius: DesignRadius.xl, style: .continuous).fill(Color.obSurface)
      )
      .accessibilityElement(children: .combine)
    case .ask:
      SetupCard {
        VStack(alignment: .leading, spacing: DesignSpacing.xl) {
          header(
            .accessibility, symbol: "accessibility", title: "Accessibility",
            detail: "So your words land in any app.")
          SetupSettingsPreview(
            pane: "Privacy & Security › Accessibility", reduceMotion: reduceMotion)
          VStack(alignment: .leading, spacing: DesignSpacing.xs) {
            reason("It hears your dictation key, such as \(dictationKey).")
            reason("It pastes your words into the app you are using.")
            reason("It stays on your Mac. Nothing you type is sent to us.")
          }
        }
      }
      .modifier(SetupRise(delay: 0, reduceMotion: reduceMotion))
    }
  }

  private func header(
    _ row: SetupPermissions.Permission, symbol: String, title: LocalizedStringKey,
    detail: LocalizedStringKey
  ) -> some View {
    HStack(spacing: DesignSpacing.xl) {
      SetupPermissionTile(symbol: symbol, allowed: false)
      rowText(title: title, detail: detail)
      SetupPermissionButton(
        title: SetupPermissions.buttonTitle(
          row: row, microphone: microphone, waiting: waiting.contains(row)),
        accessibilityName: SetupPermissions.buttonAccessibilityName(
          row: row, microphone: microphone, waiting: waiting.contains(row)),
        waiting: waiting.contains(row)
      ) { press(row) }
    }
  }

  private func rowText(title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
    VStack(alignment: .leading, spacing: DesignSpacing.xxs) {
      Text(title).font(.firstRunLabel).foregroundStyle(Color.obTextPrimary)
      Text(detail).font(.firstRunCaption).foregroundStyle(Color.obTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func reason(_ text: LocalizedStringKey) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: DesignSpacing.md) {
      Image(systemName: "checkmark")
        .font(.firstRunCaption.weight(.heavy))
        .foregroundStyle(Color.firstRunSuccessText)
        .accessibilityHidden(true)
      Text(text)
        .font(.firstRunCaption)
        .foregroundStyle(Color.obTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// One press of a row's button. The first Accessibility press asks macOS; a press while waiting
  /// reopens System Settings, so missing the switch never strands the person.
  private func press(_ row: SetupPermissions.Permission) {
    let again = waiting.press(row, microphone: microphone)
    switch row {
    case .microphone: Task { await actions.microphone() }
    case .accessibility: actions.accessibility(again)
    }
  }

  // MARK: - Footer

  private var footer: some View {
    HStack(spacing: DesignSpacing.sm) {
      if isWaiting { SetupSpinner(reduceMotion: reduceMotion) }
      Text(
        SetupPermissions.note(
          microphone, accessibilityAllowed: accessibilityAllowed, waiting: isWaiting)
      )
      .font(.firstRunCaption)
      .foregroundStyle(Color.obTextSecondary)
    }
    .frame(height: SetupMetrics.linksHeight)
    .padding(.top, DesignSpacing.xl)
    .background {
      // The mockup shows no Continue control here: Return continues once both are on (the flow
      // refuses it before). Kept out of sight and out of the pointer's way; Back is the visible
      // link below.
      Group {
        Button("Continue", action: onContinue)
          .keyboardShortcut(.defaultAction)
          .disabled(!both)
      }
      .opacity(0)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
  }
}

// MARK: - Parts

/// The row icon well (mockup `tile`; `ok` tone once allowed).
private struct SetupPermissionTile: View {
  let symbol: String
  let allowed: Bool

  var body: some View {
    Image(systemName: symbol)
      .font(.firstRunLabel)
      .foregroundStyle(allowed ? Color.obSuccess : Color.obAccent)
      .frame(width: SetupMetrics.tileSize, height: SetupMetrics.tileSize)
      .background(
        RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
          .fill(allowed ? Color.obSuccessSoft : Color.firstRunAccentSoft)
      )
      .accessibilityHidden(true)
  }
}

/// An allowed permission (mockup `row` with an `ok` tile and a popped check).
private struct SetupPermissionAllowedRow: View {
  let symbol: String
  let title: LocalizedStringKey
  let detail: LocalizedStringKey
  let reduceMotion: Bool
  @State private var popped = false

  var body: some View {
    HStack(spacing: DesignSpacing.xl) {
      SetupPermissionTile(symbol: symbol, allowed: true)
      VStack(alignment: .leading, spacing: DesignSpacing.xxs) {
        Text(title).font(.firstRunLabel).foregroundStyle(Color.obTextPrimary)
        Text(detail).font(.firstRunCaption).foregroundStyle(Color.obTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Image(systemName: "checkmark.circle.fill")
        .font(.firstRunTitle)
        .symbolRenderingMode(.palette)
        .foregroundStyle(Color.white, Color.obSuccess)
        .scaleEffect(popped || reduceMotion ? 1 : 0.6)
        .opacity(popped || reduceMotion ? 1 : 0)
        .accessibilityHidden(true)
    }
    .padding(.vertical, DesignSpacing.xl)
    .padding(.horizontal, DesignSpacing.xxl)
    .background(
      RoundedRectangle(cornerRadius: DesignRadius.xl, style: .continuous).fill(Color.obSurface)
    )
    .accessibilityElement(children: .combine)
    .onAppear {
      // Shown either way, so turning Reduce Motion off later never hides the check.
      if reduceMotion {
        popped = true
      } else {
        withAnimation(DesignMotion.firstRunRise) { popped = true }
      }
    }
  }
}

/// The in-card button (mockup `btn-sm`, 36 high): accent fill, a spinner while waiting.
private struct SetupPermissionButton: View {
  let title: LocalizedStringKey
  let accessibilityName: LocalizedStringKey
  let waiting: Bool
  let action: () -> Void
  @State private var hovering = false
  @Environment(\.overlayReduceMotionOverride) private var reduceMotionOverride
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

  var body: some View {
    Button(action: action) {
      HStack(spacing: DesignSpacing.sm) {
        if waiting {
          SetupSpinner(reduceMotion: reduceMotionOverride ?? systemReduceMotion, onAccent: true)
        }
        Text(title).font(.firstRunLabel)
      }
      .foregroundStyle(Color.firstRunOnAccent)
      .padding(.horizontal, DesignSpacing.xxl)
      .frame(height: SetupMetrics.tileSize)
      .background(
        RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous)
          .fill(hovering ? Color.firstRunButtonHover : Color.obAccent)
      )
      .contentShape(RoundedRectangle(cornerRadius: DesignRadius.md, style: .continuous))
    }
    .buttonStyle(.plain)
    .fixedSize()
    .onHover { hovering = $0 }
    .animation(SettingsHover.animation, value: hovering)
    .accessibilityLabel(Text(accessibilityName))
  }
}

/// The mockup's small arc spinner; a still arc under Reduce Motion.
private struct SetupSpinner: View {
  let reduceMotion: Bool
  var onAccent = false

  var body: some View {
    TimelineView(.animation(paused: reduceMotion)) { timeline in
      let turn = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.8)
      Circle()
        .trim(from: 0, to: 0.75)
        .stroke(
          onAccent ? Color.firstRunOnAccent : Color.obAccent,
          style: StrokeStyle(lineWidth: DesignSpacing.xxs, lineCap: .round)
        )
        .frame(width: DesignSpacing.xl, height: DesignSpacing.xl)
        .rotationEffect(.degrees(reduceMotion ? 0 : turn / 0.8 * 360))
    }
    .accessibilityHidden(true)
  }
}

/// The System Settings preview (mockup `mock`): the pane's path, the app row and its switch,
/// which flips on and back every 3.2 s to show what to do; still (off) under Reduce Motion.
private struct SetupSettingsPreview: View {
  let pane: LocalizedStringKey
  let reduceMotion: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: DesignSpacing.md) {
      Text(pane)
        .textCase(.uppercase)
        .font(.firstRunEyebrow)
        .tracking(0.8)
        .foregroundStyle(Color.obTextPrimary)
      HStack(spacing: DesignSpacing.lg) {
        RainbowLipsView(animationState: .idle, size: DesignSpacing.xxxl)
          .accessibilityHidden(true)
        Text(verbatim: "EnviousWispr")
          .font(.firstRunLabel)
          .foregroundStyle(Color.obTextPrimary)
          .frame(maxWidth: .infinity, alignment: .leading)
        TimelineView(.animation(paused: reduceMotion)) { timeline in
          SetupDemoSwitch(on: reduceMotion ? 0 : Self.switchPosition(at: timeline.date))
        }
      }
    }
    .padding(.vertical, DesignSpacing.lg)
    .padding(.horizontal, DesignSpacing.xl)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: DesignRadius.xl, style: .continuous).fill(Color.obCardBg)
    )
    .overlay(
      RoundedRectangle(cornerRadius: DesignRadius.xl, style: .continuous)
        .strokeBorder(Color.firstRunRule)
        .allowsHitTesting(false)
    )
    .accessibilityHidden(true)
  }

  /// The mockup's `obKnob`/`obTrack` keyframes over 3.2 s: off to 25 %, sliding on to 45 %, on to
  /// 85 %, back off by 100 %. 0 is off, 1 is on.
  static func switchPosition(at date: Date) -> Double {
    let p = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3.2) / 3.2
    func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    switch p {
    case ..<0.25: return 0
    case ..<0.45: return easeOut((p - 0.25) / 0.2)
    case ..<0.85: return 1
    default: return 1 - easeOut((p - 0.85) / 0.15)
    }
  }
}

/// A macOS-style switch drawn at a position between off (0) and on (1).
private struct SetupDemoSwitch: View {
  let on: Double

  var body: some View {
    ZStack(alignment: .leading) {
      Capsule().fill(Color.firstRunButtonDisabled)
      Capsule().fill(Color.obSuccess).opacity(on)
      Circle()
        .fill(Color.white)
        .frame(width: DesignSpacing.xxl, height: DesignSpacing.xxl)
        .padding(DesignSpacing.xxs)
        .offset(x: on * DesignSpacing.xxl)
    }
    .frame(
      width: DesignSpacing.xxl * 2 + DesignSpacing.xs, height: DesignSpacing.xxl + DesignSpacing.xs)
  }
}
