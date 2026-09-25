import AppKit
import EnviousWisprServices
import SwiftUI

/// The bug button beside Record in the window's top bar, and the Send Feedback popover it opens
/// (#3153). The founder moved feedback here from the menu bar and the sidebar (2026-09-25): one
/// place, the familiar bug icon, a popover that closes itself once the report is on its way.
struct FeedbackToolbarButton: View {
  @State private var isPresented = false

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      Image(systemName: "ladybug")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.stAccent)
        .frame(width: 30, height: 28)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.stAccentLight)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.stAccent.opacity(isPresented ? 0.55 : 0.22), lineWidth: 1)
            .allowsHitTesting(false)
        )
        .settingsHoverRow(cornerRadius: 8)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
    .help(Self.title)
    .accessibilityLabel(Self.title)
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      FeedbackForm { isPresented = false }
    }
  }

  static var title: String {
    String(localized: "feedback.title", defaultValue: "Send feedback")
  }
}

/// The report itself: a message, an optional reply address, Send. `FeedbackReporter` owns the
/// validity rule (`FeedbackDraft`) and the send; this view only renders them.
struct FeedbackForm: View {
  /// Closes the popover after the thank-you has been on screen for a moment.
  let onDone: () -> Void

  private enum Status: Equatable { case editing, sent, unavailable }

  @State private var message = ""
  @State private var email = ""
  @State private var status: Status = .editing
  @FocusState private var focus: Field?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let draftStore = FeedbackDraftStore()

  private enum Field: Hashable { case message, email }

  private var issue: FeedbackDraft.Issue? {
    FeedbackDraft.issue(message: message, email: email)
  }

  var body: some View {
    ZStack {
      if status == .sent {
        thanks.transition(.opacity)
      } else {
        form.transition(.opacity)
      }
    }
    .frame(width: 400)
    .background(Color.stPageBg)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: status)
    .onAppear {
      message = draftStore.message
      email = draftStore.email
      focus = .message
    }
    // Every keystroke is kept, so closing the popover, the window or the app loses nothing.
    .onChange(of: message) { _, _ in if status != .sent { draftStore.save(message: message, email: email) } }
    .onChange(of: email) { _, _ in if status != .sent { draftStore.save(message: message, email: email) } }
  }

  // MARK: - Form

  private var form: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      messageEditor
      emailField
      footer
    }
    .padding(18)
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: "ladybug.fill")
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 36, height: 36)
        .background(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(
              LinearGradient(
                colors: [
                  Color(.sRGB, red: 0.604, green: 0.361, blue: 0.965, opacity: 1),
                  Color(.sRGB, red: 0.486, green: 0.227, blue: 0.929, opacity: 1),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .shadow(color: Color.stAccent.opacity(0.3), radius: 6, y: 2)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(FeedbackToolbarButton.title)
          .font(.stRowTitle)
          .foregroundStyle(.stTextPrimary)
        Text(
          String(
            localized: "feedback.subtitle",
            defaultValue: "Found a bug or have an idea? We read every message.")
        )
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var messageEditor: some View {
    TextEditor(text: $message)
      .font(.stBody)
      .scrollContentBackground(.hidden)
      .focused($focus, equals: .message)
      .padding(.horizontal, 8)
      .padding(.vertical, 8)
      .frame(height: 150)
      .overlay(alignment: .topLeading) {
        if message.isEmpty {
          Text(
            String(
              localized: "feedback.message.placeholder",
              defaultValue: "What happened, or what would you like to see?")
          )
          .font(.stBody)
          .foregroundStyle(.stTextTertiary)
          .padding(.horizontal, 13)
          .padding(.vertical, 8)
          .allowsHitTesting(false)
        }
      }
      .overlay(alignment: .topTrailing) {
        if issue == .messageTooLong { warning.padding(10) }
      }
      .fieldChrome(focused: focus == .message, invalid: issue == .messageTooLong)
      .help(Text(verbatim: issue == .messageTooLong ? Self.tooLongText : ""))
      .accessibilityLabel(
        String(localized: "feedback.message.label", defaultValue: "Feedback message")
      )
      .accessibilityHint(Text(verbatim: issue == .messageTooLong ? Self.tooLongText : ""))
  }

  private var emailField: some View {
    HStack(spacing: 8) {
      Image(systemName: "envelope")
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(focus == .email ? Color.stAccent : Color.stTextTertiary)
        .accessibilityHidden(true)
      TextField(
        String(
          localized: "feedback.email.placeholder",
          defaultValue: "Email (optional, if you'd like a reply)"),
        text: $email
      )
      .textFieldStyle(.plain)
      .font(.stBody)
      .focused($focus, equals: .email)
      .onSubmit(send)
      if issue == .invalidEmail { warning }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .fieldChrome(focused: focus == .email, invalid: issue == .invalidEmail)
    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .onTapGesture { focus = .email }
    .help(Text(verbatim: issue == .invalidEmail ? Self.invalidEmailText : ""))
    .accessibilityHint(Text(verbatim: issue == .invalidEmail ? Self.invalidEmailText : ""))
  }

  private var footer: some View {
    HStack(alignment: .center, spacing: 10) {
      if status == .unavailable {
        Text(
          String(
            localized: "feedback.unavailable",
            defaultValue: "Couldn't send. Email hello@enviouslabs.co")
        )
        .font(.stHelper)
        .foregroundStyle(.stError)
        .fixedSize(horizontal: false, vertical: true)
      } else {
        Text(verbatim: "⌘↩")
          .font(.stHelper)
          .foregroundStyle(.stTextTertiary)
          .accessibilityHidden(true)
      }
      Spacer(minLength: 0)
      sendButton
    }
  }

  private var sendButton: some View {
    let enabled = issue == nil
    return Button(action: send) {
      HStack(spacing: 7) {
        Image(systemName: "paperplane.fill")
          .font(.system(size: 13, weight: .semibold))
        Text(String(localized: "feedback.send", defaultValue: "Send"))
          .font(.system(size: 14, weight: .semibold))
      }
      .foregroundStyle(.white)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(
            LinearGradient(
              colors: [
                Color(.sRGB, red: 0.604, green: 0.361, blue: 0.965, opacity: 1),
                Color(.sRGB, red: 0.486, green: 0.227, blue: 0.929, opacity: 1),
              ],
              startPoint: .top, endPoint: .bottom))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
          .allowsHitTesting(false)
      )
      .shadow(color: Color.stAccent.opacity(enabled ? 0.35 : 0), radius: 6, y: 2)
      .opacity(enabled ? 1 : 0.4)
      .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .keyboardShortcut(.return, modifiers: .command)
  }

  // MARK: - Thank-you

  private var thanks: some View {
    VStack(spacing: 12) {
      Image(systemName: "checkmark")
        .font(.system(size: 22, weight: .bold))
        .foregroundStyle(.white)
        .frame(width: 52, height: 52)
        .background(Circle().fill(Color.stSuccess))
        .shadow(color: Color.stSuccess.opacity(0.35), radius: 8, y: 3)
        .accessibilityHidden(true)
      Text(String(localized: "feedback.sent.title", defaultValue: "Thanks, it's on its way"))
        .font(.stRowTitle)
        .foregroundStyle(.stTextPrimary)
      Text(
        String(
          localized: "feedback.sent.detail",
          defaultValue: "If you left your email, we'll reply there.")
      )
      .font(.stHelper)
      .foregroundStyle(.stTextSecondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 40)
    .accessibilityElement(children: .combine)
  }

  // MARK: - Actions

  private func send() {
    guard let draft = FeedbackDraft(message: message, email: email) else { return }
    switch FeedbackReporter.send(draft) {
    case .queued:
      draftStore.clear()
      status = .sent
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(1.8))
        onDone()
      }
    case .unavailable:
      // Keep the words so they can be pasted into an email.
      status = .unavailable
    }
  }

  // MARK: - Pieces

  private static var invalidEmailText: String {
    String(localized: "feedback.email.invalid", defaultValue: "Enter a valid email address")
  }

  private static var tooLongText: String {
    String(localized: "feedback.message.tooLong", defaultValue: "Maximum 4,000 characters")
  }

  /// Marks the field that blocks Send, so the reason is not carried by color alone. Decoration:
  /// the field carries the tooltip and hint, and a click on the symbol reaches the field.
  private var warning: some View {
    Image(systemName: "exclamationmark.circle.fill")
      .foregroundStyle(Color.stError)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}

extension View {
  /// The popover's field look: a soft input well that lights up in brand purple while focused and
  /// turns the error colour when its value blocks Send.
  fileprivate func fieldChrome(focused: Bool, invalid: Bool) -> some View {
    self
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.stInputBg)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .strokeBorder(
            invalid ? Color.stError : (focused ? Color.stAccent : Color.stInputBorder),
            lineWidth: focused || invalid ? 1.5 : 1
          )
          .allowsHitTesting(false)
      )
      .shadow(color: focused ? Color.stAccent.opacity(0.18) : .clear, radius: 6)
  }
}
