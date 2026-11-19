import AppKit
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import SwiftUI

extension View {
  /// #3147 PR4A: a deliberate user scroll (trackpad, wheel, scroller) suspends Follow playback.
  /// Programmatic scrolls do not count, and neither does a gesture that moves nothing: on a
  /// transcript shorter than its pane the phase still turns `.interacting` (founder #4611), so
  /// only a change of the content offset during the user's gesture counts.
  @ViewBuilder
  func meetingUserScroll(_ action: @escaping () -> Void) -> some View {
    if #available(macOS 15.0, *) {
      modifier(MeetingScrollPhaseObserver(action: action))
    } else {
      modifier(MeetingWheelScrollObserver(action: action))
    }
  }
}

/// macOS 15+: the user's gesture (`.interacting`, then `.decelerating` for its momentum) counts
/// as a scroll only once the content really moves by 1 pt in all, summed over the gesture's
/// updates (a slow drag moves less than that per update). The offset is clamped to the scrollable
/// range, so a rubber-band bounce (also on content that fits its pane) moves nothing; a change of
/// the content, pane or insets size starts the sum again rather than counting as movement.
@available(macOS 15.0, *)
private struct MeetingScrollPhaseObserver: ViewModifier {
  let action: () -> Void
  @State private var userDriven = false
  @State private var distance: CGFloat = 0

  func body(content: Content) -> some View {
    content
      .onScrollPhaseChange { _, phase in
        let next = phase == .interacting || phase == .decelerating
        if !next || !userDriven { distance = 0 }
        userDriven = next
      }
      .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { old, new in
        guard old.contentSize == new.contentSize, old.containerSize == new.containerSize,
          old.contentInsets == new.contentInsets, userDriven
        else {
          distance = 0
          return
        }
        distance += abs(Self.clampedOffset(new) - Self.clampedOffset(old))
        if distance >= 1 {
          distance = 0
          action()
        }
      }
  }

  nonisolated private static func clampedOffset(_ geometry: ScrollGeometry) -> CGFloat {
    let top = geometry.contentInsets.top
    let range = max(
      0,
      geometry.contentSize.height + top + geometry.contentInsets.bottom
        - geometry.containerSize.height)
    return min(max(geometry.contentOffset.y + top, 0), range)
  }
}

/// Registers and removes one process-local watcher for scroll-wheel, trackpad-scroll and
/// left-drag events (#3147 PR4A). The live conformer is `LiveHistoryScrollMonitor` in
/// `EnviousWisprDesktopEffects`, the only module allowed to call
/// `NSEvent.addLocalMonitorForEvents` (`scripts/check-dependency-direction.sh`); tests pass one
/// that never touches the desktop.
@MainActor
package protocol HistoryScrollMonitoring: AnyObject {
  /// Calls `handler` for every such event in the process and passes the event on unchanged.
  /// Returns the framework's token, or nil when AppKit refused.
  func install(_ handler: @escaping @MainActor () -> Void) -> Any?
  func remove(_ token: Any)
}

extension EnvironmentValues {
  /// The meeting page's scroll watcher on macOS 14, injected with the app's homes. Nil (a
  /// preview, a test): Follow playback is not suspended by the user's scrolling there.
  @Entry var historyScrollMonitor: (any HistoryScrollMonitoring)? = nil
}

/// macOS 14: a scroll-wheel or trackpad scroll, or a drag (the scroller, or selecting text),
/// while the pointer is over this scroll view counts as the user scrolling. Programmatic scrolls
/// send neither event.
private struct MeetingWheelScrollObserver: ViewModifier {
  let action: () -> Void
  @Environment(\.historyScrollMonitor) private var scrollMonitor
  @State private var hovering = false
  @State private var installed: (monitor: any HistoryScrollMonitoring, token: Any)?

  func body(content: Content) -> some View {
    content
      .onHover { hovering = $0 }
      .onAppear {
        guard installed == nil, let scrollMonitor else { return }
        // A wheel or trackpad scroll, or a drag on the scroller or in the text, over this view.
        if let token = scrollMonitor.install({ if hovering { action() } }) {
          installed = (scrollMonitor, token)
        }
      }
      .onDisappear {
        if let installed { installed.monitor.remove(installed.token) }
        installed = nil
      }
  }
}

/// "Return to playback" over the bottom of a transcript while the reader has scrolled away from
/// what plays (#4611 D13 meeting page, T9 transcript page).
struct HistoryReturnToPlaybackButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      EnviousButtonLabel(
        LocalizedStringResource(
          "Return to playback",
          comment: "History meeting: scrolls the transcript back to what is playing."),
        size: .medium, systemImage: "arrow.down.to.line")
    }
    .settingsButton(.filled, size: .medium, isEnabled: true)
    .fixedSize()
  }
}
