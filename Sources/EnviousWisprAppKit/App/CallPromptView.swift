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
      CallPromptCard(
        content: content, actions: model.actions, resourceTransform: resourceTransform,
        reduceMotionOverride: reduceMotionOverride
      )
      .id(model.presentationID)
    }
  }
}

/// The slim EnviousMeet card (#4232): one row with the call's picture, a single line and ×,
/// then at most two 32 pt buttons. No name header: the rainbow line already says it is ours
/// (founder 2026-10-30).
private struct CallPromptCard: View {
  let content: CallPromptContent
  let actions: CallPromptActions
  let resourceTransform: ((LocalizedStringResource) -> LocalizedStringResource)?
  let reduceMotionOverride: Bool?
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }
  @State private var entered = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center, spacing: 12) {
        picture
        VStack(alignment: .leading, spacing: 2) {
          Text(resource(title))
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.stTextPrimary)
            .fixedSize(horizontal: false, vertical: true)
          if let detail {
            Text(resource(detail))
              .font(.system(size: 14))
              .foregroundStyle(Color.stTextSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Room for the × in the corner, so a long title never runs under it.
        .padding(.trailing, content.closes ? 18 : 0)
        if case .manualStart = content { recordingDot }
      }
      buttons
    }
    .padding(.vertical, 14)
    .padding(.horizontal, 16)
    .overlay(alignment: .topTrailing) {
      if content.closes { closeButton.padding(6) }
    }
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
    .onAppear { entered = true }
    .onDisappear(perform: stopMotion)
    .onChange(of: reduceMotion) { _, enabled in
      if enabled { stopMotion() }
    }
  }

  private var closeButton: some View {
    Button(action: actions.dismiss) {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color.stTextTertiary)
          .frame(width: 24, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        Text(
          resource(LocalizedStringResource("Close", comment: "EnviousMeet: closes the call panel."))
        ))
  }

  @ViewBuilder private var picture: some View {
    switch content {
    case .notesWriting:
      CallNotesLips(size: 40, animated: !reduceMotion)
    case .notesReady:
      CallNotesLips(size: 40, animated: false)
    case .ask(let identity), .switchMeeting(let identity), .endConfirmation(let identity),
      .switchNotConfirmed(let identity), .manualStart(let identity), .countdown(let identity?, _):
      CallAppIdentityTile(identity: identity, size: 40)
    case .countdown(nil, _), .needsAttention, .couldNotStart, .firstTip, .lastTip:
      CallNotesLips(size: 40, animated: false)
    }
  }

  private var recordingDot: some View {
    Circle()
      .fill(Color(red: 1, green: 0.353, blue: 0.416))
      .frame(width: 8, height: 8)
      .accessibilityHidden(true)
  }

  private func stopMotion() {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) { entered = true }
  }

  private func resource(_ value: LocalizedStringResource) -> LocalizedStringResource {
    resourceTransform?(value) ?? value
  }

  private var title: LocalizedStringResource {
    switch content {
    case .ask(let identity) where identity.family == .slack:
      LocalizedStringResource(
        "Take notes on this Slack huddle?",
        comment:
          "EnviousMeet: a Slack huddle uses the microphone; recording is offered, not started.")
    case .ask(let identity):
      LocalizedStringResource(
        "Take notes on this \(identity.shortName) call?",
        comment:
          "EnviousMeet: a call app uses the microphone; the app's short name. Recording is offered, not started."
      )
    case .switchMeeting(let identity):
      LocalizedStringResource(
        "New \(identity.shortName) call. Take notes on it instead?",
        comment: "EnviousMeet: a new call started while a meeting records; the app's short name.")
    case .endConfirmation:
      LocalizedStringResource(
        "Did your call end?",
        comment:
          "EnviousMeet: uncertain browser page ending; recording continues until the user explicitly stops it."
      )
    case .countdown(_, let seconds):
      LocalizedStringResource(
        "Recording stops in \(seconds) seconds",
        comment: "EnviousMeet: the call ended; the recording stops after this many seconds.")
    case .switchNotConfirmed(let identity):
      LocalizedStringResource(
        "Couldn't confirm the new \(identity.shortName) call",
        comment:
          "EnviousMeet: a switch stopped the old recording, but the new call could not be checked; the app's short name."
      )
    case .notesWriting:
      LocalizedStringResource(
        "Meeting recorded", comment: "EnviousMeet: the call ended and its recording is saved.")
    case .notesReady:
      LocalizedStringResource(
        "Your notes are ready",
        comment: "EnviousMeet: the meeting's transcript is saved and in History.")
    case .manualStart(.microphone(let withCallSound)):
      withCallSound
        ? LocalizedStringResource(
          "Taking notes from microphone and Mac sound",
          comment:
            "EnviousMeet: a recording started from the menu bar, with no call; it records the microphone and the Mac's sound."
        )
        : LocalizedStringResource(
          "Taking notes from microphone",
          comment:
            "EnviousMeet: a recording started from the menu bar, with no call; it records the microphone only."
        )
    case .manualStart(let identity) where identity.family == .slack:
      LocalizedStringResource(
        "Taking notes on this Slack huddle",
        comment: "EnviousMeet: a recording started from the menu bar during a Slack huddle.")
    case .manualStart(let identity):
      LocalizedStringResource(
        "Taking notes on this \(identity.shortName) call",
        comment:
          "EnviousMeet: a recording started from the menu bar during a call; the app's short name.")
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

  private var detail: LocalizedStringResource? {
    switch content {
    case .endConfirmation:
      LocalizedStringResource(
        "I'll keep recording unless you choose Stop recording.",
        comment:
          "EnviousMeet: uncertain browser ending only, never the native countdown. No answer or Keep recording continues recording."
      )
    case .notesWriting:
      LocalizedStringResource(
        "Writing your notes…",
        comment: "EnviousMeet: under Meeting recorded, while the transcript is written.")
    case .couldNotStart:
      LocalizedStringResource(
        "Open EnviousMeet to see why.",
        comment: "EnviousMeet: under EnviousMeet could not start recording.")
    default: nil
    }
  }

  @ViewBuilder private var buttons: some View {
    switch content {
    case .ask, .switchMeeting:
      HStack(spacing: 8) {
        startButton(actions.yes)
        notNowButton(actions.no)
      }
    case .switchNotConfirmed:
      HStack(spacing: 8) {
        startButton(actions.startNewRecording)
        notNowButton(actions.no)
      }
    case .endConfirmation:
      HStack(spacing: 8) {
        button(
          LocalizedStringResource(
            "Stop recording",
            comment: "EnviousMeet: explicitly confirm stopping after an uncertain browser ending."),
          primary: false, action: actions.stopRecording)
        button(
          LocalizedStringResource(
            "Keep recording",
            comment: "EnviousMeet: keep recording after an uncertain browser ending."),
          primary: true, action: actions.keepRecording)
      }
    case .countdown:
      button(
        LocalizedStringResource(
          "End recording",
          comment: "EnviousMeet: stops the recording now instead of after the countdown."),
        primary: true, action: actions.endRecording)
    case .notesReady:
      button(
        LocalizedStringResource(
          "Open", comment: "EnviousMeet: opens the recorded meeting in History."),
        primary: true, action: actions.open)
    case .needsAttention, .couldNotStart, .firstTip, .lastTip:
      button(
        LocalizedStringResource(
          "Open settings", comment: "EnviousMeet: opens the EnviousMeet settings page."),
        primary: true, action: actions.openSettings)
    case .notesWriting, .manualStart:
      EmptyView()
    }
  }

  private func startButton(_ action: @escaping @MainActor () -> Void) -> some View {
    button(
      LocalizedStringResource(
        "Start recording", comment: "EnviousMeet: accept the offered call recording."),
      primary: true, dot: true, action: action)
  }

  private func notNowButton(_ action: @escaping @MainActor () -> Void) -> some View {
    button(
      LocalizedStringResource(
        "Not now",
        comment:
          "EnviousMeet: decline this recording offer; a later microphone-use opportunity may ask again after the cooldown."
      ),
      primary: false, action: action)
  }

  private func button(
    _ title: LocalizedStringResource, primary: Bool, dot: Bool = false,
    action: @escaping @MainActor () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 8) {
        if dot {
          Circle()
            .fill(Color(red: 1, green: 0.353, blue: 0.416))
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
        }
        Text(resource(title))
          .font(.system(size: 14, weight: .semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.85)
      }
      .foregroundStyle(primary ? Color.white : Color.stTextPrimary)
      .padding(.horizontal, primary ? 12 : 16)
      .frame(maxWidth: primary ? .infinity : nil, minHeight: 36)
      .background(
        primary ? Color.stAccentSolid : Color.clear, in: RoundedRectangle(cornerRadius: 10)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10).stroke(
          primary ? Color.clear : Color.stInputBorder, lineWidth: 1)
      )
      .contentShape(RoundedRectangle(cornerRadius: 10))
    }
    .buttonStyle(.plain)
  }
}

/// The brand mark on a tile (#4232). At rest it is the normal logo (`WisprLogoMark`, the
/// favicon geometry), never the closed-mouth level-0 lips; while the notes are written it is the
/// rainbow lips moving gently. Reduce Motion shows the normal logo.
struct CallNotesLips: View {
  let size: CGFloat
  let animated: Bool

  var body: some View {
    Group {
      if animated {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
          let t = context.date.timeIntervalSinceReferenceDate
          RainbowLipsIcon(size: size * 0.82, audioLevel: Float(0.35 + 0.3 * sin(t * 2.4)))
        }
      } else {
        WisprLogoMark()
          .padding(size * 0.14)
      }
    }
    .frame(width: size, height: size)
    .background(Color.stPageBg, in: RoundedRectangle(cornerRadius: size * 0.25))
    .accessibilityHidden(true)
  }
}
