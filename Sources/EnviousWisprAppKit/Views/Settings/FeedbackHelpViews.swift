import AppKit
import EnviousWisprServices
import SwiftUI

/// The in-app help check's screens in the Send Feedback popover (#3275): the short "checking"
/// state after Send, and the help cards with the choices the check allows. The rules for what may
/// be offered live in `HelpCheckSuggestions`; this view only renders them. Motion follows the
/// founder-approved prototype (2026-09-29); with Reduce Motion every screen holds still.

/// Shown while the check runs (at most 7 seconds): the brand lips move on a gentle made-up wave
/// (never the microphone), a thin bar sweeps, the message folds into one quoted line and a
/// placeholder card shimmers where the answer will appear.
struct FeedbackHelpCheckingView: View {
  /// The words being checked, quoted back so the user sees their message is kept.
  let message: String

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var folded = false
  @State private var step = 0

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 12) {
        lips
        VStack(alignment: .leading, spacing: 3) {
          Text(step == 0 ? Self.readingTitle : Self.title)
            .font(.stRowTitle)
            .foregroundStyle(.stTextPrimary)
            .id(step)
            .transition(.opacity)
          Text(Self.detail)
            .font(.stHelper)
            .foregroundStyle(.stTextSecondary)
        }
      }
      FeedbackSweepBar()
      Text(verbatim: "“\(message)”")
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
        .lineLimit(folded ? 1 : 5)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, folded ? 10 : 14)
        .background(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.stInputBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .accessibilityHidden(true)
      FeedbackSkeletonCard()
    }
    .padding(20)
    .accessibilityElement(children: .combine)
    .onAppear {
      AccessibilityNotification.Announcement(Self.title).post()
      withAnimation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.85).delay(0.15))
      {
        folded = true
      }
    }
    .task {
      guard (try? await Task.sleep(for: .seconds(1.1))) != nil else { return }
      withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { step = 1 }
    }
  }

  private var lips: some View {
    Group {
      if reduceMotion {
        RainbowLipsIcon(size: 38, audioLevel: 0.45)
      } else {
        TimelineView(.animation) { context in
          let t = context.date.timeIntervalSinceReferenceDate
          RainbowLipsIcon(size: 38, audioLevel: Float(0.35 + 0.3 * (sin(t * 3.2) + 1) / 2))
        }
      }
    }
    .accessibilityHidden(true)
  }

  static var readingTitle: String {
    String(localized: "feedback.help.checking.reading", defaultValue: "Reading your message…")
  }
  static var title: String {
    String(localized: "feedback.help.checking", defaultValue: "Checking help articles…")
  }
  static var detail: String {
    String(
      localized: "feedback.help.checking.detail",
      defaultValue: "This can take a few seconds. Your message won't be lost."
    )
  }
}

/// A thin accent line sweeping across a track while the check runs; a still partial line with
/// Reduce Motion.
private struct FeedbackSweepBar: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(Color.stTextTertiary.opacity(0.18))
        if reduceMotion {
          Capsule().fill(Color.stAccent).frame(width: proxy.size.width * 0.4)
        } else {
          TimelineView(.animation) { context in
            let phase =
              context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.3) / 1.3
            let width = proxy.size.width * 0.4
            Capsule().fill(Color.stAccent)
              .frame(width: width)
              .offset(x: -width + (proxy.size.width + width) * phase)
          }
        }
      }
      .clipShape(Capsule())
    }
    .frame(height: 3)
    .accessibilityHidden(true)
  }
}

/// A placeholder card whose lines shimmer where the answer will appear.
private struct FeedbackSkeletonCard: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.animation(paused: reduceMotion)) { context in
      let phase =
        context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
      let glow = reduceMotion ? 0.0 : (sin(phase * 2 * .pi) + 1) / 2
      VStack(alignment: .leading, spacing: 10) {
        line(0.42, height: 10, glow: glow)
        line(0.7, height: 14, glow: glow)
        line(0.92, height: 10, glow: glow)
        line(0.8, height: 10, glow: glow)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.stSectionBg))
    }
    .accessibilityHidden(true)
  }

  private func line(_ fraction: CGFloat, height: CGFloat, glow: Double) -> some View {
    GeometryReader { proxy in
      RoundedRectangle(cornerRadius: height / 2, style: .continuous)
        .fill(Color.stTextTertiary.opacity(0.14 + 0.12 * glow))
        .frame(width: proxy.size.width * fraction)
    }
    .frame(height: height)
  }
}

/// The help cards. `onMark` records a concern marked solved (the marks live in the shared
/// `FeedbackSubmission`, so they survive the popover closing); `onSend` saves the report with the
/// marked concerns; `onAllSolved` ends it without sending (offered only when the check allows it
/// and every concern is marked solved); `onMinimize` closes the popover and keeps the cards for
/// the bug icon; `onEdit` goes back to the message.
struct FeedbackHelpResultsView: View {
  let suggestions: HelpCheckSuggestions
  let marks: Set<String>
  let isSaving: Bool
  let onMark: (String, Bool) -> Void
  let onSend: (Set<String>) -> Void
  let onAllSolved: (Set<String>) -> Void
  let onMinimize: () -> Void
  let onEdit: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Drives the entrance: the header, each card and the footer rise in turn.
  @State private var shown = false
  /// The cards' natural height, measured, so the list grows to fit and scrolls only past the cap.
  /// A bare ScrollView in a popover collapses to a sliver (live UAT), so its height is set here.
  @State private var cardsHeight: CGFloat = 0
  /// Tallest the card list grows before it scrolls, so the buttons stay on screen.
  private static let maxCardsHeight: CGFloat = 440

  /// One concern, verified and suppressible: the single yes-or-send choice, no marks.
  private var isSingleQuestion: Bool {
    suggestions.suppressionAllowed && suggestions.issueIDs.count == 1
  }

  private var everythingSolved: Bool {
    suggestions.suppressionAllowed && marks == suggestions.issueIDs
  }

  /// Concerns the cards do not answer: unmatched, or beyond the three cards.
  private var unanswered: [String] {
    let onCards = Set(suggestions.cards.flatMap(\.issueIDs))
    return suggestions.reply.results.map(\.id).filter { !onCards.contains($0) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header.rise(shown, index: 0, reduceMotion: reduceMotion)
      if suggestions.suppressionAllowed, !isSingleQuestion {
        Text(Self.markEachText)
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
          .rise(shown, index: 1, reduceMotion: reduceMotion)
      }
      ScrollView {
        cardList
          .background(
            GeometryReader { proxy in
              Color.clear.preference(key: FeedbackCardsHeightKey.self, value: proxy.size.height)
            })
      }
      .scrollIndicators(cardsHeight > Self.maxCardsHeight ? .automatic : .never)
      .frame(height: min(max(cardsHeight, 1), Self.maxCardsHeight))
      .onPreferenceChange(FeedbackCardsHeightKey.self) { cardsHeight = $0 }
      VStack(spacing: 10) {
        footer
        caption
      }
      .rise(shown, index: suggestions.cards.count + 1, reduceMotion: reduceMotion)
    }
    .padding(20)
    .onAppear { shown = true }
  }

  private var cardList: some View {
      VStack(alignment: .leading, spacing: 10) {
        ForEach(Array(suggestions.cards.enumerated()), id: \.element.result.id) { index, card in
          FeedbackHelpCard(
            card: card, suggestions: suggestions, marks: marks, showsMarks: !isSingleQuestion,
            onMark: onMark
          )
          .rise(shown, index: index + 1, reduceMotion: reduceMotion)
        }
        ForEach(unanswered, id: \.self) { id in
          Label {
            Text(unansweredText(for: id))
              .font(.stHelper)
              .foregroundStyle(.stTextSecondary)
              .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "paperplane")
              .foregroundStyle(.stTextSecondary)
          }
        }
      }
      .fixedSize(horizontal: false, vertical: true)
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: "book.fill")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 36, height: 36)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.stAccentSolid)
        )
        .accessibilityHidden(true)
      Text(headerText)
        .font(.stRowTitle)
        .foregroundStyle(.stTextPrimary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      Button(action: onMinimize) {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(.stTextSecondary)
          .frame(width: 26, height: 26)
          .background(Circle().fill(Color.stSectionBg))
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .help(Self.minimizeText)
      .accessibilityLabel(Self.minimizeText)
      .keyboardShortcut(.cancelAction)
    }
  }

  private var headerText: String {
    if suggestions.cards.count == 1 {
      return String(
        localized: "feedback.help.found.one", defaultValue: "We found an article that might help")
    }
    return String(
      localized: "feedback.help.found.several", defaultValue: "We found articles that might help")
  }

  private var footer: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) { footerButtons }
      VStack(spacing: 8) { footerButtons }
    }
    .disabled(isSaving)
    .animation(
      reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: everythingSolved)
  }

  @ViewBuilder
  private var footerButtons: some View {
    if isSingleQuestion {
      secondaryButton(Self.solvedDontSendText) { onAllSolved(suggestions.issueIDs) }
      primaryButton { onSend([]) }
    } else {
      if everythingSolved {
        secondaryButton(Self.allSolvedDontSendText) { onAllSolved(marks) }
          .transition(.move(edge: .leading).combined(with: .opacity))
      }
      primaryButton { onSend(marks) }
    }
  }

  private var caption: some View {
    HStack(spacing: 8) {
      Text(Self.exactWordsText)
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
      Button(action: onEdit) {
        Text(Self.editText)
          .font(.stHelper.weight(.semibold))
          .foregroundStyle(Color(nsColor: .linkColor))
          .underline()
      }
      .buttonStyle(.plain)
      .disabled(isSaving)
    }
    .frame(maxWidth: .infinity)
  }

  private func unansweredText(for id: String) -> String {
    guard let concern = suggestions.summary(for: id) else {
      return String(
        localized: "feedback.help.unmatched.generic",
        defaultValue:
          "We couldn't find a reliable answer for part of your message. You can still send your message.")
    }
    return String(
      localized: "feedback.help.unmatched",
      defaultValue: "We couldn't find a reliable answer for \(concern). You can still send your message.")
  }

  private func primaryButton(action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label(Self.sendMessageText, systemImage: "paperplane.fill")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.white)
        .lineLimit(1)
        .fixedSize()
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
          RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.stAccentSolid)
        )
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
    .buttonStyle(FeedbackPressStyle())
    .keyboardShortcut(.return, modifiers: .command)
  }

  private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label {
        Text(title)
      } icon: {
        Image(systemName: "checkmark").foregroundStyle(Color.stSuccess)
      }
      .font(.system(size: 14, weight: .medium))
      .foregroundStyle(.stTextPrimary)
      .lineLimit(1)
      .fixedSize()
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.stSectionBg))
      .overlay(
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .strokeBorder(Color.stInputBorder, lineWidth: 1)
          .allowsHitTesting(false)
      )
      .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
    .buttonStyle(FeedbackPressStyle())
  }

  static var markEachText: String {
    String(localized: "feedback.help.markEach", defaultValue: "Mark each part you've solved.")
  }
  static var sendMessageText: String {
    String(localized: "feedback.help.sendMessage", defaultValue: "Send my message")
  }
  static var solvedDontSendText: String {
    String(localized: "feedback.help.solvedDontSend", defaultValue: "Solved, don't send")
  }
  static var allSolvedDontSendText: String {
    String(localized: "feedback.help.allSolvedDontSend", defaultValue: "All solved, don't send")
  }
  static var exactWordsText: String {
    String(
      localized: "feedback.help.exactWords",
      defaultValue: "Send delivers your words exactly as you wrote them.")
  }
  static var editText: String {
    String(localized: "feedback.help.edit", defaultValue: "Edit message")
  }
  static var minimizeText: String {
    String(
      localized: "feedback.help.minimize",
      defaultValue: "Close for now. Click the bug icon to come back.")
  }
}

/// One help card: the help page's title, the section text, a link to read it, and per concern it
/// answers either a Mark solved chip (only where the check allows Solved) or a note that the
/// message will still be sent.
struct FeedbackHelpCard: View {
  let card: HelpCheckSuggestions.Card
  let suggestions: HelpCheckSuggestions
  let marks: Set<String>
  let showsMarks: Bool
  let onMark: (String, Bool) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var markable: [String] {
    showsMarks ? card.issueIDs.filter(suggestions.canMarkSolved) : []
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      // More than one concern on one card: each gets its own quoted line and chip.
      if showsMarks, card.issueIDs.count > 1 {
        ForEach(card.issueIDs, id: \.self) { id in
          HStack(spacing: 8) {
            quote(id)
            Spacer(minLength: 0)
            if suggestions.canMarkSolved(id) { chip(id) }
          }
        }
      } else if showsMarks, let id = card.issueIDs.first {
        quote(id)
      }
      if let title = card.result.pageTitle ?? card.result.heading {
        Text(title)
          .font(.stRowTitle)
          .foregroundStyle(.stTextPrimary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let text = card.result.text {
        Text(text)
          .font(.stHelper)
          .foregroundStyle(.stTextBody)
          .lineLimit(5)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 10) {
        if let url = card.result.url {
          Link(destination: url) {
            HStack(spacing: 5) {
              Text(Self.readText).underline()
              Image(systemName: "arrow.up.right")
            }
            .font(.stHelper.weight(.semibold))
            .foregroundStyle(Color(nsColor: .linkColor))
          }
        }
        Spacer(minLength: 0)
        if card.issueIDs.count == 1, let id = markable.first { chip(id) }
      }
      if card.issueIDs.contains(where: { !suggestions.canMarkSolved($0) }) {
        Text(card.result.matchType == .page ? Self.pageText : Self.stillSentText)
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.stSectionBg))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(
          allMarked ? Color.stSuccess.opacity(0.6) : Color.stInputBorder.opacity(0.6), lineWidth: 1
        )
        .allowsHitTesting(false)
    )
    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: allMarked)
  }

  private var allMarked: Bool {
    !markable.isEmpty && markable.allSatisfy(marks.contains)
  }

  private func quote(_ id: String) -> some View {
    Text(verbatim: "“\(suggestions.summary(for: id) ?? "")”")
      .font(.stHelper)
      .foregroundStyle(.stTextSecondary)
      .lineLimit(2)
      .opacity(suggestions.summary(for: id) == nil ? 0 : 1)
  }

  private func chip(_ id: String) -> some View {
    FeedbackSolvedChip(isOn: marks.contains(id)) { onMark(id, $0) }
      .accessibilityLabel(questionText(for: id))
  }

  private func questionText(for id: String) -> String {
    guard let concern = suggestions.summary(for: id) else {
      return String(localized: "feedback.help.question.generic", defaultValue: "Did this fix it?")
    }
    return String(localized: "feedback.help.question", defaultValue: "Did this fix \(concern)?")
  }

  static var readText: String {
    String(localized: "feedback.help.read", defaultValue: "Read the full article")
  }
  static var pageText: String {
    String(
      localized: "feedback.help.page",
      defaultValue: "This page might help. You can still send your message.")
  }
  static var stillSentText: String {
    String(
      localized: "feedback.help.stillSent",
      defaultValue: "This might help. You can still send your message.")
  }
}

/// The Mark solved chip: a round check that fills green with a small pop when pressed.
private struct FeedbackSolvedChip: View {
  let isOn: Bool
  let onChange: (Bool) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button {
      withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.6)) {
        onChange(!isOn)
      }
    } label: {
      HStack(spacing: 6) {
        ZStack {
          Circle()
            .strokeBorder(isOn ? Color.stSuccess : Color.stTextSecondary, lineWidth: 1.5)
            .background(Circle().fill(isOn ? Color.stSuccess : .clear))
          if isOn {
            Image(systemName: "checkmark")
              .font(.system(size: 9, weight: .heavy))
              .foregroundStyle(.white)
              .transition(.scale.combined(with: .opacity))
          }
        }
        .frame(width: 18, height: 18)
        .scaleEffect(isOn && !reduceMotion ? 1.0 : 0.96)
        Text(isOn ? Self.solvedText : Self.markText)
          .font(.stHelper.weight(.semibold))
          .foregroundStyle(isOn ? Color.stSuccess : Color.stTextPrimary)
      }
      .padding(.leading, 7)
      .padding(.trailing, 11)
      .padding(.vertical, 5)
      .background(Capsule().fill(isOn ? Color.stSuccess.opacity(0.14) : Color.stPageBg))
      .overlay(
        Capsule()
          .strokeBorder(isOn ? Color.stSuccess.opacity(0.6) : Color.stInputBorder, lineWidth: 1)
          .allowsHitTesting(false)
      )
      .contentShape(Capsule())
    }
    .buttonStyle(FeedbackPressStyle())
    .accessibilityValue(isOn ? Self.solvedText : "")
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }

  static var markText: String {
    String(localized: "feedback.help.markSolved", defaultValue: "Mark solved")
  }
  static var solvedText: String {
    String(localized: "feedback.help.solved", defaultValue: "Solved")
  }
}

/// A light press: buttons shrink a touch while held.
struct FeedbackPressStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

extension View {
  /// The staggered entrance: each piece rises and fades in a little after the one before it.
  fileprivate func rise(_ shown: Bool, index: Int, reduceMotion: Bool) -> some View {
    self
      .opacity(shown ? 1 : 0)
      .offset(y: shown || reduceMotion ? 0 : 12)
      .animation(
        reduceMotion
          ? nil : .spring(response: 0.5, dampingFraction: 0.85).delay(0.06 + Double(index) * 0.09),
        value: shown)
  }
}

/// The finish mark on the thank-you: after "Solved, don't send" a green ring and check draw
/// themselves; after sending, a paper plane takes off from a green disc. Still with Reduce Motion.
struct FeedbackDoneMark: View {
  let isHelped: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var drawn = false

  var body: some View {
    ZStack {
      Circle().fill(Color.stSuccess.opacity(0.14))
      Circle()
        .trim(from: 0, to: drawn ? 1 : 0)
        .stroke(Color.stSuccess, style: StrokeStyle(lineWidth: 3, lineCap: .round))
        .rotationEffect(.degrees(-90))
      if isHelped {
        FeedbackCheckShape()
          .trim(from: 0, to: drawn ? 1 : 0)
          .stroke(Color.stSuccess, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
          .frame(width: 24, height: 18)
      } else {
        Image(systemName: "paperplane.fill")
          .font(.system(size: 22, weight: .semibold))
          .foregroundStyle(Color.stSuccess)
          .offset(x: drawn ? 0 : -10, y: drawn ? 0 : 8)
          .opacity(drawn ? 1 : 0)
      }
    }
    .frame(width: 60, height: 60)
    .onAppear {
      withAnimation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.8).delay(0.05)) {
        drawn = true
      }
    }
  }
}

private struct FeedbackCheckShape: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.midY))
    path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    return path
  }
}

/// The measured height of the help card list.
private struct FeedbackCardsHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
