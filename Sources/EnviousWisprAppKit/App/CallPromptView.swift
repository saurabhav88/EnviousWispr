import SwiftUI

/// The card's data/actions still belong to the presenter. Its local motion has one finite
/// lifetime per presentation; countdown text and refreshed action closures do not recreate it.
struct CallPromptView: View {
  let model: CallPromptModel
  /// Standalone renders can explicitly use the compiled app's catalog. Live presentation
  /// leaves resources untouched and retains the app-hosted Bundle.main lookup contract.
  var resourceTransform: ((LocalizedStringResource) -> LocalizedStringResource)? = nil
  /// The system environment value is read-only; standalone renders opt into its static branch.
  var reduceMotionOverride: Bool? = nil

  var body: some View {
    if let content = model.content {
      CallPromptCard(content: content, actions: model.actions, resourceTransform: resourceTransform,
        reduceMotionOverride: reduceMotionOverride)
        .id(model.presentationID)
    }
  }
}

private struct CallPromptCard: View {
  let content: CallPromptContent
  let actions: CallPromptActions
  let resourceTransform: ((LocalizedStringResource) -> LocalizedStringResource)?
  let reduceMotionOverride: Bool?
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }
  @State private var entered = false
  @State private var waveProgress = 0.0

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .center, spacing: 14) {
        WisprLogoMark(waveProgress: reduceMotion ? 0 : waveProgress)
          .frame(width: 56, height: 56)
          .frame(width: 64, height: 64)
          .background(Color.stPageBg, in: RoundedRectangle(cornerRadius: 16))
          .animation(reduceMotion ? nil : .easeInOut(duration: 1.1).delay(0.3), value: waveProgress)
        VStack(alignment: .leading, spacing: 4) {
          Text(resource(title(content)))
            .font(.system(size: 19, weight: .bold))
            .foregroundStyle(Color.stTextPrimary)
            .fixedSize(horizontal: false, vertical: true)
          if let detail = detail(content) {
            Text(resource(detail))
              .font(.system(size: 14))
              .foregroundStyle(Color.stTextSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      buttons(content)
    }
    .padding(18)
    .frame(width: 340, alignment: .leading)
    .background(Color.stSectionBg, in: RoundedRectangle(cornerRadius: 16))
    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.obRainbow, lineWidth: 1))
    .shadow(color: Color.stAccentSolid.opacity(0.15), radius: 12)
    .shadow(color: Color.black.opacity(0.18), radius: 18, y: 8)
    .scaleEffect(reduceMotion || entered ? 1 : 0.55, anchor: .top)
    .offset(y: reduceMotion || entered ? 0 : -18)
    .opacity(reduceMotion || entered ? 1 : 0)
    .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.7), value: entered)
    .padding(20)
    .accessibilityElement(children: .contain)
    .onAppear {
      entered = true
      waveProgress = reduceMotion ? 0 : 1
    }
    .onDisappear(perform: stopMotion)
    .onChange(of: reduceMotion) { _, enabled in
      if enabled { stopMotion() }
    }
  }

  private func stopMotion() {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      entered = true
      waveProgress = 0
    }
  }

  private func resource(_ value: LocalizedStringResource) -> LocalizedStringResource {
    resourceTransform?(value) ?? value
  }

  private func title(_ content: CallPromptContent) -> LocalizedStringResource {
    switch content {
    case .ask:
      LocalizedStringResource(
        "Want me to take notes?", comment: "EnviousMeet: friendly question when a call app uses the microphone.")
    case .switchMeeting(let app):
      LocalizedStringResource(
        "New call in \(app). Start a new recording?",
        comment: "EnviousMeet: a new call started while a meeting records; the app's name.")
    case .countdown(let seconds):
      LocalizedStringResource(
        "Meeting ending in \(seconds) seconds",
        comment: "EnviousMeet: the call ended; the recording stops after this many seconds.")
    case .stopped, .switchNotConfirmed:
      LocalizedStringResource(
        "Recording stopped", comment: "EnviousMeet: the detected meeting stopped.")
    case .needsAttention:
      LocalizedStringResource(
        "EnviousMeet needs your attention before it can record",
        comment:
          "EnviousMeet: a call started, but a permission or the call sound explainer is needed first."
      )
    case .couldNotStart:
      LocalizedStringResource(
        "EnviousMeet could not start recording",
        comment: "EnviousMeet: Yes to Record this call?, but the recording could not start.")
    case .firstTip:
      LocalizedStringResource(
        "Tip: you can turn off call prompts for some apps in EnviousMeet settings.",
        comment: "EnviousMeet: shown once after the first No to Record this call?")
    case .lastTip(let app):
      LocalizedStringResource(
        "You said No to \(app) a few times. Last reminder: you can turn off \(app) in EnviousMeet settings.",
        comment: "EnviousMeet: shown once after the third No for one app; the app's name twice.")
    }
  }

  private func detail(_ content: CallPromptContent) -> LocalizedStringResource? {
    switch content {
    case .ask(let app):
      LocalizedStringResource(
        "\(app) is using the microphone. I can start a recording.",
        comment: "EnviousMeet: observed microphone use, including prejoin; the app name. Recording is offered, not started.")
    case .stopped:
      // No promise about the transcript: a close that timed out finishes on the next launch.
      LocalizedStringResource(
        "The call ended.", comment: "EnviousMeet: under Recording stopped.")
    case .switchNotConfirmed:
      LocalizedStringResource(
        "The new call could not be confirmed.",
        comment: "EnviousMeet: under Recording stopped, after a switch to a new call that could not be checked.")
    case .couldNotStart:
      LocalizedStringResource(
        "Open EnviousMeet to see why.",
        comment: "EnviousMeet: under EnviousMeet could not start recording.")
    default: nil
    }
  }

  @ViewBuilder private func buttons(_ content: CallPromptContent) -> some View {
    HStack(spacing: 8) {
      switch content {
      case .ask, .switchMeeting:
        button(
          content.isSwitch
            ? LocalizedStringResource("Start a new recording", comment: "EnviousMeet: switch to the newly detected call.")
            : LocalizedStringResource("Start recording", comment: "EnviousMeet: accept the offered call recording."),
          primary: true
        ) {
          actions.yes()
        }
        button(
          LocalizedStringResource("Not now", comment: "EnviousMeet: decline recording; do not ask again during this call."),
          primary: false
        ) {
          actions.no()
        }
      case .countdown:
        button(
          LocalizedStringResource(
            "Keep recording", comment: "EnviousMeet: stops the countdown; the meeting goes on."),
          primary: true
        ) {
          actions.keepRecording()
        }
      case .stopped, .switchNotConfirmed:
        button(
          LocalizedStringResource(
            "Start a new recording", comment: "EnviousMeet: after a detected meeting stopped."),
          primary: true
        ) {
          actions.startNewRecording()
        }
        button(
          LocalizedStringResource("Close", comment: "EnviousMeet: closes the call panel."),
          primary: false
        ) {
          actions.dismiss()
        }
      case .needsAttention, .couldNotStart, .firstTip, .lastTip:
        button(
          LocalizedStringResource(
            "Open settings", comment: "EnviousMeet: opens the EnviousMeet settings page."),
          primary: true
        ) {
          actions.openSettings()
        }
        button(
          LocalizedStringResource("Close", comment: "EnviousMeet: closes the call panel."),
          primary: false
        ) {
          actions.dismiss()
        }
      }
    }
  }

  private func button(_ title: LocalizedStringResource, primary: Bool, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Text(resource(title))
        .font(.system(size: 15, weight: primary ? .bold : .medium))
        .foregroundStyle(primary ? Color.white : Color.stTextPrimary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, primary ? 12 : 16)
        .frame(maxWidth: primary ? .infinity : nil, minHeight: 44)
        .background(primary ? Color.stAccentSolid : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(primary ? Color.clear : Color.stInputBorder, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
    .buttonStyle(.plain)
  }
}

private extension CallPromptContent {
  var isSwitch: Bool {
    if case .switchMeeting = self { return true }
    return false
  }
}
