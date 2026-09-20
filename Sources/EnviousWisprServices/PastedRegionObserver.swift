import AppKit
import ApplicationServices
import EnviousWisprCore
import Foundation

// MARK: - Pasted-region observation (#996 §3.1 steps 2–4)
//
// The Services owner of "what happened to the text we just pasted". It does
// three bounded things and nothing else: CAPTURE the focused element and the
// pasted text's position inside it, OBSERVE that element for changes through
// an `AXObserver` plus a slow poll, and REPORT the current anchored region or a
// closed end reason. Token alignment, judging, proposal creation and the
// per-paste lifecycle (generations, two bursts, the stop-on-next-dictation
// rule) live in the App watcher (chunk 5e); nothing here decides whether an
// edit is a correction.
//
// Every Accessibility call goes through `PastedRegionAXOperations`, and every
// timer through `PastedRegionScheduling`, so the whole state machine runs under
// test with fakes: anchors, limits, the failure policy, cancellation and stale
// callbacks are all provable without a live element. What the fakes cannot
// prove (real notification delivery, focused-element behaviour in real apps,
// the Electron opt-in) is Live UAT in chunk 5h.

// MARK: - Contracts

/// The closed end-reason vocabulary (plan §3.1 step 4). Raw values are the
/// telemetry enum for `custom_words.learn_observation_ended.reason`, so a new
/// case is a schema change and gets a knowledge row.
///
/// The observer itself can end with every reason EXCEPT `settled` and
/// `nextDictationStarted`: settling is a non-terminal event here (the watcher
/// decides when a settled burst ends the watch), and the next dictation is a
/// pipeline fact the watcher observes.
package enum PastedRegionEndReason: String, Sendable, Equatable, CaseIterable {
  case settled
  case textboxEmptied = "textbox_emptied"
  case regionRemoved = "region_removed"
  case dictatedTextNotFound = "dictated_text_not_found"
  case anchorAmbiguous = "anchor_ambiguous"
  case focusChanged = "focus_changed"
  case elementDestroyed = "element_destroyed"
  case nextDictationStarted = "next_dictation_started"
  case editDistanceExceeded = "edit_distance_exceeded"
  case ceilingElapsed = "ceiling_elapsed"
  case captureUnsupported = "capture_unsupported"
  case permissionLost = "permission_lost"
  case appTerminated = "app_terminated"
}

/// One timing and bounds contract for the whole capture path. Values from the
/// plan (§3.1 steps 2–4, §3a `settleMs`); a reader of any consumer finds the
/// number here and nowhere else.
package enum PastedRegionTiming {
  /// Quiet time after the last change before a snapshot counts as settled.
  /// Plan §3a: from Wispr Flow's `next_dictation_started` rows; revisit only
  /// with at least 30 measured bursts.
  package static let settleMs = 1500
  /// The poll that backs (or replaces) `AXObserver` delivery while identity holds.
  package static let pollMs = 750
  /// Wall-clock ceiling from paste; observation never outlives it.
  package static let ceilingMs = 60_000
  /// Values longer than this are never read into memory as evidence.
  package static let maxValueUTF16 = 20_000
  /// Context kept either side of the pasted text to re-find the region.
  package static let anchorUTF16 = 64
  /// A region that moved further than this fraction of the pasted length from
  /// the pasted text is a rewrite, not an edit (`editDistanceExceeded`).
  package static let editDistanceLimitFraction = 0.5
  /// The budget never drops below this many UTF-16 units: a one-word paste
  /// ("Zorab", limit 2 by the fraction alone) must still admit its full
  /// replacement ("Saurabh", distance 4); a rewrite of a short paste is the
  /// judge's to refuse. Cloud review of PR #3054.
  package static let editDistanceLimitFloor = 12
  /// The banded distance costs about `pasted × (2 × limit + 1)` cells; above
  /// this budget the check is INCONCLUSIVE and the watch ends as
  /// `captureUnsupported` (a processing limit), never "within budget".
  /// 16M cells is about 4,000 pasted units at the 50% band.
  package static let editDistanceCellBudget = 16_000_000
  /// Consecutive failed or non-text reads before observation ends as
  /// `captureUnsupported`. Three polls is about two seconds: long enough to ride
  /// out a busy provider, short enough that a field that never answers does not
  /// hold a watch open to the ceiling.
  package static let maxConsecutiveReadFailures = 3
}

/// Up to `anchorUTF16` units of text either side of the pasted text, taken at
/// capture. Never split inside a Unicode scalar: a window that would cut a
/// surrogate pair is shortened by one unit.
package struct PastedRegionAnchors: Sendable, Equatable {
  package let before: String
  package let after: String

  package init(before: String, after: String) {
    self.before = before
    self.after = after
  }
}

/// A text change the observer saw, or the settled form of the last one.
package enum PastedRegionEvent: Sendable, Equatable {
  /// The anchored region now reads `region` (differs from the last report).
  case changed(region: String)
  /// `settleMs` passed with no further change since the last `changed`.
  /// Non-terminal: observation continues until an end reason.
  case settled(region: String)
  /// Observation is over; no further events are delivered.
  case ended(PastedRegionEndReason)
}

/// Why `capture` did not start a watch although nothing was wrong with the
/// pasted text: these are §3.2 gate skips, not observation end reasons.
package enum PastedRegionCaptureSkip: String, Sendable, Equatable, CaseIterable {
  case secureField = "secure_field"
  case noFocusedElement = "no_focused_element"
  /// The destination process is not the active application.
  case destinationMismatch = "destination_mismatch"
}

package enum PastedRegionCaptureOutcome: Equatable {
  case captured(PastedRegionTarget)
  case skipped(PastedRegionCaptureSkip)
  /// Nothing to observe: the value could not be read, was too long, did not
  /// contain the pasted text exactly once. Reported with the end reason the
  /// watcher records for the paste.
  case ended(PastedRegionEndReason)

  package static func == (lhs: Self, rhs: Self) -> Bool {
    switch (lhs, rhs) {
    case (.captured(let a), .captured(let b)): return a == b
    case (.skipped(let a), .skipped(let b)): return a == b
    case (.ended(let a), .ended(let b)): return a == b
    default: return false
    }
  }
}

/// Everything a watch needs, fixed at capture.
package struct PastedRegionTarget: Equatable {
  package let pid: pid_t
  package let application: AXUIElement
  package let element: AXUIElement
  package let pastedText: String
  package let anchors: PastedRegionAnchors
  /// Whether the application advertised `AXManualAccessibility` (an
  /// Electron/Chromium host). Telemetry `app_class` evidence for the watcher;
  /// never a bundle id.
  package let isManualAccessibilityHost: Bool
  /// When the paste landed, in the scheduler's clock; the 60 s ceiling is
  /// measured from here.
  package let pastedAtMs: Int

  package static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.pid == rhs.pid && CFEqual(lhs.application, rhs.application)
      && CFEqual(lhs.element, rhs.element) && lhs.pastedText == rhs.pastedText
      && lhs.anchors == rhs.anchors
      && lhs.isManualAccessibilityHost == rhs.isManualAccessibilityHost
      && lhs.pastedAtMs == rhs.pastedAtMs
  }
}

/// The observer the App watcher drives. `stop()` is idempotent and every
/// callback queued before it produces nothing afterwards.
@MainActor
package protocol PastedRegionObserving: AnyObject {
  /// `pastedAtMs` is the paste instant in the scheduler's clock.
  func capture(pid: pid_t, pastedText: String, pastedAtMs: Int) -> PastedRegionCaptureOutcome
  func start(
    _ target: PastedRegionTarget, onEvent: @escaping @MainActor (PastedRegionEvent) -> Void)
  func stop()
  var isObserving: Bool { get }
}

// MARK: - Seams

/// One read of an element's value, typed so a missing attribute, a non-string
/// answer and a failed call stay three different facts.
package enum PastedRegionValueRead: Sendable, Equatable {
  case text(String)
  /// `.noValue` / `.attributeUnsupported`: the element has no text value.
  case absent
  /// The attribute answered with something that is not a string.
  case notText
  case failed(AXError)
}

/// The focused element of a process. `noFocus` is a distinct case name on
/// purpose: a bare `.none` inside an optional context is `Optional.none`.
package enum PastedRegionFocus {
  case element(AXUIElement)
  case noFocus
  case queryFailed(AXError)
}

package enum PastedRegionAXNotification: Sendable, Equatable {
  case valueChanged
  case focusedElementChanged
  case elementDestroyed
}

@MainActor
package protocol PastedRegionAXRegistration: AnyObject {
  func invalidate()
}

/// Every Accessibility operation the observer performs. The production
/// conformer is `LivePastedRegionAXOperations`; tests script answers.
@MainActor
package protocol PastedRegionAXOperations: AnyObject {
  func isTrusted() -> Bool
  func isProcessRunning(_ pid: pid_t) -> Bool
  func applicationElement(pid: pid_t) -> AXUIElement
  func focusedElement(pid: pid_t) -> PastedRegionFocus
  /// Whether the bound was installed; a read behind a failed install is unbounded.
  func setMessagingTimeout(_ element: AXUIElement, seconds: Double) -> Bool
  /// The pid of the active (frontmost) application, nil when none is.
  func frontmostPID() -> pid_t?
  func subrole(of element: AXUIElement) -> SelectionReader.SubroleOutcome
  func supportsManualAccessibility(_ application: AXUIElement) -> Bool
  /// Returns whether the attribute write succeeded.
  func enableManualAccessibility(_ application: AXUIElement) -> Bool
  func readValue(of element: AXUIElement) -> PastedRegionValueRead
  /// Registers value-changed and destroyed on `element`, focused-element-changed
  /// on `application`, with the observer's run-loop source on the MAIN run loop.
  /// Returns nil when the observer could not be created or no notification
  /// registered; the caller keeps polling.
  func register(
    pid: pid_t, element: AXUIElement, application: AXUIElement,
    handler: @escaping @MainActor (PastedRegionAXNotification) -> Void
  ) -> (any PastedRegionAXRegistration)?
}

@MainActor
package protocol PastedRegionScheduledWork: AnyObject {
  func cancel()
}

/// One-shot main-actor timers. Production uses a `Task` sleeping on the
/// continuous clock; tests advance a fake by hand.
@MainActor
package protocol PastedRegionScheduling: AnyObject {
  /// Monotonic milliseconds from an arbitrary epoch; the paste deadline is
  /// expressed in this clock so the ceiling counts from the PASTE, not from
  /// whenever capture happened to run.
  var nowMs: Int { get }
  func schedule(afterMs: Int, _ action: @escaping @MainActor () -> Void)
    -> any PastedRegionScheduledWork
}

// MARK: - Pure text geometry

/// UTF-16 arithmetic over the field value: locate the pasted text, cut anchors,
/// re-find the region between them. No Accessibility, no state.
package enum PastedRegionLocator {

  package enum Location: Equatable {
    /// UTF-16 offsets `[start, end)` of the single occurrence.
    case unique(start: Int, end: Int)
    case absent
    case ambiguous
  }

  package enum Region: Equatable {
    case region(String)
    /// An anchor is gone (or a non-empty pasted text has no anchors left to
    /// find): the region can no longer be located.
    case lost
    /// An anchor occurs more than once; the region is not uniquely defined.
    case ambiguous
  }

  /// Where `pasted` occurs in `value`, as UTF-16 offsets. Empty pasted text is
  /// `absent`: nothing to observe.
  package static func locate(pasted: String, in value: String) -> Location {
    guard !pasted.isEmpty else { return .absent }
    let haystack = Array(value.utf16)
    let needle = Array(pasted.utf16)
    let hits = occurrences(of: needle, in: haystack, limit: 2)
    switch hits.count {
    case 0: return .absent
    case 1: return .unique(start: hits[0], end: hits[0] + needle.count)
    default: return .ambiguous
    }
  }

  /// Anchors around `[start, end)`, at most `anchorUTF16` units each, shortened
  /// so neither cuts a surrogate pair.
  package static func anchors(
    around start: Int, end: Int, in value: String, width: Int = PastedRegionTiming.anchorUTF16
  ) -> PastedRegionAnchors {
    let units = Array(value.utf16)
    var beforeStart = max(0, start - width)
    if beforeStart > 0, beforeStart < units.count, UTF16.isTrailSurrogate(units[beforeStart]) {
      beforeStart += 1
    }
    var afterEnd = min(units.count, end + width)
    if afterEnd < units.count, afterEnd > 0, UTF16.isTrailSurrogate(units[afterEnd]) {
      afterEnd -= 1
    }
    let before = String(decoding: units[beforeStart..<min(start, units.count)], as: UTF16.self)
    let after = String(decoding: units[min(end, afterEnd)..<afterEnd], as: UTF16.self)
    return PastedRegionAnchors(before: before, after: after)
  }

  /// The text between the anchors in the current value. An empty `before`
  /// means the region starts at the beginning of the field, an empty `after`
  /// that it runs to the end (that is what capture produced when the paste sat
  /// at an edge). Both empty means the pasted text WAS the whole field, and the
  /// whole field is the region.
  package static func region(in value: String, anchors: PastedRegionAnchors) -> Region {
    let units = Array(value.utf16)
    let before = Array(anchors.before.utf16)
    let after = Array(anchors.after.utf16)
    var start = 0
    var end = units.count
    if !before.isEmpty {
      let hits = occurrences(of: before, in: units, limit: 2)
      guard hits.count == 1 else { return hits.isEmpty ? .lost : .ambiguous }
      start = hits[0] + before.count
    }
    if !after.isEmpty {
      // Search only past the start anchor, so an `after` that also appears
      // before the region is not a false ambiguity.
      let tail = Array(units[start...])
      let hits = occurrences(of: after, in: tail, limit: 2)
      guard hits.count == 1 else { return hits.isEmpty ? .lost : .ambiguous }
      end = start + hits[0]
    }
    guard start <= end else { return .lost }
    return .region(String(decoding: units[start..<end], as: UTF16.self))
  }

  package enum EditDistanceVerdict: Equatable {
    case within
    case exceeded
    /// The exact decision would cost more than `editDistanceCellBudget`.
    case inconclusive
  }

  /// Whether `region` has drifted further than `limitFraction` of the pasted
  /// length from `pasted`, in UTF-16 edit distance. The length difference is an
  /// exact lower bound and answers most rewrites alone; otherwise the banded
  /// distance decides, or the answer is `inconclusive` when its cell count
  /// would exceed the budget. An inconclusive answer is never "within".
  package static func editDistance(
    pasted: String, region: String,
    limitFraction: Double = PastedRegionTiming.editDistanceLimitFraction,
    limitFloor: Int = PastedRegionTiming.editDistanceLimitFloor,
    cellBudget: Int = PastedRegionTiming.editDistanceCellBudget
  ) -> EditDistanceVerdict {
    let a = Array(pasted.utf16)
    let b = Array(region.utf16)
    let limit = max(Int((Double(a.count) * limitFraction).rounded(.down)), limitFloor)
    if abs(a.count - b.count) > limit { return .exceeded }
    if a == b { return .within }
    guard a.count * (2 * limit + 1) <= cellBudget else { return .inconclusive }
    return bandedDistanceExceeds(a, b, limit: limit) ? .exceeded : .within
  }

  /// Ukkonen-banded Levenshtein: true as soon as the distance provably exceeds
  /// `limit`. Cost is O(min(m, n) × limit).
  static func bandedDistanceExceeds(_ a: [UInt16], _ b: [UInt16], limit: Int) -> Bool {
    if a == b { return false }
    if limit <= 0 { return true }
    let m = a.count
    let n = b.count
    guard m > 0 else { return n > limit }
    let inf = limit + 1
    var previous = [Int](repeating: inf, count: n + 1)
    var current = [Int](repeating: inf, count: n + 1)
    for j in 0...min(n, limit) { previous[j] = j }
    for i in 1...m {
      let lo = max(1, i - limit)
      let hi = min(n, i + limit)
      for j in 0...n { current[j] = inf }
      if i - limit <= 0 { current[0] = i }
      var rowMin = inf
      if lo <= hi {
        for j in lo...hi {
          let cost = a[i - 1] == b[j - 1] ? 0 : 1
          let value = min(previous[j - 1] + cost, previous[j] + 1, current[j - 1] + 1)
          current[j] = value
          rowMin = min(rowMin, value)
        }
      } else {
        rowMin = current[0]
      }
      if rowMin > limit { return true }
      swap(&previous, &current)
    }
    return previous[n] > limit
  }

  /// Start offsets of `needle` in `haystack`, stopping after `limit` hits.
  static func occurrences(of needle: [UInt16], in haystack: [UInt16], limit: Int) -> [Int] {
    guard !needle.isEmpty, needle.count <= haystack.count else { return [] }
    var hits: [Int] = []
    var i = 0
    let last = haystack.count - needle.count
    while i <= last, hits.count < limit {
      if haystack[i] == needle[0] {
        var k = 1
        while k < needle.count, haystack[i + k] == needle[k] { k += 1 }
        if k == needle.count { hits.append(i) }
      }
      i += 1
    }
    return hits
  }
}

// MARK: - Observer

@MainActor
package final class PastedRegionObserver: PastedRegionObserving {

  private let ax: any PastedRegionAXOperations
  private let scheduler: any PastedRegionScheduling

  /// Processes whose `AXManualAccessibility` has been switched on by this
  /// observer. Once per observed process lifetime: a pid is dropped when a
  /// watch on it ends with `appTerminated`.
  private var manualAccessibilityEnabled: Set<pid_t> = []

  private struct Watch {
    let target: PastedRegionTarget
    let generation: UInt64
    let onEvent: @MainActor (PastedRegionEvent) -> Void
    var registration: (any PastedRegionAXRegistration)?
    var registrationFailed = false
    var poll: (any PastedRegionScheduledWork)?
    var settle: (any PastedRegionScheduledWork)?
    var ceiling: (any PastedRegionScheduledWork)?
    var lastRegion: String
    var changedSinceSettled = false
    /// Bumped on every reported change; a settle timer settles only the
    /// revision it was armed for.
    var changeRevision: UInt64 = 0
    var consecutiveReadFailures = 0
  }

  private var watch: Watch?
  private var generation: UInt64 = 0

  package init(ax: any PastedRegionAXOperations, scheduler: any PastedRegionScheduling) {
    self.ax = ax
    self.scheduler = scheduler
  }

  package var isObserving: Bool { watch != nil }

  /// Whether `pid` has had `AXManualAccessibility` enabled by this observer.
  /// Test seam for the once-per-process rule.
  package func hasEnabledManualAccessibility(for pid: pid_t) -> Bool {
    manualAccessibilityEnabled.contains(pid)
  }

  // MARK: Capture (§3.1 step 2)

  package func capture(pid: pid_t, pastedText: String, pastedAtMs: Int)
    -> PastedRegionCaptureOutcome
  {
    guard ax.isTrusted() else { return .ended(.permissionLost) }
    guard pid > 0, ax.isProcessRunning(pid) else { return .ended(.appTerminated) }
    // A process-local focused element survives an app switch, so the ACTIVE
    // application is checked separately, here and on every observation.
    guard ax.frontmostPID() == pid else { return .skipped(.destinationMismatch) }
    let application = ax.applicationElement(pid: pid)
    // A read behind a failed bound is unbounded: refuse rather than hang.
    guard ax.setMessagingTimeout(application, seconds: PasteService.axMessagingTimeoutSeconds)
    else { return .ended(.captureUnsupported) }

    // Electron/Chromium hosts expose nothing until asked, INCLUDING the focused
    // element: asked after the focus query, the opt-in would never run for a
    // host that answers `.noFocus` until it is on (cloud review of PR #3054).
    // Once per process.
    let isManualHost = ax.supportsManualAccessibility(application)
    if isManualHost, !manualAccessibilityEnabled.contains(pid) {
      if ax.enableManualAccessibility(application) { manualAccessibilityEnabled.insert(pid) }
    }

    let element: AXUIElement
    switch ax.focusedElement(pid: pid) {
    case .element(let focused): element = focused
    case .noFocus: return .skipped(.noFocusedElement)
    case .queryFailed(let error): return .ended(Self.endReason(forQueryFailure: error))
    }
    // A descendant does not inherit the application's timeout (#1332).
    guard ax.setMessagingTimeout(element, seconds: PasteService.axMessagingTimeoutSeconds)
    else { return .ended(.captureUnsupported) }

    // Secure fields are never observed. `unreadable` is secure (fail closed).
    if SelectionReader.isSecureField(ax.subrole(of: element)) { return .skipped(.secureField) }

    switch ax.readValue(of: element) {
    case .text(let value):
      guard value.utf16.count <= PastedRegionTiming.maxValueUTF16 else {
        return .ended(.captureUnsupported)
      }
      switch PastedRegionLocator.locate(pasted: pastedText, in: value) {
      case .absent: return .ended(.dictatedTextNotFound)
      case .ambiguous: return .ended(.anchorAmbiguous)
      case .unique(let start, let end):
        let anchors = PastedRegionLocator.anchors(around: start, end: end, in: value)
        return .captured(
          PastedRegionTarget(
            pid: pid, application: application, element: element, pastedText: pastedText,
            anchors: anchors, isManualAccessibilityHost: isManualHost, pastedAtMs: pastedAtMs))
      }
    case .absent, .notText:
      return .ended(.captureUnsupported)
    case .failed(let error):
      return .ended(Self.endReason(forQueryFailure: error))
    }
  }

  /// A failed Accessibility call at capture or during a watch. Only the codes
  /// that name a lost permission are `permissionLost`; everything else is the
  /// destination not answering, which is `captureUnsupported`.
  static func endReason(forQueryFailure error: AXError) -> PastedRegionEndReason {
    switch error {
    case .apiDisabled, .notImplemented: return .permissionLost
    default: return .captureUnsupported
    }
  }

  // MARK: Observe (§3.1 steps 3–4)

  package func start(
    _ target: PastedRegionTarget, onEvent: @escaping @MainActor (PastedRegionEvent) -> Void
  ) {
    stop()
    generation &+= 1
    let gen = generation
    var w = Watch(
      target: target, generation: gen, onEvent: onEvent, lastRegion: target.pastedText)
    // The ceiling is measured from the PASTE. Capture and start may run later;
    // that time is not added, and an already-expired deadline ends at once,
    // before anything is registered.
    let remaining = target.pastedAtMs + PastedRegionTiming.ceilingMs - scheduler.nowMs
    guard remaining > 0 else {
      watch = w
      end(.ceilingElapsed)
      return
    }
    w.registration = ax.register(
      pid: target.pid, element: target.element, application: target.application
    ) { [weak self] notification in
      self?.handle(notification, generation: gen)
    }
    w.registrationFailed = w.registration == nil
    watch = w
    schedulePoll(generation: gen)
    watch?.ceiling = scheduler.schedule(afterMs: remaining) { [weak self] in
      guard let self, self.watch?.generation == gen else { return }
      self.end(.ceilingElapsed)
    }
  }

  package func stop() {
    guard let w = watch else { return }
    // Invalidate BEFORE clearing, so a callback that fires synchronously during
    // invalidation finds no watch.
    watch = nil
    generation &+= 1
    w.registration?.invalidate()
    w.poll?.cancel()
    w.settle?.cancel()
    w.ceiling?.cancel()
  }

  /// Whether the `AXObserver` could be registered for the current watch. False
  /// means the poll is the only source of changes. Test and diagnostics seam.
  package var isPollOnly: Bool { watch?.registrationFailed ?? false }

  // MARK: Timing state
  //
  // Every timer and callback below is a WAKE-UP, never the proof of anything.
  // The transition table, which the tests enumerate row by row:
  //
  //   event              | precondition                  | effect
  //   -------------------|-------------------------------|------------------------------------------
  //   any callback       | deadline passed               | end(ceilingElapsed) once; nothing else runs
  //   any callback       | stale generation/revision     | dropped
  //   read ok, changed   |                               | lastRegion, revision+1, unsettled=true,
  //                      |                               | emit changed (deadline rechecked after AX),
  //                      |                               | settle re-armed (fresh 1500 ms)
  //   read ok, unchanged | unsettled && no settle armed  | settle armed (fresh 1500 ms): a quiet
  //                      |                               | interval starts only from a GOOD read
  //   read ok, unchanged | otherwise                     | nothing
  //   read failed        |                               | failures+1, pending settle CANCELLED
  //                      |                               | (a failed read is not quiet time);
  //                      |                               | third in a row → end(captureUnsupported)
  //   settle fires       | revision current, unsettled   | one more full observation; settled only
  //                      |                               | on unchanged with revision still current
  //   ceiling fires      |                               | end(ceilingElapsed)
  //   stop()             |                               | idempotent; timers cancelled, registration
  //                      |                               | invalidated, generation bumped
  //   client callback    | called stop() inside          | generation recheck: nothing armed after

  private func handle(_ notification: PastedRegionAXNotification, generation gen: UInt64) {
    guard let w = watch, w.generation == gen else { return }
    // "Any callback, deadline passed → ceilingElapsed" beats every other reason.
    if endIfPastDeadline(generation: gen) { return }
    switch notification {
    case .elementDestroyed: end(.elementDestroyed)
    case .focusedElementChanged: evaluate(generation: gen, checkIdentity: true)
    case .valueChanged: evaluate(generation: gen, checkIdentity: true)
    }
  }

  private func schedulePoll(generation gen: UInt64) {
    guard watch?.generation == gen else { return }
    watch?.poll = scheduler.schedule(afterMs: PastedRegionTiming.pollMs) { [weak self] in
      guard let self, self.watch?.generation == gen else { return }
      self.evaluate(generation: gen, checkIdentity: true)
      self.schedulePoll(generation: gen)
    }
  }

  private enum Observation {
    case unchanged
    case changed
    /// The read did not produce a value; nothing about quiet time is known.
    case failed
    case ended
  }

  /// The paste-derived absolute deadline. Checked at every callback entry and
  /// again before any emission that follows an Accessibility call, because a
  /// delayed main actor (or a Mac waking up) can run an overdue poll or settle
  /// before the queued ceiling callback.
  private func deadlinePassed(_ w: Watch) -> Bool {
    scheduler.nowMs >= w.target.pastedAtMs + PastedRegionTiming.ceilingMs
  }

  /// Ends with `ceilingElapsed` when the deadline has passed. Returns true when
  /// the watch was ended (or is already gone).
  private func endIfPastDeadline(generation gen: UInt64) -> Bool {
    guard let w = watch, w.generation == gen else { return true }
    guard deadlinePassed(w) else { return false }
    end(.ceilingElapsed)
    return true
  }

  /// One observation: deadline, permission, process, the active application,
  /// the focused element, then the value, then the region. Every path here
  /// re-validates the destination; value-changed notifications included,
  /// because an inactive application keeps its focused element.
  @discardableResult
  private func evaluate(generation gen: UInt64, checkIdentity: Bool) -> Observation {
    guard let w = watch, w.generation == gen else { return .ended }
    if endIfPastDeadline(generation: gen) { return .ended }
    let target = w.target
    guard ax.isTrusted() else {
      end(.permissionLost)
      return .ended
    }
    guard ax.isProcessRunning(target.pid) else {
      manualAccessibilityEnabled.remove(target.pid)
      end(.appTerminated)
      return .ended
    }
    if checkIdentity {
      guard ax.frontmostPID() == target.pid else {
        end(.focusChanged)
        return .ended
      }
      switch ax.focusedElement(pid: target.pid) {
      case .element(let focused):
        guard CFEqual(focused, target.element) else {
          end(.focusChanged)
          return .ended
        }
      case .noFocus:
        end(.focusChanged)
        return .ended
      case .queryFailed(let error):
        return recordReadFailure(error: error, generation: gen)
      }
    }
    switch ax.readValue(of: target.element) {
    case .failed(let error):
      return recordReadFailure(error: error, generation: gen)
    case .absent, .notText:
      return recordReadFailure(error: nil, generation: gen)
    case .text(let value):
      watch?.consecutiveReadFailures = 0
      guard value.utf16.count <= PastedRegionTiming.maxValueUTF16 else {
        end(.captureUnsupported)
        return .ended
      }
      if value.isEmpty {
        end(.textboxEmptied)
        return .ended
      }
      switch PastedRegionLocator.region(in: value, anchors: target.anchors) {
      case .lost:
        end(.regionRemoved)
        return .ended
      case .ambiguous:
        end(.anchorAmbiguous)
        return .ended
      case .region(let region):
        if region.isEmpty {
          end(.regionRemoved)
          return .ended
        }
        // The AX read took time; the deadline may have passed meanwhile.
        if endIfPastDeadline(generation: gen) { return .ended }
        guard region != w.lastRegion else {
          // A GOOD unchanged read after a cancelled settle restarts the quiet
          // interval, so an edit is never stranded until the ceiling.
          if w.changedSinceSettled, watch?.settle == nil {
            armSettle(generation: gen, revision: w.changeRevision)
          }
          return .unchanged
        }
        switch PastedRegionLocator.editDistance(pasted: target.pastedText, region: region) {
        case .exceeded:
          end(.editDistanceExceeded)
          return .ended
        case .inconclusive:
          end(.captureUnsupported)
          return .ended
        case .within:
          break
        }
        // The distance computation is bounded but not free; the deadline is
        // checked once more immediately before the state change and emission.
        if endIfPastDeadline(generation: gen) { return .ended }
        watch?.lastRegion = region
        watch?.changedSinceSettled = true
        watch?.changeRevision &+= 1
        let revision = watch?.changeRevision ?? 0
        w.onEvent(.changed(region: region))
        // The client may have called `stop()` from inside the callback.
        guard watch?.generation == gen else { return .ended }
        armSettle(generation: gen, revision: revision)
        return .changed
      }
    }
  }

  /// Transient failures are counted; the policy ends the watch after
  /// `maxConsecutiveReadFailures`. A permission code ends it at once. A failed
  /// read is never "unchanged": it cancels the pending quiet interval, which a
  /// later good read restarts.
  private func recordReadFailure(error: AXError?, generation gen: UInt64) -> Observation {
    guard watch?.generation == gen else { return .ended }
    if let error, Self.endReason(forQueryFailure: error) == .permissionLost {
      end(.permissionLost)
      return .ended
    }
    watch?.settle?.cancel()
    watch?.settle = nil
    watch?.consecutiveReadFailures += 1
    if (watch?.consecutiveReadFailures ?? 0) >= PastedRegionTiming.maxConsecutiveReadFailures {
      end(.captureUnsupported)
      return .ended
    }
    return .failed
  }

  /// Settling is a fresh observation, not a memory: the timer re-validates
  /// the deadline, permission, process, active application, focused element
  /// and the value, and settles only when that read still equals the text it
  /// was armed for. A newer change re-arms with a newer revision, so an
  /// obsolete timer that still fires settles nothing.
  private func armSettle(generation gen: UInt64, revision: UInt64) {
    watch?.settle?.cancel()
    watch?.settle = scheduler.schedule(afterMs: PastedRegionTiming.settleMs) { [weak self] in
      guard let self, let w = self.watch, w.generation == gen, w.changeRevision == revision,
        w.changedSinceSettled
      else { return }
      // This timer has fired; a fresh interval must be armed explicitly.
      self.watch?.settle = nil
      guard self.evaluate(generation: gen, checkIdentity: true) == .unchanged,
        let fresh = self.watch, fresh.generation == gen, fresh.changeRevision == revision,
        fresh.changedSinceSettled
      else { return }
      if self.endIfPastDeadline(generation: gen) { return }
      self.watch?.changedSinceSettled = false
      self.watch?.settle?.cancel()
      self.watch?.settle = nil
      fresh.onEvent(.settled(region: fresh.lastRegion))
    }
  }

  private func end(_ reason: PastedRegionEndReason) {
    guard let w = watch else { return }
    stop()
    w.onEvent(.ended(reason))
  }
}

// MARK: - Production seams

/// `Task`-backed one-shot timers on the main actor.
@MainActor
package final class TaskPastedRegionScheduler: PastedRegionScheduling {
  package init() {}

  @MainActor private final class Work: PastedRegionScheduledWork {
    var task: Task<Void, Never>?
    func cancel() { task?.cancel() }
  }

  private let epoch = ContinuousClock.now

  package var nowMs: Int {
    let elapsed = ContinuousClock.now - epoch
    return Int(elapsed.components.seconds) * 1000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
  }

  package func schedule(afterMs: Int, _ action: @escaping @MainActor () -> Void)
    -> any PastedRegionScheduledWork
  {
    let work = Work()
    work.task = Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(afterMs))
      guard !Task.isCancelled else { return }
      action()
    }
    return work
  }
}

/// The real Accessibility calls. Every read is bounded by the messaging timeout
/// the caller set on the handle; nothing here mutates the destination except
/// the documented Electron opt-in.
@MainActor
package final class LivePastedRegionAXOperations: PastedRegionAXOperations {
  package init() {}

  package func isTrusted() -> Bool { AXIsProcessTrusted() }

  package func isProcessRunning(_ pid: pid_t) -> Bool {
    // `kill(pid, 0)` answers "does this pid exist and may I signal it" without
    // sending anything. ESRCH is the only "gone" answer; EPERM is alive.
    guard pid > 0 else { return false }
    if kill(pid, 0) == 0 { return true }
    // -1 with EPERM is a live process we may not signal; ESRCH is gone.
    return errno == EPERM
  }

  package func applicationElement(pid: pid_t) -> AXUIElement {
    AXUIElementCreateApplication(pid)
  }

  package func focusedElement(pid: pid_t) -> PastedRegionFocus {
    switch PasteService.focusedElement(pid: pid) {
    case .element(let element): return .element(element)
    case .none: return .noFocus
    case .queryFailed(let error): return .queryFailed(error)
    }
  }

  package func setMessagingTimeout(_ element: AXUIElement, seconds: Double) -> Bool {
    AXUIElementSetMessagingTimeout(element, Float(seconds)) == .success
  }

  package func frontmostPID() -> pid_t? {
    NSWorkspace.shared.frontmostApplication?.processIdentifier
  }

  package func subrole(of element: AXUIElement) -> SelectionReader.SubroleOutcome {
    var ref: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &ref)
    return SelectionReader.resolveSubrole(error: error, value: ref)
  }

  static let manualAccessibilityAttribute = "AXManualAccessibility" as CFString

  package func supportsManualAccessibility(_ application: AXUIElement) -> Bool {
    var names: CFArray?
    guard AXUIElementCopyAttributeNames(application, &names) == .success,
      let list = names as? [String]
    else { return false }
    return list.contains(Self.manualAccessibilityAttribute as String)
  }

  package func enableManualAccessibility(_ application: AXUIElement) -> Bool {
    AXUIElementSetAttributeValue(
      application, Self.manualAccessibilityAttribute, kCFBooleanTrue) == .success
  }

  package func readValue(of element: AXUIElement) -> PastedRegionValueRead {
    var ref: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref)
    switch error {
    case .success:
      guard let value = ref else { return .absent }
      guard CFGetTypeID(value) == CFStringGetTypeID(), let text = value as? String else {
        return .notText
      }
      return .text(text)
    case .noValue, .attributeUnsupported:
      return .absent
    default:
      return .failed(error)
    }
  }

  /// One `AXObserver` per watch. The C callback receives the registration as
  /// its refcon and hops to the main actor; the run-loop source is added to
  /// the MAIN run loop, so callbacks arrive on the main thread.
  package func register(
    pid: pid_t, element: AXUIElement, application: AXUIElement,
    handler: @escaping @MainActor (PastedRegionAXNotification) -> Void
  ) -> (any PastedRegionAXRegistration)? {
    Registration.make(pid: pid, element: element, application: application, handler: handler)
  }

  @MainActor
  final class Registration: PastedRegionAXRegistration {
    private let observer: AXObserver
    private let element: AXUIElement
    private let application: AXUIElement
    private var handler: (@MainActor (PastedRegionAXNotification) -> Void)?
    private var registered: [(AXUIElement, CFString)] = []
    private var sourceAdded = false

    private init(observer: AXObserver, element: AXUIElement, application: AXUIElement) {
      self.observer = observer
      self.element = element
      self.application = application
    }

    static func make(
      pid: pid_t, element: AXUIElement, application: AXUIElement,
      handler: @escaping @MainActor (PastedRegionAXNotification) -> Void
    ) -> Registration? {
      var observerRef: AXObserver?
      let created = AXObserverCreate(pid, Registration.callback, &observerRef)
      guard created == .success, let observer = observerRef else { return nil }
      let registration = Registration(
        observer: observer, element: element, application: application)
      registration.handler = handler
      let refcon = Unmanaged.passUnretained(registration).toOpaque()
      let wanted: [(AXUIElement, CFString)] = [
        (element, kAXValueChangedNotification as CFString),
        (element, kAXUIElementDestroyedNotification as CFString),
        (application, kAXFocusedUIElementChangedNotification as CFString),
      ]
      for (target, name) in wanted
      where AXObserverAddNotification(observer, target, name, refcon) == .success {
        registration.registered.append((target, name))
      }
      guard !registration.registered.isEmpty else { return nil }
      CFRunLoopAddSource(
        CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), CFRunLoopMode.defaultMode)
      registration.sourceAdded = true
      return registration
    }

    private static let callback: AXObserverCallback = { _, _, notification, refcon in
      guard let refcon else { return }
      let name = notification as String
      let kind: PastedRegionAXNotification
      switch name {
      case kAXValueChangedNotification as String: kind = .valueChanged
      case kAXUIElementDestroyedNotification as String: kind = .elementDestroyed
      case kAXFocusedUIElementChangedNotification as String: kind = .focusedElementChanged
      default: return
      }
      // The source lives on the main run loop, so this is the main thread. The
      // pointer is handed across the isolation boundary once, here, and read
      // only inside the main-actor block (`extract-before-assumeisolated`).
      nonisolated(unsafe) let opaque = refcon
      MainActor.assumeIsolated {
        let registration = Unmanaged<Registration>.fromOpaque(opaque).takeUnretainedValue()
        registration.handler?(kind)
      }
    }

    func invalidate() {
      handler = nil
      for (target, name) in registered {
        AXObserverRemoveNotification(observer, target, name)
      }
      registered.removeAll()
      if sourceAdded {
        CFRunLoopRemoveSource(
          CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), CFRunLoopMode.defaultMode)
        sourceAdded = false
      }
    }
  }
}
