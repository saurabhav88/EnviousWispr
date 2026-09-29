import AppKit
import EnviousWisprServices
import SwiftUI

/// The in-app help check's screens in the Send Feedback popover (#3275): the short "checking"
/// state after Send, and the help cards with the choices the check allows. The rules for what may
/// be offered live in `HelpCheckSuggestions`; this view only renders them.

/// Shown while the check runs (at most 7 seconds). The brand lips move on a gentle made-up wave,
/// never the microphone; with Reduce Motion they hold still.
struct FeedbackHelpCheckingView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 14) {
      Group {
        if reduceMotion {
          RainbowLipsIcon(size: 44, audioLevel: 0.45)
        } else {
          TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            RainbowLipsIcon(size: 44, audioLevel: Float(0.35 + 0.3 * (sin(t * 3.2) + 1) / 2))
          }
        }
      }
      .accessibilityHidden(true)
      Text(Self.title)
        .font(.stRowTitle)
        .foregroundStyle(.stTextPrimary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 44)
    .accessibilityElement(children: .combine)
    .onAppear { AccessibilityNotification.Announcement(Self.title).post() }
  }

  static var title: String {
    String(localized: "feedback.help.checking", defaultValue: "Checking for helpful answers…")
  }
}

/// The help cards. `onSend` saves the report with the concerns marked solved; `onAllSolved` ends
/// it without sending (offered only when the check allows it and every concern is marked
/// solved); `onClose` closes the cards and keeps the draft.
struct FeedbackHelpResultsView: View {
  let suggestions: HelpCheckSuggestions
  let isSaving: Bool
  let onSend: (Set<String>) -> Void
  let onAllSolved: (Set<String>) -> Void
  let onClose: () -> Void

  /// Concerns the user marked solved. Every choice starts at "Still happening".
  @State private var solved: Set<String> = []

  /// One concern, verified and suppressible: the single yes-or-send question.
  private var isSingleQuestion: Bool {
    suggestions.suppressionAllowed && suggestions.issueIDs.count == 1
  }

  private var everythingSolved: Bool {
    suggestions.suppressionAllowed && solved == suggestions.issueIDs
  }

  /// Concerns the cards do not answer: unmatched, or beyond the three cards.
  private var unanswered: [String] {
    let onCards = Set(suggestions.cards.flatMap(\.issueIDs))
    return suggestions.reply.results.map(\.id).filter { !onCards.contains($0) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(suggestions.cards, id: \.result.id) { card in
            FeedbackHelpCard(
              card: card, suggestions: suggestions, solved: $solved,
              showsChoices: !isSingleQuestion)
          }
          ForEach(unanswered, id: \.self) { id in
            Label {
              Text(unansweredText(for: id))
                .font(.stHelper)
                .foregroundStyle(.stTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
              Image(systemName: "paperplane")
                .foregroundStyle(.stTextTertiary)
            }
          }
        }
      }
      .frame(maxHeight: 360)
      footer
    }
    .padding(18)
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 10) {
      Text(headerText)
        .font(.stRowTitle)
        .foregroundStyle(.stTextPrimary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.stTextSecondary)
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(Self.closeText)
      .accessibilityLabel(Self.closeText)
      .keyboardShortcut(.cancelAction)
    }
  }

  private var headerText: String {
    if isSingleQuestion {
      return String(
        localized: "feedback.help.single.question",
        defaultValue: "Does this solve everything you wanted to report?")
    }
    return String(
      localized: "feedback.help.several.title",
      defaultValue: "We found help for parts of your message.")
  }

  private var footer: some View {
    HStack(spacing: 10) {
      Spacer(minLength: 0)
      if isSingleQuestion {
        secondaryButton(Self.stillSendText) { onSend([]) }
        primaryButton(Self.allSolvedText) { onAllSolved(suggestions.issueIDs) }
      } else if everythingSolved {
        secondaryButton(Self.stillSendText) { onSend(solved) }
        primaryButton(Self.allSolvedText) { onAllSolved(solved) }
      } else {
        primaryButton(Self.sendText) { onSend(solved) }
      }
    }
    .disabled(isSaving)
  }

  private func unansweredText(for id: String) -> String {
    guard let concern = suggestions.summary(for: id) else {
      return String(
        localized: "feedback.help.unmatched.generic",
        defaultValue:
          "We couldn't find a reliable answer for part of your message. We'll send your message.")
    }
    return String(
      localized: "feedback.help.unmatched",
      defaultValue: "We couldn't find a reliable answer for \(concern). We'll send your message.")
  }

  private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.stAccentSolid)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    .buttonStyle(.plain)
    .keyboardShortcut(.return, modifiers: .command)
  }

  private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.stTextPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.stSectionBg))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    .buttonStyle(.plain)
  }

  static var sendText: String {
    String(localized: "feedback.help.send", defaultValue: "Send my feedback")
  }
  static var stillSendText: String {
    String(localized: "feedback.help.stillSend", defaultValue: "Still send my feedback")
  }
  static var allSolvedText: String {
    String(localized: "feedback.help.allSolved", defaultValue: "Yes, that solved everything")
  }
  static var closeText: String {
    String(localized: "feedback.help.close", defaultValue: "Close and keep editing")
  }
}

/// One help card: the section or page, a link to read it, and per concern it answers either the
/// Solved / Still happening choice (only where the check allows Solved) or a note that the
/// message will still be sent.
struct FeedbackHelpCard: View {
  let card: HelpCheckSuggestions.Card
  let suggestions: HelpCheckSuggestions
  @Binding var solved: Set<String>
  let showsChoices: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let heading = card.result.heading {
        Text(heading)
          .font(.stRowTitle)
          .foregroundStyle(.stTextPrimary)
      }
      if let text = card.result.text {
        Text(text)
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
          .lineLimit(5)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let url = card.result.url {
        Button {
          NSWorkspace.shared.open(url)
        } label: {
          Label(Self.readText, systemImage: "arrow.up.right.square")
            .font(.stHelper)
            .foregroundStyle(.stAccent)
        }
        .buttonStyle(.plain)
      }
      ForEach(card.issueIDs, id: \.self) { id in
        concernRow(id)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.stSectionBg))
  }

  @ViewBuilder
  private func concernRow(_ id: String) -> some View {
    if suggestions.canMarkSolved(id) {
      if showsChoices {
        VStack(alignment: .leading, spacing: 6) {
          Text(questionText(for: id))
            .font(.stHelper)
            .foregroundStyle(.stTextPrimary)
            .fixedSize(horizontal: false, vertical: true)
          Picker(questionText(for: id), selection: choice(for: id)) {
            Text(Self.stillHappeningText).tag(false)
            Text(Self.solvedText).tag(true)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
        }
      }
    } else {
      Text(card.result.matchType == .page ? Self.pageText : Self.stillSentText)
        .font(.stHelper)
        .foregroundStyle(.stTextTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func choice(for id: String) -> Binding<Bool> {
    Binding(
      get: { solved.contains(id) },
      set: { isSolved in
        if isSolved { solved.insert(id) } else { solved.remove(id) }
      })
  }

  private func questionText(for id: String) -> String {
    guard let concern = suggestions.summary(for: id) else {
      return String(localized: "feedback.help.question.generic", defaultValue: "Did this fix it?")
    }
    return String(localized: "feedback.help.question", defaultValue: "Did this fix \(concern)?")
  }

  static var readText: String {
    String(localized: "feedback.help.read", defaultValue: "Read in the help center")
  }
  static var solvedText: String {
    String(localized: "feedback.help.solved", defaultValue: "Solved")
  }
  static var stillHappeningText: String {
    String(localized: "feedback.help.stillHappening", defaultValue: "Still happening")
  }
  static var pageText: String {
    String(
      localized: "feedback.help.page",
      defaultValue: "This page might help. We'll still send your message.")
  }
  static var stillSentText: String {
    String(
      localized: "feedback.help.stillSent",
      defaultValue: "This might help. We'll still send your message.")
  }
}
