import SwiftUI

/// #1480: canonical copy for the Bluetooth cold-start education. The three tip
/// strings are IDENTICAL across the overlay popover and the Microphone-settings
/// guide (plan §3c — same wording, reviewed together), so both surfaces read
/// them from here and can never drift. Council-corrected wording (plan §3B/§14):
/// "after your mic has been idle" not "first dictation"; "keeps follow-up
/// dictations ready" not "instant"; "usually avoid this startup delay" not
/// "more reliable". No em/en dashes (brand rule).
enum BluetoothTipsCopy {
  // Overlay popover
  static let cardTitle = "Bluetooth mic detected"
  static let cardIntro = "Bluetooth microphones can take a moment on a cold start."
  static let cardFootnote = "Shown once per launch when Bluetooth is your mic"
  static let gotItButton = "Got it"
  static let adjustSettingsButton = "Adjust settings"
  static let closeAccessibilityLabel = "Dismiss Bluetooth tips"

  // Shared tips (identical on both surfaces)
  static let tipTiming = "After your mic has been idle, wait 1 to 2 seconds before speaking."
  static let tipReadiness =
    "Microphone Readiness keeps follow-up dictations ready for up to 30 seconds (on by default)."
  static let tipHeadphones = "Built-in or wired mics usually avoid this startup delay."

  // SF Symbols for the three tips (same icons on both surfaces).
  static let iconTiming = "clock"
  static let iconReadiness = "timer"
  static let iconHeadphones = "headphones"

  // Microphone-settings guide
  static let settingsHeader = "When using Bluetooth"
  static let settingsIntro =
    "Bluetooth microphones switch into call mode when a recording starts, which takes a moment on a cold start."
  static let micOrder = "Preferred mic order: Built-in or wired > USB > Bluetooth"
  static let settingsPS =
    "Built-in, wired, and USB mics do not have this Bluetooth startup delay."
  static let showTipsToggle = "Show Bluetooth tips"
}

// MARK: - BluetoothAwarenessCardView

/// #1480: the once-per-launch Bluetooth cold-start education popover, rendered in
/// the top-middle overlay slot by `RecordingOverlayPanel`. Theme-aware — every
/// colour is a dynamic `st*` token (`SettingsDesignTokens.swift`), so it resolves
/// per `NSApp.appearance` and swaps with the appearance ticker exactly like the
/// rest of the app.
///
/// The view owns NO dismissal state and NO timer: its three buttons forward the
/// user's tap to `BluetoothAwarenessPresenter` via the injected closures, and the
/// presenter alone decides teardown + telemetry. Any fade is view-local and
/// becomes harmless the moment the hosting panel closes (plan §3D supersession
/// contract — no completion-owned teardown).
struct BluetoothAwarenessCardView: View {
  let onGotIt: () -> Void
  let onClose: () -> Void
  let onAdjustSettings: () -> Void

  private static let cardWidth: CGFloat = 320

  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 14) {
        // Title + intro (centered).
        VStack(spacing: 6) {
          Text(BluetoothTipsCopy.cardTitle)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.stTextPrimary)
            .multilineTextAlignment(.center)
          Text(BluetoothTipsCopy.cardIntro)
            .font(.system(size: 13))
            .foregroundStyle(.stTextSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }

        // Tips (left-aligned rows — icon and sentence on the same line).
        VStack(alignment: .leading, spacing: 12) {
          tipRow(icon: BluetoothTipsCopy.iconTiming, text: BluetoothTipsCopy.tipTiming)
          tipRow(icon: BluetoothTipsCopy.iconReadiness, text: BluetoothTipsCopy.tipReadiness)
          tipRow(icon: BluetoothTipsCopy.iconHeadphones, text: BluetoothTipsCopy.tipHeadphones)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        // Footnote (centered).
        Text(BluetoothTipsCopy.cardFootnote)
          .font(.system(size: 12))
          .foregroundStyle(.stTextTertiary)
          .multilineTextAlignment(.center)

        // Actions (centered): primary "Got it" + quiet "Adjust settings".
        VStack(spacing: 10) {
          Button(action: onGotIt) {
            Text(BluetoothTipsCopy.gotItButton)
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(.white)
              .padding(.horizontal, 28)
              .padding(.vertical, 9)
              .contentShape(Rectangle())
              .background(Capsule().fill(Color.stAccentSolid))
          }
          .buttonStyle(.plain)

          Button(action: onAdjustSettings) {
            Text(BluetoothTipsCopy.adjustSettingsButton)
              .font(.system(size: 13, weight: .medium))
              .foregroundStyle(.stAccent)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 20)
      .padding(.top, 20)
      .padding(.bottom, 15)

      // Brand rainbow bottom line.
      rainbowLine
    }
    .frame(width: Self.cardWidth)
    .background(Color.stSectionBg)
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(Color.stAccent.opacity(0.18), lineWidth: 1)
    )
    .overlay(alignment: .topTrailing) {
      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.stTextTertiary)
          .frame(width: 25, height: 25)
          .contentShape(Rectangle())
          .background(Color.stAccentLight, in: RoundedRectangle(cornerRadius: 8))
      }
      .buttonStyle(.plain)
      .accessibilityLabel(BluetoothTipsCopy.closeAccessibilityLabel)
      .padding(11)
    }
    .shadow(color: .black.opacity(0.28), radius: 22, y: 12)
  }

  private func tipRow(icon: String, text: String) -> some View {
    HStack(alignment: .center, spacing: 11) {
      Image(systemName: icon)
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.stAccent)
        .frame(width: 34, height: 34)
        .background(Color.stAccentLight, in: Circle())
        .overlay(Circle().strokeBorder(Color.stAccent.opacity(0.22), lineWidth: 1))
        .accessibilityHidden(true)
      Text(text)
        .font(.system(size: 13))
        .foregroundStyle(.stTextBody)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
  }

  private var rainbowLine: some View {
    LinearGradient(
      colors: [
        Color(red: 1.0, green: 0.165, blue: 0.251),  // red
        Color(red: 1.0, green: 0.549, blue: 0.0),  // orange
        Color(red: 1.0, green: 0.843, blue: 0.0),  // yellow
        Color(red: 0.678, green: 1.0, blue: 0.184),  // yellow-green
        Color(red: 0.0, green: 0.98, blue: 0.604),  // mint
        Color(red: 0.0, green: 1.0, blue: 1.0),  // cyan
        Color(red: 0.118, green: 0.565, blue: 1.0),  // dodger blue
        Color(red: 0.255, green: 0.412, blue: 0.882),  // royal blue
        Color(red: 0.541, green: 0.169, blue: 0.886),  // purple
      ],
      startPoint: .leading,
      endPoint: .trailing
    )
    .frame(height: 2)
    .opacity(0.92)
    .accessibilityHidden(true)
  }
}
