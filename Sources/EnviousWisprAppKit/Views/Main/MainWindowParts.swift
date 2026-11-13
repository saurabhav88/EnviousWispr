import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// Pipeline status badge in toolbar — renders nothing when idle/complete/error
/// (so it never shows in the resting frame), minimal during active states. It is
/// the only in-window phase cue on pages without the History status row, so the
/// toolbar keeps it alongside the record button.
struct StatusBadge: View {
  var textOverride: String? = nil
  // PR7 of #763: live phase resolves through LiveRecordingState.
  @Environment(LiveRecordingState.self) private var liveRecordingState

  var body: some View {
    Group {
      switch liveRecordingState.pipelineState {
      case .recording:
        pill {
          Image(systemName: "mic.fill")
            .foregroundStyle(.stError)
            .symbolEffect(.pulse)
          Text(DictationNarrator.recordingStatus)
            .foregroundStyle(.secondary)
        }

      case .loadingModel:
        progressLabel(DictationNarrator.loadingModelBadge)

      case .transcribing:
        progressLabel(DictationNarrator.statusBadgeCopy(for: .transcribing))

      case .polishing:
        progressLabel(DictationNarrator.statusBadgeCopy(for: .polishing))

      // #1891: advisory is a resting terminal like idle/complete/error, so the
      // toolbar badge stays empty. The sentence is carried by the overlay and
      // the main-window body, not duplicated in the toolbar.
      // #3972 R47: a meeting recording shows no badge here (stealth, founder F14); the menu
      // bar glow and the live Recordings row in History are its only signs.
      case .idle, .complete, .error, .advisory:
        EmptyView()
      }
    }
    .animation(.easeInOut(duration: 0.2), value: liveRecordingState.pipelineState)
  }

  private func progressLabel(_ text: String) -> some View {
    pill {
      ProgressView().controlSize(.small)
      Text(textOverride ?? text).foregroundStyle(.secondary)
    }
  }

  /// The badge owns its own capsule rather than borrowing the toolbar's.
  /// macOS 26 draws a Liquid Glass capsule behind a toolbar item and sized it
  /// narrower than this content, so the status words spilled past its
  /// right-hand border (founder screenshot, 2026-09-02). Owning the shape means
  /// the padding is ours; `fixedSize` keeps the words from being compressed by
  /// whatever width the toolbar offers.
  private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    HStack(spacing: 4, content: content)
      .font(.caption)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(Capsule().fill(Color.stTextSecondary.opacity(0.10)))
      .overlay(Capsule().strokeBorder(Color.stDivider, lineWidth: 1))
      .fixedSize()
  }
}

/// Hides the main window's titlebar title text while leaving `window.title` set.
/// The centered toolbar wordmark is the only visible identity, but the Window
/// menu, window switcher, and VoiceOver still read the app name (cloud review
/// #1311). Attached inside the main window's content, so `window` is always it.
struct MainWindowTitleHider: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { NSView() }

  func updateNSView(_ nsView: NSView, context: Context) {
    // Defer until the view is in a window; `.hidden` suppresses the titlebar
    // text without clearing `title`, so assistive tech keeps the name.
    DispatchQueue.main.async {
      nsView.window?.titleVisibility = .hidden
    }
  }
}

/// Record/stop button in the toolbar.
struct RecordButton: View {
  var titleOverride: String? = nil
  // PR7 of #763: live phase resolves through LiveRecordingState.
  @Environment(LiveRecordingState.self) private var liveRecordingState
  // PR10 of #763: toggle dispatches through DictationRuntime façade.
  @Environment(DictationRuntime.self) private var dictationRuntime

  var body: some View {
    let state = liveRecordingState.pipelineState
    let recording = state == .recording
    Button {
      Task {
        await dictationRuntime.toggleRecording(source: .toolbar)
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: recording ? "stop.fill" : "mic.fill")
          .font(.system(size: 11, weight: .semibold))
        Group {
          if let titleOverride {
            Text(verbatim: titleOverride)
          } else {
            Text(recording ? "Stop" : "Record")
          }
        }
        .font(.system(size: 13, weight: .semibold))
      }
      .foregroundStyle(.white)
      .padding(.horizontal, 13)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(
            LinearGradient(
              colors: recording
                ? [
                  Color(.sRGB, red: 0.855, green: 0.302, blue: 0.302, opacity: 1),
                  Color(.sRGB, red: 0.722, green: 0.208, blue: 0.161, opacity: 1),
                ]
                : [
                  Color(.sRGB, red: 0.604, green: 0.361, blue: 0.965, opacity: 1),
                  Color(.sRGB, red: 0.486, green: 0.227, blue: 0.929, opacity: 1),
                ],
              startPoint: .top, endPoint: .bottom))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
      )
      .shadow(color: (recording ? Color.stError : Color.stAccent).opacity(0.35), radius: 5, y: 2)
      // The most-pressed control in the window, and gradient-filled, so a tint
      // beneath it would not show. The veil goes on top for the same reason the
      // selected sidebar row's does. Gated on the same condition as `.disabled`
      // below, so a button that cannot be pressed does not answer the pointer.
      .settingsHoverRow(
        cornerRadius: 8,
        tint: SettingsHover.selectedRowVeil,
        isEnabled: !(state.isActive && !recording))
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
    .disabled(state.isActive && !recording)
    .help(recording ? "Stop recording" : "Start recording")
  }
}
