#if DEBUG
  import EnviousWisprServices
  import Foundation
  import Observation

  /// One call pop-up the Pill Preview can play (#4232).
  struct CallPopupPreviewEntry: Identifiable, Equatable {
    let id: String
    let title: String
    let content: CallPromptContent
  }

  /// Every card `CallPromptContent` can show, with the app names a real call would use.
  enum CallPopupPreviewCatalog {
    static let all: [CallPopupPreviewEntry] = [
      .init(
        id: "ask", title: "Offer to record (Microsoft Teams)",
        content: .ask(appName: "Microsoft Teams")),
      .init(
        id: "switchMeeting", title: "New call while recording (Zoom)",
        content: .switchMeeting(appName: "Zoom")),
      .init(id: "firstTip", title: "First tip, after the first Not now", content: .firstTip),
      .init(
        id: "countdown", title: "Countdown, then Recording stopped",
        content: .countdown(secondsLeft: 10)),
      .init(
        id: "endConfirmation", title: "Did your call end? (browser call)", content: .endConfirmation
      ),
      .init(id: "stopped", title: "Recording stopped (call ended)", content: .stopped),
      .init(
        id: "stoppedByUser", title: "Recording stopped (stopped by you)", content: .stoppedByUser),
      .init(
        id: "lastTip", title: "Last reminder (Microsoft Teams)",
        content: .lastTip(appName: "Microsoft Teams")),
      .init(
        id: "switchNotConfirmed", title: "New call not confirmed", content: .switchNotConfirmed),
      .init(id: "needsAttention", title: "Needs your attention", content: .needsAttention),
      .init(id: "couldNotStart", title: "Could not start recording", content: .couldNotStart),
    ]

    /// How long the real card stays when nobody answers (`CallDetectionPolicy`). Nil: it waits
    /// for an answer.
    static func lifetime(of content: CallPromptContent) -> TimeInterval? {
      switch content {
      case .ask, .switchMeeting: CallDetectionPolicy.promptTimeout
      case .countdown: CallDetectionPolicy.countdownLength
      case .stopped, .stoppedByUser, .switchNotConfirmed: CallDetectionPolicy.stoppedOffer
      case .firstTip, .lastTip, .needsAttention, .couldNotStart: CallDetectionPolicy.noteTimeout
      case .endConfirmation: nil
      }
    }
  }

  /// Plays call pop-ups for a developer (#4232). It shows the real `CallPromptView` in its own
  /// `CallPromptPanel`, placed like the real one, and keeps it up as long as the real card
  /// stays. It never touches call detection: a button only closes the preview and says so.
  /// It refuses while a real call pop-up is on screen and closes if one appears.
  @MainActor
  @Observable
  final class CallPopupPreviewController {

    enum Outcome: Equatable {
      case idle
      case shown(String)
      case ended(String)
      case notShown(String)
    }

    var selectedID: String
    private(set) var outcome: Outcome = .idle
    /// The last button pressed on a preview card, for the status line.
    private(set) var lastEvent: String?

    private struct Playing {
      let entry: CallPopupPreviewEntry
      var content: CallPromptContent
      let deadline: Date?
      let generation: Int
    }

    @ObservationIgnored private var playing: Playing?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let presenter: any CallPromptPresenting
    @ObservationIgnored private let realPopupIsShowing: @MainActor () -> Bool
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let usesTimer: Bool
    @ObservationIgnored let entries: [CallPopupPreviewEntry]

    /// `usesTimer: false` lets tests drive `tick()` themselves.
    init(
      presenter: any CallPromptPresenting,
      realPopupIsShowing: @escaping @MainActor () -> Bool,
      now: @escaping @MainActor () -> Date = { Date() },
      usesTimer: Bool = true,
      entries: [CallPopupPreviewEntry] = CallPopupPreviewCatalog.all
    ) {
      self.presenter = presenter
      self.realPopupIsShowing = realPopupIsShowing
      self.now = now
      self.usesTimer = usesTimer
      self.entries = entries
      self.selectedID = entries.first?.id ?? ""
    }

    var isPlaying: Bool { playing != nil }

    func play() {
      lastEvent = nil
      guard let entry = entries.first(where: { $0.id == selectedID }) else {
        stop()
        outcome = .notShown("no pop-up is selected")
        return
      }
      guard !realPopupIsShowing() else {
        stop()
        outcome = .notShown("a real call pop-up is on screen")
        return
      }
      show(entry, content: entry.content)
    }

    /// Closes only this controller's own card.
    func dismiss() {
      stop()
      outcome = .idle
      lastEvent = nil
    }

    /// Runs the card's clock: countdown ticks, the hand-over to Recording stopped, expiry, and
    /// stepping aside for a real pop-up.
    func tick() {
      guard let current = playing else { return }
      if realPopupIsShowing() {
        stop()
        outcome = .notShown("a real call pop-up appeared")
        return
      }
      guard let deadline = current.deadline else { return }
      let left = deadline.timeIntervalSince(now())
      if case .countdown = current.content {
        if left > 0 {
          // Same rounding as `CallDetectionCoordinator`.
          let next = CallPromptContent.countdown(secondsLeft: max(1, Int(ceil(left))))
          if next != current.content {
            playing?.content = next
            presenter.show(next, actions: actions(generation: current.generation))
          }
        } else {
          // A real call end hands the countdown over to Recording stopped.
          show(current.entry, content: .stopped)
        }
        return
      }
      if left <= 0 {
        stop()
        outcome = .ended(current.entry.title)
      }
    }

    private func show(_ entry: CallPopupPreviewEntry, content: CallPromptContent) {
      generation += 1
      playing = Playing(
        entry: entry, content: content,
        deadline: CallPopupPreviewCatalog.lifetime(of: content).map {
          now().addingTimeInterval($0)
        },
        generation: generation)
      presenter.show(content, actions: actions(generation: generation))
      outcome = .shown(entry.title)
      startTimer()
    }

    private func stop() {
      timer?.invalidate()
      timer = nil
      if playing != nil { presenter.hide() }
      playing = nil
      generation += 1
    }

    private func startTimer() {
      guard usesTimer, timer == nil else { return }
      // Common modes, like the real prompt clock: an open menu must not freeze the countdown.
      let clock = Timer(timeInterval: CallDetectionCoordinator.presentationTick, repeats: true) {
        [weak self] _ in
        Task { @MainActor in self?.tick() }
      }
      RunLoop.main.add(clock, forMode: .common)
      timer = clock
    }

    private func actions(generation: Int) -> CallPromptActions {
      func press(_ name: String) -> @MainActor () -> Void {
        { [weak self] in
          // A button on an older card cannot close a newer one.
          guard let self, let current = self.playing, current.generation == generation else {
            return
          }
          self.stop()
          self.outcome = .ended(current.entry.title)
          self.lastEvent = "Pressed \(name). A preview only closes; nothing else happens."
        }
      }
      return CallPromptActions(
        yes: press("Start recording"), no: press("Not now"),
        stopRecording: press("Stop recording"), keepRecording: press("Keep recording"),
        startNewRecording: press("Start a new recording"), openSettings: press("Open settings"),
        dismiss: press("Close"))
    }
  }
#endif
