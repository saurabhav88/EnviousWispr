import Foundation

/// Whether EnviousMeet may open the Zoom app's participants panel during a recorded call (#4013
/// r4, founder 2026-10-28). Speaker names need the panel's complete list (`ZoomAppSpeakerReader`),
/// and Zoom keeps it closed by default. Pure: the observer supplies snapshots and state, performs
/// the press on its own AX queue, and reports back. At most one press per meeting, never a close,
/// and a panel the user has had open and then closed is never reopened.
package enum ZoomParticipantsPanelPolicy {
  static let meetingWindowIdentifier = "zm.meeting.window.main"
  static let closedPanelButtonPrefix = "Open participants panel, closed"

  /// One bounded copy of the linked Zoom call's windows, with what the copy itself cannot show.
  package struct Snapshot: Sendable, Equatable {
    package let windows: [CallAXWindow]
    /// The copy reached every element within its bounds and every read succeeded.
    package let isComplete: Bool
    /// Host time, in nanoseconds, when the copy started: its oldest read can be no older, so age
    /// is measured from here, never from when a long walk finished.
    package let startedAtNanos: UInt64
    /// Host time, in nanoseconds, when the copy finished.
    package let finishedAtNanos: UInt64
    /// The call link this copy was taken for; a relink makes it another call's copy.
    package let linkGeneration: UInt64

    package init(
      windows: [CallAXWindow], isComplete: Bool, startedAtNanos: UInt64, finishedAtNanos: UInt64,
      linkGeneration: UInt64
    ) {
      self.windows = windows
      self.isComplete = isComplete
      self.startedAtNanos = startedAtNanos
      self.finishedAtNanos = finishedAtNanos
      self.linkGeneration = linkGeneration
    }

    /// Taken in order, finished by `now`, and started no more than `maxAge` before it.
    func isFresh(nowNanos: UInt64, maxAgeNanos: UInt64) -> Bool {
      startedAtNanos <= finishedAtNanos && finishedAtNanos <= nowNanos
        && nowNanos - startedAtNanos <= maxAgeNanos
    }
  }

  /// One meeting's panel history.
  package struct State: Sendable, Equatable {
    /// The participants list has been seen open in this meeting.
    package private(set) var observedOpen = false
    /// The one press is used up: admitted, refused at the last check, failed or timed out.
    package private(set) var attemptSpent = false

    package init() {}

    /// Notes a snapshot of this meeting. Only an unambiguous open list counts as open.
    package mutating func observe(_ snapshot: Snapshot) {
      if case .open = ZoomParticipantsPanelPolicy.panel(in: snapshot.windows) {
        observedOpen = true
      }
    }

    /// Spends the allowance and says whether this caller may go on to the final check. Called
    /// before the press is admitted, so two callers or a retry can never press twice.
    package mutating func admit() -> Bool {
      guard !attemptSpent else { return false }
      attemptSpent = true
      return true
    }
  }

  package enum Refusal: String, Sendable, Equatable {
    case settingOff, attemptSpent, observedOpenBefore, noSnapshot, incompleteSnapshot
    case staleSnapshot, otherCall, notOneMeetingWindow, panelOpen, noButton, ambiguousButton
    case notRecording, paused, invalidated, noPermission, dictating
  }

  package enum Decision: Sendable, Equatable {
    case press
    case refuse(Refusal)
  }

  enum Panel: Equatable {
    case open
    case closedWithOneButton
    case noButton
    case ambiguous
  }

  /// What the meeting window shows. A participants list anywhere counts as open; otherwise the
  /// one meeting window must hold exactly one closed-panel button.
  static func panel(in windows: [CallAXWindow]) -> Panel {
    let meeting = windows.filter { $0.root.identifier == meetingWindowIdentifier }
    guard meeting.count == 1, let window = meeting.first else { return .ambiguous }
    let nodes = window.root.allNodes
    if nodes.contains(where: {
      $0.role == "AXOutline" && $0.label == ZoomAppSpeakerReader.participantsListLabel
    }) {
      return .open
    }
    let buttons = nodes.filter {
      $0.role == "AXButton" && ($0.label?.hasPrefix(closedPanelButtonPrefix) ?? false)
    }
    switch buttons.count {
    case 0: return .noButton
    case 1: return .closedWithOneButton
    default: return .ambiguous
    }
  }

  /// The decision to try a press, from the latest snapshot. Refusals for a missing, partial,
  /// old or other-call snapshot come before anything is read from it.
  package static func decide(
    settingOn: Bool, snapshot: Snapshot?, state: State, currentLinkGeneration: UInt64,
    nowNanos: UInt64, maxAgeNanos: UInt64
  ) -> Decision {
    guard settingOn else { return .refuse(.settingOff) }
    guard !state.attemptSpent else { return .refuse(.attemptSpent) }
    guard !state.observedOpen else { return .refuse(.observedOpenBefore) }
    guard let snapshot else { return .refuse(.noSnapshot) }
    guard snapshot.isComplete else { return .refuse(.incompleteSnapshot) }
    guard snapshot.isFresh(nowNanos: nowNanos, maxAgeNanos: maxAgeNanos) else {
      return .refuse(.staleSnapshot)
    }
    guard snapshot.linkGeneration == currentLinkGeneration else { return .refuse(.otherCall) }
    switch panel(in: snapshot.windows) {
    case .closedWithOneButton: return .press
    case .open: return .refuse(.panelOpen)
    case .noButton: return .refuse(.noButton)
    case .ambiguous:
      let meeting = snapshot.windows.filter { $0.root.identifier == meetingWindowIdentifier }
      return .refuse(meeting.count == 1 ? .ambiguousButton : .notOneMeetingWindow)
    }
  }

  /// What `State.admit()` let through: the call link and the observer's invalidation
  /// generation at that moment. The observer advances the invalidation generation on every pause,
  /// stop, relink, permission loss and quit, so an action admitted before any of them stays
  /// refused even after the state looks normal again (a pause, then a resume).
  package struct Admission: Sendable, Equatable {
    package let linkGeneration: UInt64
    package let invalidationGeneration: UInt64

    package init(linkGeneration: UInt64, invalidationGeneration: UInt64) {
      self.linkGeneration = linkGeneration
      self.invalidationGeneration = invalidationGeneration
    }
  }

  /// What the observer knows at the moment of the press, read again on its AX queue.
  package struct FinalCheck: Sendable, Equatable {
    package let recording: Bool
    package let paused: Bool
    package let linkGeneration: UInt64
    package let invalidationGeneration: UInt64
    package let settingOn: Bool
    package let accessibilityAllowed: Bool
    package let dictationIdle: Bool
    /// A fresh copy of the meeting window taken for this check.
    package let snapshot: Snapshot

    package init(
      recording: Bool, paused: Bool, linkGeneration: UInt64, invalidationGeneration: UInt64,
      settingOn: Bool, accessibilityAllowed: Bool, dictationIdle: Bool, snapshot: Snapshot
    ) {
      self.recording = recording
      self.paused = paused
      self.linkGeneration = linkGeneration
      self.invalidationGeneration = invalidationGeneration
      self.settingOn = settingOn
      self.accessibilityAllowed = accessibilityAllowed
      self.dictationIdle = dictationIdle
      self.snapshot = snapshot
    }
  }

  /// The last check before AXPress, after `State.admit()` returned true. `state` is the latest
  /// history, so a panel seen open (and closed by the user) after admission is still respected.
  /// Any refusal leaves the allowance spent: there is no second attempt.
  package static func finalCheck(
    _ check: FinalCheck, state: State, admitted: Admission, nowNanos: UInt64, maxAgeNanos: UInt64
  ) -> Decision {
    guard check.recording else { return .refuse(.notRecording) }
    guard !check.paused else { return .refuse(.paused) }
    guard check.invalidationGeneration == admitted.invalidationGeneration else {
      return .refuse(.invalidated)
    }
    guard check.linkGeneration == admitted.linkGeneration,
      check.snapshot.linkGeneration == admitted.linkGeneration
    else { return .refuse(.otherCall) }
    guard !state.observedOpen else { return .refuse(.observedOpenBefore) }
    guard check.settingOn else { return .refuse(.settingOff) }
    guard check.accessibilityAllowed else { return .refuse(.noPermission) }
    guard check.dictationIdle else { return .refuse(.dictating) }
    guard check.snapshot.isComplete else { return .refuse(.incompleteSnapshot) }
    guard check.snapshot.isFresh(nowNanos: nowNanos, maxAgeNanos: maxAgeNanos) else {
      return .refuse(.staleSnapshot)
    }
    switch panel(in: check.snapshot.windows) {
    case .closedWithOneButton: return .press
    case .open: return .refuse(.panelOpen)
    case .noButton: return .refuse(.noButton)
    case .ambiguous: return .refuse(.ambiguousButton)
    }
  }
}
