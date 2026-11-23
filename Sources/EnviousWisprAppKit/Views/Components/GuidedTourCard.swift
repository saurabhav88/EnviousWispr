import SwiftUI

/// #4565: the guided tour's one card, shown inline above the page in the main window. It follows
/// the page the tour is on and its own controls, using the app's standard inline panel, and it only
/// ever asks for navigation: the user does every action the sentences describe.
struct GuidedTourCard: View {
  let phase: GuidedTourModel.Phase
  let plan: GuidedTourPlan
  /// Which run the card is showing; a new run announces its first stop again.
  let run: Int
  /// The stop's page, and the tab holding the control its sentence names, are what the window shows.
  let showing: Bool
  let showingHistory: Bool
  let dictationsFiltered: Bool
  let start: () -> Void
  let notNow: () -> Void
  let next: () -> Void
  let finish: () -> Void
  let open: (GuidedTourStop) -> Void
  let end: () -> Void

  private struct Announced: Equatable {
    let run: Int
    let stop: GuidedTourStop
  }

  /// The last stop announced, by run, so each of the three callbacks can announce without a repeat.
  @State private var announced: Announced?

  var body: some View {
    BrandedPanel(icon: "waveform", header: title, description: description) {
      HStack(spacing: DesignSpacing.md) {
        switch phase {
        case .offer:
          action("Start tour", emphasis: .filled, perform: start)
          action("Not now", emphasis: .quiet, perform: notNow)
        case .stop(let stop):
          if showing {
            if stop == plan.last {
              action("Finish tour", emphasis: .filled, perform: finish)
            } else {
              action("Next", emphasis: .filled, perform: next)
            }
          } else if !(stop == .history && showingHistory) {
            action(openTitle(stop), emphasis: .filled, perform: { open(stop) })
          }
          // #4903: "Finish tour" already ends the tour on the last stop, so a second exit there
          // would be a near-synonym the user cannot tell apart from it.
          if !(showing && stop == plan.last) {
            action("End tour", emphasis: .quiet, perform: end)
          }
          Spacer(minLength: DesignSpacing.md)
          if let position = plan.position(of: stop) {
            Text("\(position) of \(plan.count)")
              .font(.stHelper)
              .foregroundStyle(.stTextSecondary)
          }
        }
      }
    } footnote: {
      if case .stop(.history) = phase, showing, dictationsFiltered {
        Text("If you don’t see a recording, clear search or filters.")
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
      }
    }
    .accessibilityElement(children: .contain)
    .onAppear { announce() }
    .onChange(of: phase) { _, _ in announce() }
    .onChange(of: showing) { _, _ in announce() }
    .onChange(of: run) { _, _ in announce() }
  }

  /// One announcement per stop, made once the stop's page is actually showing: a stop blocked by
  /// the Setup leave question is not announced while that question is the only thing on screen.
  /// It covers a card that mounts on a stop (a replay) and every later stop. Focus is never moved.
  private func announce() {
    guard case .stop(let stop) = phase, showing, announced != Announced(run: run, stop: stop),
      let position = plan.position(of: stop)
    else { return }
    announced = Announced(run: run, stop: stop)
    let name = String(localized: stop.pageTitle)
    AccessibilityNotification.Announcement(
      String(localized: "\(name), \(position) of \(plan.count)")
    ).post()
  }

  private var title: LocalizedStringResource {
    switch phase {
    case .offer: "Take a quick tour"
    case .stop(let stop): stop.pageTitle
    }
  }

  private var description: LocalizedStringResource? {
    switch phase {
    case .offer:
      "See where everything is in EnviousWispr."
    case .stop(let stop):
      if stop == .history, !showing {
        showingHistory ? "Go back to the list if needed, then choose Dictations." : nil
      } else {
        showing ? Self.sentence(for: stop) : nil
      }
    }
  }

  /// One short sentence per stop. A control a sentence names is quoted from that control's own
  /// resource, so it reads as the screen shows it in every language.
  static func sentence(for stop: GuidedTourStop) -> LocalizedStringResource {
    switch stop {
    case .keybinds:
      let name = String(localized: KeybindsSettingsCopy.recordTitle)
      return "Set your dictation shortcut under \(name)."
    case .history:
      return "Your dictations are listed here. When one has a recording, press Play to hear it."
    case .dictation:
      return "Choose your speech engine, microphone and recording pill here."
    case .aiPolish:
      let name = String(localized: SettingsItemCopy.AIPolish.enable)
      return "Turn on \(name) to tidy your dictation with a model you choose."
    case .dictionary:
      let name = String(localized: SettingsItemCopy.Dictionary.addWord)
      return "Use \(name) to teach EnviousWispr names and terms."
    case .snippets:
      let name = String(localized: SettingsItemCopy.Snippets.add)
      return "Use \(name) to save text that appears when you say your keyword, then its trigger."
    case .transcribeFile:
      return "Choose an audio or video file here to get a transcript."
    case .meetings:
      return "EnviousMeet records your calls and turns them into transcripts."
    case .recordings:
      let name = String(localized: RecordingsSettingsCopy.saveTitle)
      return "Turn off \(name) to stop saving audio, or delete recordings here."
    }
  }

  private func openTitle(_ stop: GuidedTourStop) -> LocalizedStringResource {
    // Recordings is a tab of App Settings: the button names the tab the sentence is about.
    let name =
      stop == .recordings
      ? String(localized: AppSettingsTab.recordings.label)
      : String(localized: stop.pageTitle)
    return "Open \(name)"
  }

  private func action(
    _ title: LocalizedStringResource, emphasis: EnviousButtonFace.Emphasis = .outlined,
    perform: @escaping () -> Void
  ) -> some View {
    Button(action: perform) {
      EnviousButtonLabel(title, size: .medium)
    }
    .settingsButton(emphasis, shape: .roundedRect, size: .medium, isEnabled: true)
  }
}
