import EnviousWisprCore
import SwiftUI

/// What the card after a dictation shows (#3438, plan §17 C3; #3988): its title, its line and
/// its button labels, all composed when the card is raised and frozen with it, so a setup that
/// changes while the card is up never rewrites what it says. A value, so the overlay compares
/// and renders it like any other content.
struct PolishSetupCardModel: Hashable, Sendable {
  /// Which outside-stop notice this is (#3988); nil for a setup card.
  enum NoticeVariant: String, Hashable, Sendable {
    case first
  }

  let title: String
  let line: String
  /// The button that does something; nil draws no such button at all.
  let primaryLabel: String?
  /// The button that closes the card.
  let dismissLabel: String
  let variant: NoticeVariant?

  init(problem: PolishSetupProblem) {
    if case .localEngineStoppedOutside(_, let stop) = problem {
      self.init(outsideStop: stop)
    } else {
      self.init(
        title: PolishSetupSurfaceCopy.cardTitle,
        line: PolishSetupSurfaceCopy.cardLine(reason: PolishSetupSurfaceCopy.shortReason(problem)),
        primaryLabel: PolishSetupLeaveDialogContent.Copy.finishSetup,
        dismissLabel: PolishSetupSurfaceCopy.cardNotNow, variant: nil)
    }
  }

  /// #3988: the first notice after a take missed polish because something outside the app
  /// stopped the engine. Words from the stop the take froze; OK only.
  init(outsideStop stop: OutsideStopContext) {
    self.init(
      title: PolishSetupSurfaceCopy.outsideStopTitle,
      line: PolishSetupSurfaceCopy.outsideStopNotice(stop), primaryLabel: nil,
      dismissLabel: PolishSetupLeaveDialogContent.Copy.ok, variant: .first)
  }

  private init(
    title: String, line: String, primaryLabel: String?, dismissLabel: String,
    variant: NoticeVariant?
  ) {
    self.title = title
    self.line = line
    self.primaryLabel = primaryLabel
    self.dismissLabel = dismissLabel
    self.variant = variant
  }

  /// What VoiceOver reads when the card appears: the same title and line it shows.
  var announcement: String { "\(title). \(line)" }
}

/// The card after a dictation whose AI polish did not run: its setup is unfinished, or (#3988)
/// something outside the app stopped the local engine. Non-modal and theme-aware, drawn like
/// the Bluetooth card: a title, one line, and its buttons. No close button and no timer: the
/// dismiss button is the way to leave it.
struct PolishSetupCardView: View {
  let model: PolishSetupCardModel
  let onFinishSetup: () -> Void
  let onNotNow: () -> Void

  private static let cardWidth: CGFloat = 320

  var body: some View {
    VStack(spacing: 14) {
      VStack(spacing: 6) {
        Text(model.title)
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
        if let primaryLabel = model.primaryLabel {
          Button(action: onFinishSetup) {
            Text(primaryLabel)
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(.white)
              .padding(.horizontal, 28)
              .padding(.vertical, 9)
              .contentShape(Rectangle())
              .background(Capsule().fill(Color.stAccentSolid))
          }
          .buttonStyle(.plain)
        }

        Button(action: onNotNow) {
          Text(model.dismissLabel)
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
