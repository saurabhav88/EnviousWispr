import SwiftUI

/// What the AI polish setup card shows (#3438, plan §17 C3): its line, already composed from
/// the problem the card was raised for. A value, so the overlay compares and renders it like
/// any other content.
struct PolishSetupCardModel: Hashable, Sendable {
  let line: String

  init(problem: PolishSetupProblem) {
    line = PolishSetupSurfaceCopy.cardLine(reason: PolishSetupSurfaceCopy.shortReason(problem))
  }
}

/// The card after a dictation whose AI polish did not run because its chosen model is not set
/// up. Non-modal and theme-aware, drawn like the Bluetooth card: a title, one line, and two
/// buttons. No close button and no timer: "Not now" is the way to leave it.
struct PolishSetupCardView: View {
  let model: PolishSetupCardModel
  let onFinishSetup: () -> Void
  let onNotNow: () -> Void

  private static let cardWidth: CGFloat = 320

  var body: some View {
    VStack(spacing: 14) {
      VStack(spacing: 6) {
        Text(PolishSetupSurfaceCopy.cardTitle)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(.stTextPrimary)
          .multilineTextAlignment(.center)
        Text(model.line)
          .font(.system(size: 14))
          .foregroundStyle(.stTextSecondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }

      VStack(spacing: 10) {
        Button(action: onFinishSetup) {
          Text(PolishSetupLeaveDialogContent.Copy.finishSetup)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background(Capsule().fill(Color.stAccentSolid))
        }
        .buttonStyle(.plain)

        Button(action: onNotNow) {
          Text(PolishSetupSurfaceCopy.cardNotNow)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.stAccent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 18)
    .frame(width: Self.cardWidth)
    .background(Color.stSectionBg)
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(Color.stAccent.opacity(0.18), lineWidth: 1)
        .allowsHitTesting(false)
    )
    .shadow(color: .black.opacity(0.28), radius: 22, y: 12)
  }
}
