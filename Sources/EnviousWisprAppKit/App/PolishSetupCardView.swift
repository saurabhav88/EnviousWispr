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
    /// The repeat within a day: names the engine, offers Choose engine, then quiet for 24 h.
    case escalated
  }

  let title: String
  let line: String
  /// The button that does something; nil draws no such button at all.
  let primaryLabel: String?
  /// The button that closes the card.
  let dismissLabel: String
  let variant: NoticeVariant?

  init(problem: PolishSetupProblem, egOneSize: EGOneSize? = nil) {
    if case .localEngineStoppedOutside(_, let stop) = problem {
      self.init(outsideStop: stop, variant: .first)
    } else if case .cloudNoModel(let provider) = problem {
      // #4353 D4: the title says what to do; the line is the dictation's own outcome.
      self.init(
        title: PolishSetupSurfaceCopy.chooseModelTitle(provider),
        line: Self.pastedWithoutPolish,
        primaryLabel: PolishSetupSurfaceCopy.selectNewCloudModel,
        dismissLabel: PolishSetupSurfaceCopy.cardNotNow, variant: nil)
    } else if case .cloudModelUnavailable(_, let model) = problem {
      self.init(
        title: PolishSetupSurfaceCopy.modelNoLongerWorksTitle(model),
        line: Self.pastedWithoutPolish,
        primaryLabel: PolishSetupSurfaceCopy.selectNewCloudModel,
        dismissLabel: PolishSetupSurfaceCopy.cardNotNow, variant: nil)
    } else {
      self.init(
        title: PolishSetupSurfaceCopy.cardTitle,
        line: PolishSetupSurfaceCopy.cardLine(
          reason: PolishSetupSurfaceCopy.shortReason(problem, egOneSize: egOneSize)),
        primaryLabel: PolishSetupLeaveDialogContent.Copy.finishSetup,
        dismissLabel: PolishSetupSurfaceCopy.cardNotNow, variant: nil)
    }
  }

  /// #3988: the notice after a take missed polish because something outside the app stopped
  /// the engine, in words from the stop the take froze. The first is OK only; the repeat within
  /// a day adds Choose engine.
  init(outsideStop stop: OutsideStopContext, variant: NoticeVariant) {
    switch variant {
    case .first:
      self.init(
        title: PolishSetupSurfaceCopy.outsideStopTitle,
        line: PolishSetupSurfaceCopy.outsideStopNotice(stop), primaryLabel: nil,
        dismissLabel: PolishSetupLeaveDialogContent.Copy.ok, variant: .first)
    case .escalated:
      self.init(
        title: PolishSetupSurfaceCopy.outsideStopTitle,
        line: PolishSetupSurfaceCopy.outsideStopEscalation(stop),
        primaryLabel: PolishSetupSurfaceCopy.chooseEngine,
        dismissLabel: PolishSetupLeaveDialogContent.Copy.ok, variant: .escalated)
    }
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

  /// The same sentence the dictation's own notice uses (`DictationNarrator`).
  private static var pastedWithoutPolish: String {
    String(
      localized: "Pasted without AI polish.",
      // Same key and comment as the pill, so the catalog keeps one entry and one translation.
      comment: "Pill: AI polish failed, so the unpolished text was pasted.")
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

  var body: some View {
    PolishSetupCardChrome(
      title: model.title, line: model.line,
      primary: model.primaryLabel.map { .init(id: 0, title: $0, perform: onFinishSetup) },
      secondary: [.init(id: 1, title: model.dismissLabel, perform: onNotNow)])
  }
}

/// The drawn card itself: a title, one line, one filled button and the quieter ones under it.
/// One owner for the look, shared by the card after a dictation and (#4473, founder 2026-11-11)
/// the question asked before leaving an unfinished polish setup, so both read as the same card.
struct PolishSetupCardChrome: View {
  struct Action: Identifiable {
    let id: Int
    let title: String
    /// The key that presses this button, if any (the leave question binds Return and Escape).
    var shortcut: KeyboardShortcut? = nil
    let perform: () -> Void
  }

  let title: String
  let line: String
  /// The filled button; nil draws none.
  let primary: Action?
  /// The quieter buttons, top to bottom.
  let secondary: [Action]

  private static let cardWidth: CGFloat = 320

  var body: some View {
    VStack(spacing: 14) {
      VStack(spacing: 6) {
        Text(title)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(.stTextPrimary)
          .multilineTextAlignment(.center)
        Text(line)
          .font(.system(size: 14))
          .foregroundStyle(.stTextSecondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }

      VStack(spacing: 10) {
        if let primary {
          Button(action: primary.perform) {
            Text(primary.title)
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(.white)
              .padding(.horizontal, 28)
              .padding(.vertical, 9)
              .contentShape(Rectangle())
              .background(Capsule().fill(Color.stAccentSolid))
          }
          .buttonStyle(.plain)
          .keyboardShortcut(primary.shortcut)
        }

        ForEach(secondary) { action in
          Button(action: action.perform) {
            Text(action.title)
              .font(.system(size: 14, weight: .medium))
              .foregroundStyle(.stAccent)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .keyboardShortcut(action.shortcut)
        }
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
