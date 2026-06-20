import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// Inner content for the History tab: transcript list (left) + detail/status (right).
///
/// #1024: a custom width-tracking split replaces `HSplitView`, which never
/// renegotiates pane widths when its container shrinks (the content canvas kept
/// its old total and clipped under the sidebar / off the window edge). Here the
/// effective list width is re-clamped against the live container width on every
/// render, so window shrink compresses the detail pane first, then the list down
/// to its readable floor; the root window minimum in WisprBootstrapper covers
/// sidebar + both floors so neither column can ever render broken.
struct HistoryContentView: View {
  @Environment(PermissionsService.self) private var permissions
  @Environment(TranscriptCoordinator.self) private var transcriptCoordinator
  // PR7 of #763: live-recording fallback transcript comes from LiveRecordingState.
  @Environment(LiveRecordingState.self) private var liveRecordingState

  /// User's preferred list width from divider drags; the effective width shown
  /// is this value re-clamped to the live container (see `effectiveListWidth`).
  @State private var preferredListWidth: CGFloat = HistorySplitMetrics.listIdeal

  /// PR7 of #763: compose the displayed transcript inline. History selection
  /// from `TranscriptCoordinator` wins over the in-flight live fallback —
  /// same priority the pre-PR7 root-state getter delivered.
  private var displayedTranscript: Transcript? {
    let tc = transcriptCoordinator
    if let selected = tc.selectedTranscriptID,
      let match = tc.transcripts.first(where: { $0.id == selected })
    {
      return match
    }
    return liveRecordingState.currentTranscript
  }

  var body: some View {
    VStack(spacing: 0) {
      if permissions.shouldShowAccessibilityWarning {
        AccessibilityWarningBanner()
      }

      GeometryReader { geo in
        let listWidth = HistorySplitMetrics.effectiveListWidth(
          preferred: preferredListWidth, available: geo.size.width)

        HStack(spacing: 0) {
          TranscriptHistoryView()
            .frame(width: listWidth)

          HistorySplitDivider(
            preferredListWidth: $preferredListWidth, currentListWidth: listWidth)

          Group {
            if let transcript = displayedTranscript {
              TranscriptDetailView(transcript: transcript)
            } else {
              StatusView()
            }
          }
          .frame(
            width: max(0, geo.size.width - listWidth - HistorySplitMetrics.dividerWidth))
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task {
      transcriptCoordinator.load()
    }
  }
}

/// Width allocation for the History split (#1024). Pure so the clamp
/// boundaries are unit-testable.
enum HistorySplitMetrics {
  static let listMin: CGFloat = 230
  static let listIdeal: CGFloat = 260
  static let listMax: CGFloat = 340
  static let detailMin: CGFloat = 260
  static let dividerWidth: CGFloat = 8

  /// Clamp the preferred list width to what the container can host: the list
  /// holds its preferred width until the detail pane would drop below its
  /// floor, then compresses to `listMin`. Containers too small for both floors
  /// degrade without negative frames (list keeps up to its floor, detail gets
  /// the non-negative remainder); the root window minimum prevents that state
  /// outside transient live-resize.
  static func effectiveListWidth(preferred: CGFloat, available: CGFloat) -> CGFloat {
    let maxHostable = min(listMax, available - detailMin - dividerWidth)
    guard maxHostable >= listMin else {
      return min(listMin, max(0, available - dividerWidth))
    }
    return min(max(preferred, listMin), maxHostable)
  }
}

/// Draggable boundary between the transcript list and the detail pane:
/// 1pt separator line inside an 8pt hit target.
private struct HistorySplitDivider: View {
  @Binding var preferredListWidth: CGFloat
  let currentListWidth: CGFloat

  @State private var dragBaseWidth: CGFloat?
  @State private var isHovering = false

  var body: some View {
    ZStack {
      Color.clear
      Rectangle()
        .fill(Color(nsColor: .separatorColor))
        .frame(width: 1)
    }
    .frame(width: HistorySplitMetrics.dividerWidth)
    .contentShape(Rectangle())
    .onHover { inside in
      if inside, !isHovering {
        NSCursor.resizeLeftRight.push()
        isHovering = true
      } else if !inside, isHovering {
        NSCursor.pop()
        isHovering = false
      }
    }
    .onDisappear {
      if isHovering {
        NSCursor.pop()
        isHovering = false
      }
    }
    .gesture(
      DragGesture(minimumDistance: 1)
        .onChanged { value in
          let base = dragBaseWidth ?? currentListWidth
          if dragBaseWidth == nil { dragBaseWidth = base }
          preferredListWidth = base + value.translation.width
        }
        .onEnded { _ in
          preferredListWidth = min(
            max(preferredListWidth, HistorySplitMetrics.listMin), HistorySplitMetrics.listMax)
          dragBaseWidth = nil
        }
    )
  }
}
