import EnviousWisprServices
import SwiftUI

/// Settings > Send Feedback (#3153): a message box, an optional email field and Send.
///
/// Deliberately nothing else on the page (founder, 2026-09-24): no disclaimer or explainer. What a
/// report carries is described in the privacy policy. Reports go to Sentry through
/// `FeedbackReporter`, which owns the validity rule (`FeedbackDraft`) and the send.
struct SendFeedbackView: View {
  private enum Status: Equatable { case idle, sent, unavailable }

  @State private var message = ""
  @State private var email = ""
  @State private var status: Status = .idle
  @FocusState private var emailFocused: Bool

  private var issue: FeedbackDraft.Issue? {
    FeedbackDraft.issue(message: message, email: email)
  }

  var body: some View {
    SettingsContentView {
      BrandedSection {
        BrandedRow {
          VStack(alignment: .leading, spacing: 12) {
            messageEditor
            emailField
            sendRow
          }
        }
      }
    }
  }

  private var messageEditor: some View {
    TextEditor(text: $message)
      .font(.stBody)
      .frame(minHeight: 160)
      .scrollContentBackground(.hidden)
      .padding(6)
      .background(Color.stSectionBg, in: RoundedRectangle(cornerRadius: 8))
      .overlay(alignment: .topLeading) {
        if message.isEmpty {
          Text(
            String(
              localized: "feedback.message.placeholder",
              defaultValue: "What happened, or what would you like to see?")
          )
          .font(.stBody)
          .foregroundStyle(.stTextSecondary)
          .padding(.horizontal, 11)
          .padding(.vertical, 6)
          .allowsHitTesting(false)
        }
      }
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(Color.stAccent.opacity(0.22), lineWidth: 1)
          .allowsHitTesting(false)
      )
      .accessibilityLabel(
        String(localized: "feedback.message.label", defaultValue: "Feedback message"))
  }

  private var emailField: some View {
    TextField(
      String(localized: "feedback.email.placeholder", defaultValue: "Email (optional)"),
      text: $email
    )
    .focused($emailFocused)
    .settingsFieldChrome(focused: $emailFocused)
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(Color.stError, lineWidth: issue == .invalidEmail ? 1.5 : 0)
        .allowsHitTesting(false)
    )
  }

  private var sendRow: some View {
    HStack(spacing: 10) {
      SettingsActionButton(
        title: status == .sent
          ? String(localized: "feedback.sent", defaultValue: "Sent")
          : String(localized: "feedback.send", defaultValue: "Send"),
        isEnabled: issue == nil && status != .sent,
        emphasis: .filled
      ) {
        send()
      }
      if status == .unavailable {
        Text(
          String(
            localized: "feedback.unavailable",
            defaultValue: "Couldn't send. Email hello@enviouslabs.co")
        )
        .settingsReadingCopy()
      }
      Spacer(minLength: 0)
    }
  }

  private func send() {
    guard let draft = FeedbackDraft(message: message, email: email) else { return }
    switch FeedbackReporter.send(draft) {
    case .queued:
      message = ""
      email = ""
      status = .sent
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(2))
        if status == .sent { status = .idle }
      }
    case .unavailable:
      // Keep the words so they can be pasted into an email.
      status = .unavailable
    }
  }
}
