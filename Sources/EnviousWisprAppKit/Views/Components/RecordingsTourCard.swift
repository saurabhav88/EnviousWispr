import SwiftUI

/// The tour follows the current page and its own controls, using the app's standard inline panel.
struct RecordingsTourCard: View {
  enum Stop: Equatable {
    case offer
    case history
    case recordings
  }

  let stop: Stop
  let showingHistory: Bool
  let showingDictations: Bool
  let showingRecordings: Bool
  let dictationsFiltered: Bool
  let start: () -> Void
  let openHistory: () -> Void
  let openRecordings: () -> Void
  let dismiss: () -> Void

  var body: some View {
    BrandedPanel(icon: "waveform", header: title, description: description) {
      HStack(spacing: DesignSpacing.md) {
        switch stop {
        case .offer:
          action("Start tour", perform: start)
        case .history:
          if showingDictations {
            action("Next", perform: openRecordings)
          } else if !showingHistory {
            action("Open History", perform: openHistory)
          }
        case .recordings:
          if !showingRecordings {
            action("Open Recordings settings", perform: openRecordings)
          }
        }
        action(stop == .offer ? "Not now" : "Done", emphasis: .quiet, perform: dismiss)
      }
    } footnote: {
      if stop == .history, showingDictations, dictationsFiltered {
        Text("If you don’t see a recording, clear search or filters.")
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
      }
    }
  }

  private var title: LocalizedStringResource {
    switch stop {
    case .offer: "Dictation recordings"
    case .history: "Play or delete a recording"
    case .recordings: "Manage recordings"
    }
  }

  private var description: LocalizedStringResource? {
    switch stop {
    case .offer:
      "Your dictation recordings are saved on this Mac. Take a quick look at where to play and manage them."
    case .history:
      if showingDictations {
        "Press Play to listen. To remove just the audio and keep the text, open More actions and choose Delete recording, keep text."
      } else if showingHistory {
        "Go back to the list if needed, then choose Dictations."
      } else {
        nil
      }
    case .recordings:
      if showingRecordings {
        "Turn off Save dictation recordings to stop saving new audio. Choose how long to keep recordings, or delete them all. Your text stays either way."
      } else {
        nil
      }
    }
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
