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

  /// #996 (Wispr Flow parity, baseline 2026-09-20): whether an edit that was
  /// seen but had not yet sat quiet for `settleMs` is FLUSHED as one last
  /// `.settled` before this end. The flushed region is always the last GOOD
  /// read: bounded, located, inside the edit-distance limit. What differs per
  /// reason is whether the field is still telling us anything:
  /// - true for the ends a person causes by moving on from a fix they just
  ///   typed: the box emptied because the message was sent (Flow's dominant
  ///   stop reason, 79% of its rows), focus moved, the field went away, the
  ///   app quit, the ceiling ran out; and for the ends where the CURRENT read
  ///   no longer resembles the paste (region gone, anchors doubled, distance
  ///   exceeded). A chat composer that was just sent reads as its placeholder
  ///   text, not as empty (Discord, app matrix 2026-09-20), so a send can
  ///   arrive as `regionRemoved` or `editDistanceExceeded` as well as
  ///   `textboxEmptied`; the fix typed a moment before is the same fix.
  /// - false when the field could not be read at all (`captureUnsupported`
  ///   after repeated failures, `permissionLost`): the host is wedged or the
  ///   permission is gone, and nothing about it should be acted on. ONE
  ///   exception, decided by the observer rather than by the reason: a box
  ///   that stopped answering AFTER a good read saw the fix is a send that
  ///   arrived as three failed reads (WhatsApp 2026-09-21: fix typed, Return
  ///   pressed, the old composer element answered nothing three times; the
  ///   fix was seen and then dropped). The observer flushes that last good
  ///   read through `end(_:lostBoxFlush:)` when every failure in the run was
  ///   a read of the box itself (not `unstable`, not a failed focus query)
  ///   and the fix is at least `flushMinQuietMs` old, the partial-word guard.
  /// `nextDictationStarted` is a send-shaped end the WATCHER asks for
  /// (`finish(_:)`): Wispr Flow's second stop signal after the emptied box;
  /// a fix typed before the next recording is the same fix (Codex r30).
  /// `settled` and `dictatedTextNotFound` are not observer ends (see above).
  /// A young pending edit is withheld only when FOCUS moved: that is the
  /// measured partial-word path (a poll catches "S" mid-word and an app
  /// switch follows at once). The age is measured from the READ that saw the
  /// change, not from the keystroke, so on a poll-backed host a send 900 ms
  /// after the fix can look 150 ms old; send-shaped ends (emptied, removed,
  /// replaced, destroyed, quit, ceiling) therefore flush the last good read
  /// at any age (Codex round 6).
  package var minimumPendingEditAgeMs: Int {
    self == .focusChanged ? PastedRegionTiming.flushMinQuietMs : 0
  }

  package var flushesPendingEdit: Bool {
    switch self {
    case .textboxEmptied, .focusChanged, .elementDestroyed, .appTerminated, .regionRemoved,
      .anchorAmbiguous, .editDistanceExceeded, .ceilingElapsed, .nextDictationStarted:
      return true
    case .settled, .dictatedTextNotFound, .captureUnsupported, .permissionLost:
      return false
    }
  }
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
  /// The least a pending edit must have sat, as READ, before a `focusChanged`
  /// end may flush it (`PastedRegionEndReason.minimumPendingEditAgeMs`). A
  /// poll that lands MID-WORD followed at once by a focus change (VS Code's
  /// suggest popup while typing "Saurabh": the flushed region read "S", app
  /// matrix 2026-09-20; the popup itself is now tolerated by `focusGraceMs`,
  /// an app switch is not) is younger than this; a person leaving the field
  /// after finishing a word is not. Send-shaped ends are not gated.
  package static let flushMinQuietMs = 500
  /// How long the focused element may differ from the watched one, inside the
  /// same application, before the watch ends as `focusChanged`. An editor's
  /// autocomplete popup (VS Code's suggest widget, measured 2026-09-20 while
  /// "Saurabh" was typed) takes accessibility focus after the first letter and
  /// gives it back on the next keystroke; ending there loses every fix typed
  /// in such an editor. The watched element's value stays readable meanwhile,
  /// so observation continues and only a focus that STAYS away ends the
  /// watch. One settle interval: a person who left the field for good has
  /// long stopped editing it by then. A different frontmost application still
  /// ends at once.
  package static let focusGraceMs = 1500
  /// Cursor-aware settling (founder UAT 2026-09-21, Codex r30): a quiet
  /// interval is permission to CHECK whether editing finished, not proof
  /// that it did. When the settle timer fires with the caret still inside or
  /// immediately after the changed span, the interval is re-armed; this is
  /// the absolute bound, measured from the first deferral of a change
  /// revision, after which the latest good region settles regardless. A new
  /// revision starts a new bound; the ceiling below still wins.
  package static let caretCapMs = 10_000
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
  /// The value's own units for the located paste, `[start, end)` as read: the
  /// same text as `pastedText` except where the host renders it differently
  /// (a terminal wraps a long line into rows with a newline and a gutter,
  /// #996 Ghostty follow-up; a contenteditable stores a no-break space). The
  /// observer compares later reads against THIS, so a host's rendering never
  /// counts as an edit; the watcher aligns edits against `pastedText`, whose
  /// whitespace tokenizer sees the two alike.
  package let renderedText: String
  package let anchors: PastedRegionAnchors
  /// Whether the application advertised `AXManualAccessibility` (an
  /// Electron/Chromium host). Telemetry `app_class` evidence for the watcher;
  /// never a bundle id.
  package let isManualAccessibilityHost: Bool
  /// When the paste landed, in the scheduler's clock; the 60 s ceiling is
  /// measured from here.
  package let pastedAtMs: Int
  /// The reader that produced the captured value; every read of the watch
  /// uses the same one (#3073).
  package let reader: PastedRegionTextReader

  package static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.pid == rhs.pid && CFEqual(lhs.application, rhs.application)
      && CFEqual(lhs.element, rhs.element) && lhs.pastedText == rhs.pastedText
      && lhs.renderedText == rhs.renderedText && lhs.anchors == rhs.anchors
      && lhs.isManualAccessibilityHost == rhs.isManualAccessibilityHost
      && lhs.pastedAtMs == rhs.pastedAtMs && lhs.reader == rhs.reader
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
  /// End the watch for a reason the WATCHER knows first (a new dictation),
  /// flushing a pending edit the way the observer's own send-shaped ends do,
  /// then delivering `.ended(reason)`. No-op when nothing is observed.
  func finish(_ reason: PastedRegionEndReason)
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
  /// The text is longer than `PastedRegionTiming.maxValueUTF16`. Produced by
  /// `PastedRegionObserver.readText` only, never by a primitive read: the
  /// range reader refuses before reading, the value reader after.
  case tooLong
  /// The field changed between the calls composing one range snapshot (the
  /// count read after the text differs from the count read before it): a
  /// paste landing late on a slow host, or a keystroke. Retryable; no
  /// partial text is ever accepted (cloud review of PR #3077).
  case unstable
}

/// One read of `AXNumberOfCharacters` (#3073), typed like the value read.
package enum PastedRegionCountRead: Sendable, Equatable {
  case count(Int)
  /// `.noValue` / `.attributeUnsupported`, or an answer that is not a number.
  case absent
  case failed(AXError)
}

/// How an element's text is read (#3073). Chosen once at capture and kept
/// for every read of that watch: a host answering both attributes could
/// render the same text two ways, and a switch mid-watch would read as an
/// edit.
package enum PastedRegionTextReader: String, Sendable, Equatable {
  /// The whole `AXValue`, the first choice.
  case value
  /// `AXStringForRange(0, AXNumberOfCharacters)`, for editors that expose
  /// text only through the parameterized attribute.
  case range
}

/// The focused element of a process. `noFocus` is a distinct case name on
/// purpose: a bare `.none` inside an optional context is `Optional.none`.
package enum PastedRegionFocus {
  case element(AXUIElement)
  case noFocus
  case queryFailed(AXError)
}

/// One read of a window attribute (`AXWindow` of an element, `AXFocusedWindow` of an application),
/// typed so an absent attribute, an answer that is not an element and a failed call stay three
/// different facts (#3106).
package enum PastedRegionWindowRead {
  case window(AXUIElement)
  /// `.noValue` / `.attributeUnsupported`: no window to report.
  case absent
  /// The attribute answered with something that is not an `AXUIElement`.
  case notElement
  /// The call failed, including a stale element (`.invalidUIElement`) and `.cannotComplete`.
  case failed(AXError)
}

/// One read of the selected text range, UTF-16 units relative to the element.
package enum PastedRegionSelectedRange: Sendable, Equatable {
  case range(location: Int, length: Int)
  /// Unreadable, not an AXValue range, or the host refuses: the caller falls
  /// back to quiet-only settling.
  case unavailable
}

package enum PastedRegionAXNotification: Sendable, Hashable, CaseIterable {
  case valueChanged
  case focusedElementChanged
  case elementDestroyed
}

@MainActor
package protocol PastedRegionAXRegistration: AnyObject {
  func invalidate()
  /// The notifications that ACTUALLY registered (#3106). A partial registration is still
  /// returned; a caller that needs every notification compares against what it asked for.
  var registeredNotifications: Set<PastedRegionAXNotification> { get }
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
  /// Nil when the attribute names could not be read: "could not tell" is not "unsupported".
  func supportsManualAccessibility(_ application: AXUIElement) -> Bool?
  /// Returns whether the attribute write succeeded.
  func enableManualAccessibility(_ application: AXUIElement) -> Bool
  func readValue(of element: AXUIElement) -> PastedRegionValueRead
  /// `AXSelectedTextRange` of `element` in UTF-16 units (caret = length 0);
  /// `.unavailable` when the host does not answer with a range. The live
  /// conformer reuses `PasteService.selectedRange`, the one type-checked
  /// reader of that attribute.
  func selectedRange(of element: AXUIElement) -> PastedRegionSelectedRange
  /// `AXNumberOfCharacters`, in UTF-16 units (#3073).
  func characterCount(of element: AXUIElement) -> PastedRegionCountRead
  /// `AXStringForRange` for `length` UTF-16 units from `location` (#3073).
  /// A range past the field's length fails outright rather than clamping
  /// (accessibility-macos.md FACT: reading-caret-context-from-another-app).
  func string(of element: AXUIElement, location: Int, length: Int) -> PastedRegionValueRead
  /// Registers value-changed and destroyed on `element`, focused-element-changed
  /// on `application`, with the observer's run-loop source on the MAIN run loop.
  /// Returns nil when the observer could not be created or no notification
  /// registered; the caller keeps polling.
  func register(
    pid: pid_t, element: AXUIElement, application: AXUIElement,
    handler: @escaping @MainActor (PastedRegionAXNotification) -> Void
  ) -> (any PastedRegionAXRegistration)?

  // MARK: #3106 paste landing check: one AX call per method, on the exact handle given

  /// `AXFocusedUIElement` of THIS application handle, one call. The caller installs the handle's
  /// messaging timeout first; nothing here creates another handle or sets its own bound.
  func focusedElement(ofApplication application: AXUIElement) -> PastedRegionFocus
  /// The process that owns `element`, or nil when it cannot be read.
  func pid(of element: AXUIElement) -> pid_t?
  /// `AXWindow` of `element`, one call.
  func window(of element: AXUIElement) -> PastedRegionWindowRead
  /// `AXFocusedWindow` of `application`, one call.
  func focusedWindow(of application: AXUIElement) -> PastedRegionWindowRead
  /// Registers value-changed and destroyed on `element` (when there is one) and focus-changed on
  /// `application`. `admit` is asked before EACH `AXObserverAddNotification` with the handle that
  /// call messages; a refusal stops registering. Returns nil when the observer could not be
  /// created or nothing registered; otherwise `registeredNotifications` says what did.
  func registerLanding(
    pid: pid_t, element: AXUIElement?, application: AXUIElement,
    admit: @MainActor (AXUIElement) -> Bool,
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

  /// A located region with its absolute UTF-16 offsets in the field, the unit
  /// the caret is reported in.
  package struct Located: Equatable {
    package let text: String
    package let start: Int
    package let end: Int
    package init(text: String, start: Int, end: Int) {
      self.text = text
      self.start = start
      self.end = end
    }
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
  ///
  /// Three host habits are folded away before matching. Two were measured on
  /// the 2026-09-20 app matrix (#996): a contenteditable (Gmail in Chrome,
  /// Slack) stores a pasted trailing space as NO-BREAK SPACE, and some
  /// composers drop the trailing space altogether. Fixed-width space variants
  /// are folded to U+0020 on both sides (a 1:1 fold, so the offsets stay the
  /// value's own), and when the text is absent the needle is retried without
  /// its trailing whitespace. The third is the terminal (Ghostty, measured
  /// 2026-09-21): its `AXTextArea` value is the screen, one row per line, so a
  /// paste longer than the window wraps into `word\n  word` with a gutter,
  /// and the one-line "Saoirse" sentence located while the four-sentence
  /// paragraph read `dictated_text_not_found`. A space in the pasted text
  /// therefore matches ANY run of whitespace in the value (spaces, tabs, line
  /// breaks, folded no-break spaces). A wrap that falls inside a word still
  /// does not match: the pasted text is known exactly, so a break where it
  /// has no space is not the paste. Offsets always describe `value` as read.
  /// A FINAL whitespace run reports `end` before its first line break, so the
  /// located region never crosses from the pasted row into whatever the host
  /// draws on the next one (#3100); an inner run still carries the host's
  /// rendered wrap, and the located slice still carries its own rendering.
  package static func locate(pasted: String, in value: String) -> Location {
    guard !pasted.isEmpty else { return .absent }
    let haystack = value.utf16.map(foldSpace)
    let full = pasted.utf16.map(foldSpace)
    var hits = wrapTolerantOccurrences(of: full, in: haystack, limit: 2)
    if hits.isEmpty {
      let trimmed = Array(full.reversed().drop(while: isSpaceUnit).reversed())
      if !trimmed.isEmpty, trimmed.count < full.count {
        hits = wrapTolerantOccurrences(of: trimmed, in: haystack, limit: 2)
      }
    }
    switch hits.count {
    case 0: return .absent
    case 1: return .unique(start: hits[0].start, end: hits[0].end)
    default: return .ambiguous
    }
  }

  /// `occurrences(of:in:limit:)` where a run of U+0020 in `needle` matches a
  /// run of whitespace units in `haystack` at least as long. Every other unit
  /// must match exactly. Returns `[start, end)` per hit, `end` depending on
  /// the run lengths. A needle that starts with a space is anchored once per
  /// haystack run, at the run's first unit, so one wrapped occurrence is one
  /// hit and not one per unit of the run.
  static func wrapTolerantOccurrences(
    of needle: [UInt16], in haystack: [UInt16], limit: Int
  ) -> [(start: Int, end: Int)] {
    guard !needle.isEmpty, needle.count <= haystack.count else { return [] }
    var hits: [(start: Int, end: Int)] = []
    var i = 0
    while i < haystack.count, hits.count < limit {
      if needle[0] == 0x0020, i > 0, isSpaceUnit(haystack[i - 1]) {
        i += 1
        continue
      }
      if let match = matchWrapTolerant(needle, in: haystack, at: i) {
        hits.append((start: i, end: match.reported))
      }
      i += 1
    }
    return hits
  }

  /// The end offset of a match of `needle` starting at `haystack[start]`, or
  /// nil. A needle space run of length k must meet a haystack whitespace run
  /// of length >= k and then takes the whole run; a needle non-space must
  /// equal the unit.
  ///
  /// `end` is what the match consumed. `reported` is what the REGION ends at,
  /// and it never crosses the line break that closes the region's own row.
  ///
  /// #3100: a dictation carries a trailing space, a terminal reports each row
  /// without its padding, so the needle's trailing space run meets the row's
  /// LINE BREAK and, taking the whole run, carries the region onto the first
  /// glyph of the next row. In an agent CLI the next row is the rule drawn
  /// under the input box, one glyph repeated, and a 64-unit landmark cut from
  /// it matches that rule in several places, so the region can never be
  /// re-found. The FINAL run is therefore reported only as far as its first
  /// line break; the match itself still consumes the whole run, and an inner
  /// run still crosses a wrap, which is what makes a wrapped paste locatable.
  private static func matchWrapTolerant(_ needle: [UInt16], in haystack: [UInt16], at start: Int)
    -> (end: Int, reported: Int)?
  {
    var n = 0
    var h = start
    // Where the run that ends the needle first broke a line, if it did.
    var finalRunBreak: Int?
    while n < needle.count {
      if needle[n] == 0x0020 {
        let needleRunStart = n
        while n < needle.count, needle[n] == 0x0020 { n += 1 }
        guard h < haystack.count, isSpaceUnit(haystack[h]) else { return nil }
        let haystackRunStart = h
        var firstBreak: Int?
        while h < haystack.count, isSpaceUnit(haystack[h]) {
          if firstBreak == nil, isLineBreakUnit(haystack[h]) { firstBreak = h }
          h += 1
        }
        guard h - haystackRunStart >= n - needleRunStart else { return nil }
        finalRunBreak = n == needle.count ? firstBreak : nil
      } else {
        guard h < haystack.count, haystack[h] == needle[n] else { return nil }
        n += 1
        h += 1
        finalRunBreak = nil
      }
    }
    // A needle that is ONLY whitespace can meet a run that begins with the
    // break, which would clamp the region to nothing. The consumed end is
    // right for that one shape, and polish never emits whitespace alone.
    let reported = finalRunBreak ?? h
    return (end: h, reported: reported == start ? h : reported)
  }

  static func isLineBreakUnit(_ unit: UInt16) -> Bool {
    unit == 0x000A || unit == 0x000D
  }

  /// NO-BREAK SPACE, NARROW NO-BREAK SPACE and FIGURE SPACE read as U+0020.
  /// Same width in UTF-16, so a folded index is a real index into the value.
  static func foldSpace(_ unit: UInt16) -> UInt16 {
    switch unit {
    case 0x00A0, 0x202F, 0x2007: return 0x0020
    default: return unit
    }
  }

  static func isSpaceUnit(_ unit: UInt16) -> Bool {
    unit == 0x0020 || unit == 0x0009 || unit == 0x000A || unit == 0x000D
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
    switch locateRegion(in: value, anchors: anchors) {
    case .located(let l): return .region(l.text)
    case .lost: return .lost
    case .ambiguous: return .ambiguous
    }
  }

  package enum LocatedRegion: Equatable {
    case located(Located)
    case lost
    case ambiguous
  }

  /// `region(in:anchors:)` with the offsets retained (Codex r30: the caret
  /// and the changed span must share one unit, the field's UTF-16 offset).
  package static func locateRegion(in value: String, anchors: PastedRegionAnchors) -> LocatedRegion {
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
    return .located(Located(text: String(decoding: units[start..<end], as: UTF16.self), start: start, end: end))
  }

  /// The conservative UTF-16 envelope of everything that changed between the
  /// pasted rendering and the current region, relative to the region: the
  /// span between the longest common prefix and the longest common suffix.
  /// Several separate edits become one wider envelope, which can only make
  /// the watcher wait longer, never settle an actively edited word. An
  /// unchanged region yields an empty envelope at the end.
  package static func changedEnvelope(pasted: String, region: String) -> Range<Int> {
    let a = Array(pasted.utf16), b = Array(region.utf16)
    var prefix = 0
    while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < a.count - prefix, suffix < b.count - prefix,
      a[a.count - 1 - suffix] == b[b.count - 1 - suffix]
    { suffix += 1 }
    // Never start or end inside a surrogate pair: a replacement between two
    // emoji sharing a lead unit would otherwise begin between lead and trail.
    var lower = prefix
    var upper = b.count - suffix
    if lower > 0, lower < b.count, UTF16.isTrailSurrogate(b[lower]) { lower -= 1 }
    if upper > 0, upper < b.count, UTF16.isTrailSurrogate(b[upper]) { upper += 1 }
    return lower..<upper
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

  /// Why an `.ambiguous` answer happened, in COUNTS ONLY.
  ///
  /// #3100: in a terminal the accessibility value is the screen, and the
  /// screen is full of drawn rules and padding that repeat. Nothing here
  /// carries a character of the user's text — the fields are lengths, hit
  /// counts and shape numbers, so the report is safe to log on a real
  /// machine while a real person dictates.
  package struct AmbiguityReport: Equatable, Sendable {
    /// `before`, `after` or `pasted`: which needle was not unique.
    package let side: String
    /// How many times the needle occurs, counted up to `hitCeiling`.
    package let hits: Int
    package let needleUTF16: Int
    package let valueUTF16: Int
    /// Lines in the value: a terminal answers with one row per line.
    package let valueRows: Int
    /// Distinct UTF-16 units in the needle. A drawn box rule has very few.
    package let distinctUnits: Int
    /// Longest run of one repeated unit in the needle.
    package let longestRun: Int

    package init(
      side: String, hits: Int, needleUTF16: Int, valueUTF16: Int, valueRows: Int,
      distinctUnits: Int, longestRun: Int
    ) {
      self.side = side
      self.hits = hits
      self.needleUTF16 = needleUTF16
      self.valueUTF16 = valueUTF16
      self.valueRows = valueRows
      self.distinctUnits = distinctUnits
      self.longestRun = longestRun
    }

    package var logLine: String {
      "side=\(side) hits=\(hits) needle_utf16=\(needleUTF16) value_utf16=\(valueUTF16) "
        + "value_rows=\(valueRows) distinct_units=\(distinctUnits) longest_run=\(longestRun)"
    }
  }

  /// Counting stops here: the question is "more than one", not "how many".
  package static let hitCeiling = 8

  static func shape(of needle: [UInt16]) -> (distinct: Int, longestRun: Int) {
    guard !needle.isEmpty else { return (0, 0) }
    var seen = Set<UInt16>()
    var longest = 1
    var run = 1
    for i in needle.indices {
      seen.insert(needle[i])
      if i > 0, needle[i] == needle[i - 1] {
        run += 1
        longest = max(longest, run)
      } else {
        run = 1
      }
    }
    return (seen.count, longest)
  }

  static func rows(in units: [UInt16]) -> Int {
    units.reduce(1) { $1 == 0x000A ? $0 + 1 : $0 }
  }

  static func report(side: String, needle: [UInt16], hits: Int, value: [UInt16])
    -> AmbiguityReport
  {
    let s = shape(of: needle)
    return AmbiguityReport(
      side: side, hits: hits, needleUTF16: needle.count, valueUTF16: value.count,
      valueRows: rows(in: value), distinctUnits: s.distinct, longestRun: s.longestRun)
  }

  /// The report for an `.ambiguous` answer from `locate(pasted:in:)`.
  package static func ambiguityReport(pasted: String, in value: String) -> AmbiguityReport? {
    let haystack = value.utf16.map(foldSpace)
    let full = pasted.utf16.map(foldSpace)
    var hits = wrapTolerantOccurrences(of: full, in: haystack, limit: hitCeiling)
    var needle = full
    if hits.isEmpty {
      let trimmed = Array(full.reversed().drop(while: isSpaceUnit).reversed())
      if !trimmed.isEmpty, trimmed.count < full.count {
        hits = wrapTolerantOccurrences(of: trimmed, in: haystack, limit: hitCeiling)
        needle = trimmed
      }
    }
    guard hits.count > 1 else { return nil }
    return report(side: "pasted", needle: needle, hits: hits.count, value: haystack)
  }

  /// The report for an `.ambiguous` answer from `locateRegion(in:anchors:)`.
  /// Reports the FIRST side that is not unique, which is the side that ended
  /// the watch.
  package static func ambiguityReport(in value: String, anchors: PastedRegionAnchors)
    -> AmbiguityReport?
  {
    let units = Array(value.utf16)
    let before = Array(anchors.before.utf16)
    let after = Array(anchors.after.utf16)
    var start = 0
    if !before.isEmpty {
      let hits = occurrences(of: before, in: units, limit: hitCeiling)
      guard hits.count == 1 else {
        guard hits.count > 1 else { return nil }
        return report(side: "before", needle: before, hits: hits.count, value: units)
      }
      start = hits[0] + before.count
    }
    if !after.isEmpty {
      let tail = Array(units[start...])
      let hits = occurrences(of: after, in: tail, limit: hitCeiling)
      guard hits.count == 1 else {
        guard hits.count > 1 else { return nil }
        return report(side: "after", needle: after, hits: hits.count, value: units)
      }
    }
    return nil
  }

  /// The report for a `.lost` answer from `locateRegion(in:anchors:)`: which
  /// side vanished, and the shape of the landmark that did. Counts only.
  package static func missingAnchorReport(in value: String, anchors: PastedRegionAnchors)
    -> AmbiguityReport?
  {
    let units = Array(value.utf16)
    let before = Array(anchors.before.utf16)
    let after = Array(anchors.after.utf16)
    var start = 0
    if !before.isEmpty {
      let hits = occurrences(of: before, in: units, limit: hitCeiling)
      if hits.isEmpty { return report(side: "before", needle: before, hits: 0, value: units) }
      guard hits.count == 1 else { return nil }
      start = hits[0] + before.count
    }
    if !after.isEmpty {
      let tail = Array(units[start...])
      let hits = occurrences(of: after, in: tail, limit: hitCeiling)
      if hits.isEmpty { return report(side: "after", needle: after, hits: 0, value: units) }
    }
    return nil
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

  /// #3100 probe: why the region stopped being unique, as counts only.
  /// DEBUG builds only; a Release build logs nothing at all.
  static func logAmbiguity(path: String, _ report: PastedRegionLocator.AmbiguityReport?) {
    #if DEBUG
      let detail = report?.logLine ?? "side=none_found"
      Task {
        await AppLogger.shared.log(
          "anchor_ambiguous_probe path=\(path) \(detail)", level: .info,
          category: "LearnFromEdits")
      }
    #endif
  }

  /// #3100 probe: why a region stopped being findable. `kind` is
  /// `anchor_lost` (a landmark is gone) or `empty_region` (both landmarks are
  /// there and nothing is left between them). Counts only; the pasted text is
  /// read for ONE boolean, never logged.
  static func logRegionRemoved(
    path: String, kind: String, pastedText: String,
    report: PastedRegionLocator.AmbiguityReport? = nil,
    start: Int? = nil, end: Int? = nil, valueUTF16: Int
  ) {
    #if DEBUG
      let trailing = pastedText.utf16.last.map { PastedRegionLocator.isSpaceUnit($0) } ?? false
      var fields = [
        "region_removed_probe", "path=\(path)", "kind=\(kind)",
        "pasted_trailing_whitespace=\(trailing)", "value_utf16=\(valueUTF16)",
      ]
      if let report { fields.append(report.logLine) }
      if let start, let end {
        fields.append("start=\(start)")
        fields.append("end=\(end)")
        fields.append("region_utf16=\(max(0, end - start))")
      }
      let line = fields.joined(separator: " ")
      Task {
        await AppLogger.shared.log(line, level: .info, category: "LearnFromEdits")
      }
    #endif
  }

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
    /// Absolute UTF-16 offsets of `lastRegion` in the field, from the read
    /// that produced it; the caret is compared in the same unit.
    var lastRegionStart = 0
    var lastRegionEnd = 0
    /// UTF-16 length of the complete field value from the same good read that
    /// produced `lastRegionStart` and `lastRegion`; a foreign range past it is
    /// malformed.
    var lastValueUTF16Count = 0
    var changedSinceSettled = false
    /// Absolute deadline of the cursor-aware deferral for the current change
    /// revision (`caretCapMs`); nil until the first deferral, cleared on a
    /// new revision.
    var caretDeadlineMs: Int?
    /// When `lastRegion` was last read as changed, for `flushMinQuietMs`.
    var lastChangeAtMs = 0
    /// When the focused element first differed from the watched one within the
    /// same application; nil while focus is on the element (`focusGraceMs`).
    var focusAwayAtMs: Int?
    /// Bumped on every reported change; a settle timer settles only the
    /// revision it was armed for.
    var changeRevision: UInt64 = 0
    var consecutiveReadFailures = 0
    /// The kinds of the current failure run, for the log line.
    var readFailureKinds: [String] = []
    /// True only while every failure in the current run came from reading
    /// the watched box itself and was stable enough to support a lost-box
    /// flush (`recordReadFailure` owns the classification).
    var failureRunPermitsLostBoxFlush = true
  }

  private var watch: Watch?
  private var generation: UInt64 = 0

  /// Diagnostic lines (never text content): which kind each failed read was
  /// and whether an end flushed a pending fix. nil in tests and when nothing
  /// listens.
  private let log: (@MainActor (String) -> Void)?

  package init(
    ax: any PastedRegionAXOperations, scheduler: any PastedRegionScheduling,
    log: (@MainActor (String) -> Void)? = nil
  ) {
    self.ax = ax
    self.scheduler = scheduler
    self.log = log
  }

  package var isObserving: Bool { watch != nil }

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
    // host that answers `.noFocus` until it is on. Asked on EVERY capture, not
    // once per pid: a pid cache outlives the process it names and macOS reuses
    // pids, so a later Electron process under a remembered number would never
    // be asked; one attribute write per paste is nothing (cloud review of
    // PR #3054, both rounds).
    // An unreadable answer is treated as "not a manual host", exactly as before it could be told
    // apart (#3106): the watcher's behaviour does not change.
    let isManualHost = ax.supportsManualAccessibility(application) ?? false
    if isManualHost { _ = ax.enableManualAccessibility(application) }

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

    // `AXValue` first. An editor that has none, or answers with something
    // that is not a string, may still expose its text through the
    // parameterized range attribute (#3073; Excel in edit mode is the
    // measured candidate). A FAILED value read is the host not answering,
    // not "no value", and is not retried through the other reader.
    var reader = PastedRegionTextReader.value
    var read = readText(of: element, using: reader)
    if read == .absent || read == .notText {
      reader = .range
      read = readText(of: element, using: reader)
    }
    switch read {
    case .text(let value):
      switch PastedRegionLocator.locate(pasted: pastedText, in: value) {
      case .absent: return .ended(.dictatedTextNotFound)
      case .ambiguous:
        #if DEBUG
          Self.logAmbiguity(
            path: "capture", PastedRegionLocator.ambiguityReport(pasted: pastedText, in: value))
        #endif
        return .ended(.anchorAmbiguous)
      case .unique(let start, let end):
        let anchors = PastedRegionLocator.anchors(around: start, end: end, in: value)
        let units = Array(value.utf16)
        let rendered = String(decoding: units[start..<end], as: UTF16.self)
        return .captured(
          PastedRegionTarget(
            pid: pid, application: application, element: element, pastedText: pastedText,
            renderedText: rendered, anchors: anchors, isManualAccessibilityHost: isManualHost,
            pastedAtMs: pastedAtMs, reader: reader))
      }
    case .absent, .notText, .tooLong:
      return .ended(.captureUnsupported)
    case .unstable:
      // The text is not STABLY there yet: the one capture outcome the watcher
      // retries through its capture grace (`deservesCaptureGrace`).
      return .ended(.dictatedTextNotFound)
    case .failed(let error):
      return .ended(Self.endReason(forQueryFailure: error))
    }
  }

  /// The element's complete text through one reader (#3073). The ceiling
  /// `PastedRegionTiming.maxValueUTF16` is applied here for BOTH readers,
  /// the only place it is: the range reader refuses before anything is read
  /// into memory, the value reader can only measure what it was handed.
  ///
  /// Range path, fail closed: a count that is not a number is `absent`; a
  /// string of any other UTF-16 length than the count is `absent` too
  /// (`AXStringForRange(0, n)` is not guaranteed to return n units, and a
  /// truncated snapshot would mis-anchor the region; accessibility-macos.md
  /// FACT: reading-caret-context-from-another-app), and the count is read
  /// again after the text so a field that changed between the calls is
  /// `unstable` (retryable) instead of an exact-length prefix. A count of
  /// zero is the empty text, so `textboxEmptied` survives the range path.
  package func readText(of element: AXUIElement, using reader: PastedRegionTextReader)
    -> PastedRegionValueRead
  {
    // `admit` never refuses here, so the optional is always a read: the learn watcher's reads are
    // bounded by the timeout its capture installed, exactly as before #3106.
    Self.readText(of: element, using: reader, ax: ax, admit: { _ in true }) ?? .absent
  }

  /// The one implementation of both readers. `admit` is asked before EACH Accessibility call with
  /// the handle that call messages (#3106's cumulative preparation budget installs the remaining
  /// timeout there); nil means it refused and the read stopped, which is not an answer about the
  /// field.
  package static func readText(
    of element: AXUIElement, using reader: PastedRegionTextReader,
    ax: any PastedRegionAXOperations, admit: @MainActor (AXUIElement) -> Bool
  ) -> PastedRegionValueRead? {
    switch reader {
    case .value:
      guard admit(element) else { return nil }
      let read = ax.readValue(of: element)
      if case .text(let value) = read, value.utf16.count > PastedRegionTiming.maxValueUTF16 {
        return .tooLong
      }
      return read
    case .range:
      guard admit(element) else { return nil }
      switch ax.characterCount(of: element) {
      case .failed(let error): return .failed(error)
      case .absent: return .absent
      case .count(let count):
        guard count >= 0 else { return .absent }
        guard count <= PastedRegionTiming.maxValueUTF16 else { return .tooLong }
        guard count > 0 else { return .text("") }
        guard admit(element) else { return nil }
        let read = ax.string(of: element, location: 0, length: count)
        if read == .notText { return read }
        // The host can change between the calls: a range read of the OLD
        // count then returns an exact-length PREFIX of the new text, a
        // different length, or fails because the range no longer exists
        // (Codex grounded review r1, cloud review of PR #3077). The count is
        // read again after the text; a different count is one class,
        // `unstable`, and never a verdict on the host. A length mismatch under
        // a STABLE count is the host's own answer disagreeing with its count
        // (measured on other hosts, accessibility-macos.md) and stays `absent`.
        guard admit(element) else { return nil }
        switch ax.characterCount(of: element) {
        case .count(let current) where current > PastedRegionTiming.maxValueUTF16:
          return .tooLong
        case .count(let current) where current != count:
          return .unstable
        case .count:
          if case .text(let value) = read, value.utf16.count != count { return .absent }
          return read
        case .absent:
          return .absent
        case .failed(let error):
          return .failed(error)
        }
      }
    }
  }

  /// The element's whole text the way capture reads it: `AXValue` first, and the range reader only
  /// when the value is absent or not text (a FAILED value read is not retried). Nil when `admit`
  /// refused a call (#3106).
  package static func readWholeText(
    of element: AXUIElement, ax: any PastedRegionAXOperations, admit: @MainActor (AXUIElement) -> Bool
  ) -> PastedRegionValueRead? {
    guard let read = readText(of: element, using: .value, ax: ax, admit: admit) else { return nil }
    guard read == .absent || read == .notText else { return read }
    return readText(of: element, using: .range, ax: ax, admit: admit)
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
      target: target, generation: gen, onEvent: onEvent, lastRegion: target.renderedText)
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
    case .focusedElementChanged: evaluate(generation: gen, checkIdentity: true, source: "focus_notification")
    case .valueChanged: evaluate(generation: gen, checkIdentity: true, source: "value_notification")
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
  /// `source` names what triggered this read, for the `learn_read_changed`
  /// log line that measures which hosts deliver per-keystroke notifications.
  private func evaluate(generation gen: UInt64, checkIdentity: Bool, source: String = "poll") -> Observation {
    guard let w = watch, w.generation == gen else { return .ended }
    if endIfPastDeadline(generation: gen) { return .ended }
    let target = w.target
    guard ax.isTrusted() else {
      end(.permissionLost)
      return .ended
    }
    guard ax.isProcessRunning(target.pid) else {
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
        if CFEqual(focused, target.element) {
          watch?.focusAwayAtMs = nil
        } else if focusAwayTooLong(generation: gen) {
          end(.focusChanged)
          return .ended
        }
      case .noFocus:
        if focusAwayTooLong(generation: gen) {
          end(.focusChanged)
          return .ended
        }
      case .queryFailed(let error):
        // Discovering the focused element failed; the watched box itself was
        // never read, so this says nothing about it (cloud review of #3087).
        return recordReadFailure(
          error: error, kind: "focusQueryFailed(\(error.rawValue))", permitsLostBoxFlush: false,
          generation: gen)
      }
    }
    let read = readText(of: target.element, using: target.reader)
    // The read took time (up to three bounded AX calls on the range path); a
    // deadline that passed meanwhile beats every reason the read could name,
    // including an emptied box or a failed read (second-pass review of
    // #3073; this check used to sit after the region was located, where it
    // could not reach those ends).
    if endIfPastDeadline(generation: gen) { return .ended }
    switch read {
    case .failed(let error):
      return recordReadFailure(
        error: error, kind: "failed(\(error.rawValue))", permitsLostBoxFlush: true, generation: gen)
    case .absent:
      return recordReadFailure(error: nil, kind: "absent", permitsLostBoxFlush: true, generation: gen)
    case .notText:
      return recordReadFailure(error: nil, kind: "notText", permitsLostBoxFlush: true, generation: gen)
    case .unstable:
      // A person mid-keystroke; the next poll reads a settled field. Three in
      // a row are still a host that cannot be read, and never a lost box.
      return recordReadFailure(error: nil, kind: "unstable", permitsLostBoxFlush: false, generation: gen)
    case .tooLong:
      end(.captureUnsupported)
      return .ended
    case .text(let value):
      watch?.consecutiveReadFailures = 0
      watch?.readFailureKinds = []
      watch?.failureRunPermitsLostBoxFlush = true
      if value.isEmpty {
        end(.textboxEmptied)
        return .ended
      }
      switch PastedRegionLocator.locateRegion(in: value, anchors: target.anchors) {
      case .lost:
        #if DEBUG
          Self.logRegionRemoved(
            path: "poll", kind: "anchor_lost", pastedText: target.pastedText,
            report: PastedRegionLocator.missingAnchorReport(in: value, anchors: target.anchors),
            valueUTF16: value.utf16.count)
        #endif
        end(.regionRemoved)
        return .ended
      case .ambiguous:
        #if DEBUG
          Self.logAmbiguity(
            path: "poll",
            PastedRegionLocator.ambiguityReport(in: value, anchors: target.anchors))
        #endif
        end(.anchorAmbiguous)
        return .ended
      case .located(let located):
        let region = located.text
        if region.isEmpty {
          #if DEBUG
            Self.logRegionRemoved(
              path: "poll", kind: "empty_region", pastedText: target.pastedText,
              start: located.start, end: located.end, valueUTF16: value.utf16.count)
          #endif
          end(.regionRemoved)
          return .ended
        }
        guard region != w.lastRegion else {
          // The same text can sit at a new offset (text inserted before the
          // anchor): the coordinates the caret is compared with follow every
          // good read, changed or not (Codex r32).
          watch?.lastRegionStart = located.start
          watch?.lastRegionEnd = located.end
          watch?.lastValueUTF16Count = value.utf16.count
          // A GOOD unchanged read after a cancelled settle restarts the quiet
          // interval, so an edit is never stranded until the ceiling.
          if w.changedSinceSettled, watch?.settle == nil {
            armSettle(generation: gen, revision: w.changeRevision)
          }
          return .unchanged
        }
        switch PastedRegionLocator.editDistance(pasted: target.renderedText, region: region) {
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
        watch?.lastRegionStart = located.start
        watch?.lastRegionEnd = located.end
        watch?.lastValueUTF16Count = value.utf16.count
        watch?.changedSinceSettled = true
        watch?.lastChangeAtMs = scheduler.nowMs
        watch?.changeRevision &+= 1
        watch?.caretDeadlineMs = nil
        let revision = watch?.changeRevision ?? 0
        log?("learn_read_changed source=\(source)")
        w.onEvent(.changed(region: region))
        // The client may have called `stop()` from inside the callback.
        guard watch?.generation == gen else { return .ended }
        armSettle(generation: gen, revision: revision)
        return .changed
      }
    }
  }

  /// Focus is off the watched element inside the same application: the first
  /// such tick starts the grace clock; later ticks compare against it. The
  /// element itself is still read (a popup does not change its value), so a
  /// fix typed through an autocomplete popup is observed normally.
  private func focusAwayTooLong(generation gen: UInt64) -> Bool {
    guard let w = watch, w.generation == gen else { return true }
    let since = w.focusAwayAtMs ?? scheduler.nowMs
    if w.focusAwayAtMs == nil { watch?.focusAwayAtMs = since }
    return scheduler.nowMs - since >= PastedRegionTiming.focusGraceMs
  }

  /// Transient failures are counted; the policy ends the watch after
  /// `maxConsecutiveReadFailures`. A permission code ends it at once. A failed
  /// read is never "unchanged": it cancels the pending quiet interval, which a
  /// later good read restarts.
  /// `permitsLostBoxFlush` is the closed classification of failure sources: a
  /// failed, absent or non-text read OF THE WATCHED BOX is evidence the box
  /// went away; an `unstable` read (a person still typing) and a failed focus
  /// query (the box was never read) are not.
  private func recordReadFailure(
    error: AXError?, kind: String, permitsLostBoxFlush: Bool, generation gen: UInt64
  ) -> Observation {
    guard watch?.generation == gen else { return .ended }
    if let error, Self.endReason(forQueryFailure: error) == .permissionLost {
      end(.permissionLost)
      return .ended
    }
    watch?.settle?.cancel()
    watch?.settle = nil
    watch?.consecutiveReadFailures += 1
    watch?.readFailureKinds.append(kind)
    if !permitsLostBoxFlush { watch?.failureRunPermitsLostBoxFlush = false }
    let failures = watch?.consecutiveReadFailures ?? 0
    log?("learn_read_failed n=\(failures)/\(PastedRegionTiming.maxConsecutiveReadFailures) kind=\(kind) pending_fix=\(watch?.changedSinceSettled ?? false)")
    if failures >= PastedRegionTiming.maxConsecutiveReadFailures {
      // A box that stopped answering right after a good read saw the fix is
      // a send in another shape (see `flushesPendingEdit`).
      end(.captureUnsupported, lostBoxFlush: watch?.failureRunPermitsLostBoxFlush ?? false)
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
      guard self.evaluate(generation: gen, checkIdentity: true, source: "settle") == .unchanged,
        let fresh = self.watch, fresh.generation == gen, fresh.changeRevision == revision,
        fresh.changedSinceSettled
      else { return }
      if self.endIfPastDeadline(generation: gen) { return }
      let trigger = self.settleTrigger(generation: gen)
      // The caret read is another pair of AX calls: the ceiling may have
      // passed meanwhile (Codex r32).
      if self.endIfPastDeadline(generation: gen) { return }
      guard let trigger else {
        // Still editing (caret inside or right after the changed span, or a
        // selection over it): the quiet interval is re-armed, bounded by
        // `caretCapMs` from the first deferral of this revision.
        self.armSettle(generation: gen, revision: revision)
        return
      }
      self.watch?.changedSinceSettled = false
      self.watch?.caretDeadlineMs = nil
      self.watch?.settle?.cancel()
      self.watch?.settle = nil
      self.log?("learn_settle trigger=\(trigger.rawValue)")
      fresh.onEvent(.settled(region: fresh.lastRegion))
    }
  }

  /// Why a quiet interval was allowed to settle; nil means "still editing,
  /// wait". Internal, for tests and the log line; no telemetry (Codex r30).
  package enum SettleTrigger: String, Sendable, Equatable {
    /// The caret (or selection) is outside the changed span.
    case caretLeft
    /// `caretCapMs` elapsed since the first deferral of this revision.
    case cap
    /// The selected range could not be used: unavailable, negative,
    /// overflowing or past the field's last good length. Today's quiet-only
    /// rule. (Focus elsewhere or a failed focus query WAIT instead.)
    case fallbackQuiet
  }

  /// The decision table (Codex r30 §D), evaluated when the quiet interval has
  /// elapsed and the value read unchanged. The focused element is resolved
  /// AGAIN and the range read from that fresh handle: a stored handle can
  /// report a stale zero (accessibility-macos.md). Focus temporarily on
  /// another element of the same app (an autocomplete popup), no focus, or a
  /// failed second focus query all wait; the existing focus grace ends the
  /// watch if focus stays away, and `caretCapMs` bounds every wait.
  private func settleTrigger(generation gen: UInt64) -> SettleTrigger? {
    guard let w = watch, w.generation == gen else { return nil }
    let now = scheduler.nowMs
    if let deadline = w.caretDeadlineMs, now >= deadline { return .cap }
    let stillEditing: Bool
    switch ax.focusedElement(pid: w.target.pid) {
    case .element(let focused) where CFEqual(focused, w.target.element):
      switch ax.selectedRange(of: focused) {
      case .unavailable:
        return .fallbackQuiet
      case .range(let location, let length):
        // A foreign implementation's range: negative, overflowing or past the
        // field's last good length is malformed, never "outside".
        guard location >= 0, length >= 0 else { return .fallbackQuiet }
        let (selectionEnd, overflow) = location.addingReportingOverflow(length)
        guard !overflow, selectionEnd <= w.lastValueUTF16Count else { return .fallbackQuiet }
        let envelope = PastedRegionLocator.changedEnvelope(pasted: w.target.renderedText, region: w.lastRegion)
        let spanStart = w.lastRegionStart + envelope.lowerBound
        let spanEnd = w.lastRegionStart + envelope.upperBound
        if length == 0 {
          // A caret inside the span, or immediately after it (typing appends there).
          stillEditing = location >= spanStart && location <= spanEnd
        } else {
          // A selection that overlaps the span.
          stillEditing = location < spanEnd && selectionEnd > spanStart
        }
      }
    case .element, .noFocus:
      // Focus is elsewhere in the same app for now (a popup): wait; the poll's
      // focus grace decides whether it stays away.
      stillEditing = true
    case .queryFailed:
      // The identity check moments ago succeeded; a failure now is a
      // transient second-sample disagreement, not proof the host lacks a
      // caret. Wait under the same bounded cap (Codex r32).
      stillEditing = true
    }
    guard stillEditing else { return .caretLeft }
    // The AX calls above took time: re-sample before deciding the cap.
    let afterCaretRead = scheduler.nowMs
    if let deadline = w.caretDeadlineMs, afterCaretRead >= deadline { return .cap }
    if w.caretDeadlineMs == nil { watch?.caretDeadlineMs = afterCaretRead + PastedRegionTiming.caretCapMs }
    return nil
  }

  package func finish(_ reason: PastedRegionEndReason) {
    guard let w = watch else { return }
    // One fresh read before the flush: on a poll-only host the cached region
    // can be half a word typed since the last poll (cloud review of #3090).
    // The read may itself end the watch (the box emptied, the region gone);
    // then that end, already delivered, stands and there is nothing to do.
    _ = evaluate(generation: w.generation, checkIdentity: true, source: "finish")
    guard watch != nil else { return }
    end(reason)
  }

  /// A pending edit (changed, not yet settled) is flushed as one `.settled`
  /// before the `.ended` when the reason `flushesPendingEdit` and the edit is
  /// at least `reason.minimumPendingEditAgeMs` old, so a fix typed and sent
  /// inside the quiet interval is still judged while a half-typed word caught
  /// by a poll right before an app switch is not. The watcher keeps answering a burst after `.ended` (it drops
  /// answers only for a cancelled or superseded watch), which is what makes
  /// the flush worth emitting.
  /// `lostBoxFlush` is the observer's own send-shaped verdict for
  /// `captureUnsupported` (three failed reads of the box after a good read
  /// saw the fix); every other reason decides by `flushesPendingEdit` alone.
  /// A lost box is weaker evidence than an emptied one (three failures can
  /// also be a wedged host under a person still typing), so it carries the
  /// same `flushMinQuietMs` floor as a focus change; poll-driven failures
  /// take about 2.25 s, well past it (Codex r28).
  private func end(_ reason: PastedRegionEndReason, lostBoxFlush: Bool = false) {
    guard let w = watch else { return }
    let minimumAgeMs =
      lostBoxFlush ? PastedRegionTiming.flushMinQuietMs : reason.minimumPendingEditAgeMs
    let flush =
      (reason.flushesPendingEdit || lostBoxFlush) && w.changedSinceSettled && !w.lastRegion.isEmpty
      && w.lastRegion != w.target.renderedText
      && scheduler.nowMs - w.lastChangeAtMs >= minimumAgeMs
    stop()
    if lostBoxFlush {
      log?("learn_lost_box reason=\(reason.rawValue) flushed=\(flush) reads=\(w.readFailureKinds.joined(separator: ","))")
    }
    if flush { w.onEvent(.settled(region: w.lastRegion)) }
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

  package func supportsManualAccessibility(_ application: AXUIElement) -> Bool? {
    var names: CFArray?
    guard AXUIElementCopyAttributeNames(application, &names) == .success,
      let list = names as? [String]
    else { return nil }
    return list.contains(Self.manualAccessibilityAttribute as String)
  }

  package func enableManualAccessibility(_ application: AXUIElement) -> Bool {
    AXUIElementSetAttributeValue(
      application, Self.manualAccessibilityAttribute, kCFBooleanTrue) == .success
  }

  package func selectedRange(of element: AXUIElement) -> PastedRegionSelectedRange {
    guard let range = PasteService.selectedRange(of: element) else { return .unavailable }
    return .range(location: range.location, length: range.length)
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

  package func characterCount(of element: AXUIElement) -> PastedRegionCountRead {
    var ref: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(
      element, kAXNumberOfCharactersAttribute as CFString, &ref)
    switch error {
    case .success:
      // A foreign implementation may answer with anything; only a number counts.
      guard let value = ref, CFGetTypeID(value) == CFNumberGetTypeID(),
        let count = value as? Int
      else { return .absent }
      return .count(count)
    case .noValue, .attributeUnsupported, .notImplemented:
      // `.notImplemented` here is the host not implementing THIS attribute:
      // a process without Accessibility never reaches a range read, because
      // the focus query before it would have failed (second-pass review of
      // #3073). The value read keeps its older mapping.
      return .absent
    default:
      return .failed(error)
    }
  }

  package func string(of element: AXUIElement, location: Int, length: Int)
    -> PastedRegionValueRead
  {
    guard location >= 0, length >= 0 else { return .absent }
    var range = CFRange(location: location, length: length)
    guard let rangeValue = AXValueCreate(.cfRange, &range) else { return .absent }
    var ref: CFTypeRef?
    let error = AXUIElementCopyParameterizedAttributeValue(
      element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &ref)
    switch error {
    case .success:
      guard let value = ref else { return .absent }
      guard CFGetTypeID(value) == CFStringGetTypeID(), let text = value as? String else {
        return .notText
      }
      return .text(text)
    case .noValue, .attributeUnsupported, .parameterizedAttributeUnsupported, .notImplemented:
      return .absent
    default:
      return .failed(error)
    }
  }

  package func focusedElement(ofApplication application: AXUIElement) -> PastedRegionFocus {
    var ref: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(
      application, kAXFocusedUIElementAttribute as CFString, &ref)
    // The same mapping as `PasteService.focusedElement`: `.noValue` is the ordinary unfocused
    // answer; a successful call with nothing usable is an absence, not a failure.
    if PasteService.isUnfocusedResponse(error) { return .noFocus }
    guard error == .success else { return .queryFailed(error) }
    guard let value = ref, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .noFocus }
    return .element(value as! AXUIElement)
  }

  package func pid(of element: AXUIElement) -> pid_t? {
    var pid: pid_t = 0
    return AXUIElementGetPid(element, &pid) == .success ? pid : nil
  }

  package func window(of element: AXUIElement) -> PastedRegionWindowRead {
    Self.windowRead(element, attribute: kAXWindowAttribute as CFString)
  }

  package func focusedWindow(of application: AXUIElement) -> PastedRegionWindowRead {
    Self.windowRead(application, attribute: kAXFocusedWindowAttribute as CFString)
  }

  private static func windowRead(_ handle: AXUIElement, attribute: CFString)
    -> PastedRegionWindowRead
  {
    var ref: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(handle, attribute, &ref)
    switch error {
    case .success:
      guard let value = ref else { return .absent }
      guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return .notElement }
      return .window(value as! AXUIElement)
    case .noValue, .attributeUnsupported:
      return .absent
    default:
      return .failed(error)
    }
  }

  package func registerLanding(
    pid: pid_t, element: AXUIElement?, application: AXUIElement,
    admit: @MainActor (AXUIElement) -> Bool,
    handler: @escaping @MainActor (PastedRegionAXNotification) -> Void
  ) -> (any PastedRegionAXRegistration)? {
    Registration.make(
      pid: pid, element: element, application: application, admit: admit, handler: handler)
  }

  /// One `AXObserver` per watch. The C callback receives the registration as
  /// its refcon and hops to the main actor; the run-loop source is added to
  /// the MAIN run loop, so callbacks arrive on the main thread.
  package func register(
    pid: pid_t, element: AXUIElement, application: AXUIElement,
    handler: @escaping @MainActor (PastedRegionAXNotification) -> Void
  ) -> (any PastedRegionAXRegistration)? {
    Registration.make(
      pid: pid, element: element, application: application, admit: { _ in true },
      handler: handler)
  }

  @MainActor
  final class Registration: PastedRegionAXRegistration {
    private let observer: AXObserver
    private let element: AXUIElement?
    private let application: AXUIElement
    private var handler: (@MainActor (PastedRegionAXNotification) -> Void)?
    private var registered: [(AXUIElement, CFString)] = []
    private var sourceAdded = false

    private init(observer: AXObserver, element: AXUIElement?, application: AXUIElement) {
      self.observer = observer
      self.element = element
      self.application = application
    }

    /// `admit` is asked before each `AXObserverAddNotification`; a refusal stops registering and
    /// keeps what already succeeded (the learn watcher passes an `admit` that never refuses).
    static func make(
      pid: pid_t, element: AXUIElement?, application: AXUIElement,
      admit: @MainActor (AXUIElement) -> Bool,
      handler: @escaping @MainActor (PastedRegionAXNotification) -> Void
    ) -> Registration? {
      // The budget is asked before the observer exists: a spent budget creates nothing.
      guard admit(application) else { return nil }
      var observerRef: AXObserver?
      let created = AXObserverCreate(pid, Registration.callback, &observerRef)
      guard created == .success, let observer = observerRef else { return nil }
      let registration = Registration(
        observer: observer, element: element, application: application)
      registration.handler = handler
      let refcon = Unmanaged.passUnretained(registration).toOpaque()
      var wanted: [(AXUIElement, CFString)] = []
      if let element {
        wanted.append((element, kAXValueChangedNotification as CFString))
        wanted.append((element, kAXUIElementDestroyedNotification as CFString))
      }
      wanted.append((application, kAXFocusedUIElementChangedNotification as CFString))
      for (target, name) in wanted {
        guard admit(target) else { break }
        if AXObserverAddNotification(observer, target, name, refcon) == .success {
          registration.registered.append((target, name))
        }
      }
      guard !registration.registered.isEmpty else { return nil }
      CFRunLoopAddSource(
        CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), CFRunLoopMode.defaultMode)
      registration.sourceAdded = true
      return registration
    }

    private static let callback: AXObserverCallback = { _, _, notification, refcon in
      guard let refcon else { return }
      guard let kind = Registration.kind(of: notification as String) else { return }
      // The source lives on the main run loop, so this is the main thread. The
      // pointer is handed across the isolation boundary once, here, and read
      // only inside the main-actor block (`extract-before-assumeisolated`).
      nonisolated(unsafe) let opaque = refcon
      MainActor.assumeIsolated {
        let registration = Unmanaged<Registration>.fromOpaque(opaque).takeUnretainedValue()
        registration.handler?(kind)
      }
    }

    var registeredNotifications: Set<PastedRegionAXNotification> {
      Set(registered.compactMap { Self.kind(of: $0.1 as String) })
    }

    private static func kind(of name: String) -> PastedRegionAXNotification? {
      switch name {
      case kAXValueChangedNotification as String: .valueChanged
      case kAXUIElementDestroyedNotification as String: .elementDestroyed
      case kAXFocusedUIElementChangedNotification as String: .focusedElementChanged
      default: nil
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
