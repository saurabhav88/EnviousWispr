import SwiftUI

/// The shell's background download status. The same facts and actions drive the Downloads cards.
struct SetupDownloadPill: View {
  let model: SetupScreenModel

  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.overlayReduceMotionOverride) private var reduceMotionOverride

  var body: some View {
    if model.state.canInspectDownloads, let presentation = model.sources.downloads?(),
      let status = Self.status(presentation)
    {
      Button {
        if status == .stopped {
          model.sources.downloadActions.retryDownloads()
        } else {
          model.send(.inspectDownloads)
        }
      } label: {
        HStack(spacing: DesignSpacing.xs) {
          if status == .moving {
            SetupSpinner(reduceMotion: reduceMotionOverride ?? systemReduceMotion)
              .scaleEffect(0.5)
              .frame(width: 12, height: 12)
              .accessibilityHidden(true)
          }
          Text(status.title)
            .font(.firstRunCaption)
        }
        .padding(.horizontal, DesignSpacing.md)
        .padding(.vertical, DesignSpacing.xxs)
        .foregroundStyle(status == .stopped ? Color.firstRunErrorText : Color.obAccent)
        .background(Color.firstRunAccentSoft, in: Capsule())
      }
      .buttonStyle(.plain)
      .accessibilityHint(status == .stopped ? Text("Restarts downloads") : Text("Shows downloads"))
    }
  }

  enum Status: Equatable {
    case moving, ready, stopped

    var title: LocalizedStringKey {
      switch self {
      case .moving: "Downloading models"
      case .ready: "Models ready"
      case .stopped: "Download stopped · Try again"
      }
    }
  }

  static func status(_ p: OnboardingDownloadsPresentation) -> Status? {
    if p.block != nil || SetupGate.stopped(p.speechPhase) || p.polishPreparation == .downloadStopped {
      return .stopped
    }
    if p.downloadsFinished, p.speech != nil { return .ready }
    switch p.speechPhase {
    case .downloading?, .verifying?: return .moving
    default: break
    }
    switch p.polishPreparation {
    case .queued, .downloading: return .moving
    default: return nil
    }
  }
}
