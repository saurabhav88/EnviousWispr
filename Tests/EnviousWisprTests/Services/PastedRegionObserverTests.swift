import ApplicationServices
import EnviousWisprPostProcessing
import EnviousWisprServices
import Foundation
import Testing

// MARK: - Fakes

/// Scripted Accessibility. Every answer is set by the test; nothing here talks
/// to the real AX server, and the element handles are plain `AXUIElement`
/// values used only for identity (`CFEqual`).
@MainActor
final class PastedRegionFakeAX: PastedRegionAXOperations {
  var trusted = true
  var runningPIDs: Set<pid_t> = [42]
  var focused: [pid_t: PastedRegionFocus] = [:]
  var subroles: [String: SelectionReader.SubroleOutcome] = [:]
  var manualHosts: Set<pid_t> = []
  var enableSucceeds = true
  var enableCalls: [pid_t] = []
  /// Reads are consumed in order; the last one repeats.
  var reads: [PastedRegionValueRead] = []
  var readCount = 0
  var timeoutsSet: [(pid_t, Double)] = []
  /// pids whose timeout install fails (application handle = pid, field = pid + 10_000).
  var timeoutFailsFor: Set<pid_t> = []
  var frontmost: pid_t? = 42
  var registrationFails = false
  var registrations: [PastedRegionFakeRegistration] = []

  static func app(_ pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }
  static func field(_ pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid + 10_000) }

  func isTrusted() -> Bool { trusted }
  func isProcessRunning(_ pid: pid_t) -> Bool { runningPIDs.contains(pid) }
  func applicationElement(pid: pid_t) -> AXUIElement { Self.app(pid) }
  /// Electron-shaped: a pid listed here answers `.noFocus` until
  /// `enableManualAccessibility` has been called for it.
  var focusOnlyAfterOptIn: Set<pid_t> = []
  func focusedElement(pid: pid_t) -> PastedRegionFocus {
    if focusOnlyAfterOptIn.contains(pid), !enableCalls.contains(pid) { return .noFocus }
    return focused[pid] ?? .noFocus
  }
  func setMessagingTimeout(_ element: AXUIElement, seconds: Double) -> Bool {
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    timeoutsSet.append((pid, seconds))
    return !timeoutFailsFor.contains(pid)
  }
  func frontmostPID() -> pid_t? { frontmost }
  func subrole(of element: AXUIElement) -> SelectionReader.SubroleOutcome {
    subroles["\(CFHash(element))"] ?? .subrole(nil)
  }
  func supportsManualAccessibility(_ application: AXUIElement) -> Bool {
    var pid: pid_t = 0
    AXUIElementGetPid(application, &pid)
    return manualHosts.contains(pid)
  }
  func enableManualAccessibility(_ application: AXUIElement) -> Bool {
    var pid: pid_t = 0
    AXUIElementGetPid(application, &pid)
    enableCalls.append(pid)
    return enableSucceeds
  }
  func readValue(of element: AXUIElement) -> PastedRegionValueRead {
    readCount += 1
    guard !reads.isEmpty else { return .absent }
    return reads.count > 1 ? reads.removeFirst() : reads[0]
  }
  /// Range reader (#3073): counts and range answers are consumed in order like
  /// `reads`; the last one repeats. Empty means the host has no such attribute.
  var counts: [PastedRegionCountRead] = []
  var countCalls = 0
  var rangeReads: [PastedRegionValueRead] = []
  var rangeCalls: [(location: Int, length: Int)] = []
  func characterCount(of element: AXUIElement) -> PastedRegionCountRead {
    countCalls += 1
    guard !counts.isEmpty else { return .absent }
    return counts.count > 1 ? counts.removeFirst() : counts[0]
  }
  func string(of element: AXUIElement, location: Int, length: Int) -> PastedRegionValueRead {
    rangeCalls.append((location, length))
    guard !rangeReads.isEmpty else { return .absent }
    return rangeReads.count > 1 ? rangeReads.removeFirst() : rangeReads[0]
  }
  func register(
    pid: pid_t, element: AXUIElement, application: AXUIElement,
    handler: @escaping @MainActor (PastedRegionAXNotification) -> Void
  ) -> (any PastedRegionAXRegistration)? {
    guard !registrationFails else { return nil }
    let registration = PastedRegionFakeRegistration(handler: handler)
    registrations.append(registration)
    return registration
  }
}

@MainActor
final class PastedRegionFakeRegistration: PastedRegionAXRegistration {
  let handler: @MainActor (PastedRegionAXNotification) -> Void
  private(set) var invalidated = 0
  init(handler: @escaping @MainActor (PastedRegionAXNotification) -> Void) {
    self.handler = handler
  }
  func invalidate() { invalidated += 1 }
  /// Deliver as the real observer would: even after `invalidate`, a callback
  /// already queued on the run loop can still arrive.
  func fire(_ notification: PastedRegionAXNotification) { handler(notification) }
}

/// Logical clock: nothing fires until the test advances it.
@MainActor
final class PastedRegionFakeScheduler: PastedRegionScheduling {
  final class Work: PastedRegionScheduledWork {
    let dueAt: Int
    let action: @MainActor () -> Void
    var cancelled = false
    init(dueAt: Int, action: @escaping @MainActor () -> Void) {
      self.dueAt = dueAt
      self.action = action
    }
    func cancel() { cancelled = true }
  }

  private(set) var now = 0
  /// Milliseconds the clock moves on EVERY `nowMs` read: models time passing
  /// inside a callback (an AX read, an edit-distance computation). Zero by
  /// default so ordinary tests read a still clock.
  var tickPerNowRead = 0
  var nowMs: Int {
    defer { now += tickPerNowRead }
    return now
  }
  private(set) var works: [Work] = []
  var pending: [Work] { works.filter { !$0.cancelled && $0.dueAt > now } }
  private(set) var scheduledCount = 0

  func schedule(afterMs: Int, _ action: @escaping @MainActor () -> Void)
    -> any PastedRegionScheduledWork
  {
    scheduledCount += 1
    let work = Work(dueAt: now + afterMs, action: action)
    works.append(work)
    return work
  }

  /// Move the clock WITHOUT firing anything: models a delayed main actor (or a
  /// Mac waking up) where overdue callbacks run in arbitrary order later.
  func jump(ms: Int) { now += ms }

  /// Advance the clock, firing due work in due order, including work scheduled
  /// by fired actions when it is also due.
  func advance(ms: Int) {
    let target = now + ms
    // A fired work is marked cancelled, so two works due at the same instant
    // both fire, in scheduling order.
    while true {
      let due = works.enumerated().filter { !$0.element.cancelled && $0.element.dueAt <= target }
        .sorted { ($0.element.dueAt, $0.offset) < ($1.element.dueAt, $1.offset) }
      guard let next = due.first?.element else { break }
      now = max(now, next.dueAt)
      next.cancel()
      next.action()
    }
    now = target
  }
}

// MARK: - Pure geometry

@Suite(.tags(.productOutcome))
struct PastedRegionLocatorTests {
  typealias L = PastedRegionLocator

  @Test("the pasted text is found once, not at all, or more than once")
  func locate() {
    #expect(L.locate(pasted: "Saira", in: "Ask Saira today") == .unique(start: 4, end: 9))
    #expect(L.locate(pasted: "Saira", in: "Ask Sarah today") == .absent)
    #expect(L.locate(pasted: "Saira", in: "Saira and Saira") == .ambiguous)
    #expect(L.locate(pasted: "", in: "anything") == .absent)
    #expect(L.locate(pasted: "long text", in: "long") == .absent)
    // Offsets are UTF-16: the emoji is two units.
    #expect(L.locate(pasted: "hi", in: "😀 hi") == .unique(start: 3, end: 5))
  }

  @Test(
    "#996 app matrix: a contenteditable stores the pasted trailing space as NO-BREAK SPACE, and a composer may drop it; both still locate, with offsets into the value as read"
  )
  func locateAcrossHostSpaceHabits() {
    // Gmail in Chrome, measured 2026-09-20: "…to Sora.\u{00A0}" for a pasted "…to Sora. ".
    #expect(L.locate(pasted: "to Sora. ", in: "Send it to Sora.\u{00A0}") == .unique(start: 8, end: 17))
    // Slack: the trailing space is gone.
    #expect(L.locate(pasted: "to Sora. ", in: "Send it to Sora.") == .unique(start: 8, end: 16))
    // Inner no-break spaces fold too, and the value's own units are what the offsets count.
    #expect(L.locate(pasted: "to Sora", in: "Send\u{00A0}it\u{00A0}to\u{00A0}Sora") == .unique(start: 8, end: 15))
    // The trimmed retry never invents a match, and never trims to nothing.
    #expect(L.locate(pasted: "to Sarah ", in: "Send it to Sora.") == .absent)
    #expect(L.locate(pasted: "   ", in: "Send it to Sora.") == .absent)
    // An exact hit is taken before any trimming; two exact hits are still ambiguous.
    #expect(L.locate(pasted: "Sora. ", in: "Sora. and Sora.") == .unique(start: 0, end: 6))
    #expect(L.locate(pasted: "Sora. ", in: "Sora. and Sora. ") == .ambiguous)
    // Only when the exact text is absent does the trimmed text count, once.
    #expect(L.locate(pasted: "Sora. ", in: "Sora.") == .unique(start: 0, end: 5))
    #expect(L.locate(pasted: "Sora. ", in: "Sora.,Sora.") == .ambiguous)
  }

  @Test(
    "#996 Ghostty follow-up: a terminal wraps a long paste into rows with a gutter; a pasted space matches the whitespace run, a wrap inside a word does not"
  )
  func locateAcrossTerminalWrap() {
    // Ghostty AXTextArea, measured 2026-09-21: one row per line, the Claude Code
    // input continues on the next row after a two-cell gutter.
    let screen = "❯\u{00A0}Quick update before I log off. I asked Kishtik to pull the\n  full report so we can review it.\n───"
    let pasted = "Quick update before I log off. I asked Kishtik to pull the full report so we can review it."
    let located = L.locate(pasted: pasted, in: screen)
    guard case .unique(let start, let end) = located else {
      Issue.record("expected a unique hit across the wrap, got \(located)")
      return
    }
    let units = Array(screen.utf16)
    let rendered = String(decoding: units[start..<end], as: UTF16.self)
    #expect(rendered.hasPrefix("Quick update") && rendered.hasSuffix("review it."))
    #expect(rendered.contains("the\n  full"), "the slice carries the host's own rendering")
    // The rendering and the paste tokenize alike, so a wrap is never an edit.
    #expect(EditAlignment.align(pasted: pasted, edited: rendered).runs.isEmpty)
    // A break inside a word is not the paste: the pasted text has no space there.
    #expect(L.locate(pasted: "pull the report", in: "pull the re\n  port") == .absent)
    // Any whitespace run stands in for one pasted space, including a tab and a bare newline.
    #expect(L.locate(pasted: "a b", in: "x a\tb y") == .unique(start: 2, end: 5))
    #expect(L.locate(pasted: "a b", in: "a\n\n b") == .unique(start: 0, end: 5))
    // Two wrapped occurrences are still ambiguous; a lone one-liner still exact.
    #expect(L.locate(pasted: "a b", in: "a\n b and a b") == .ambiguous)
    #expect(L.locate(pasted: "a b", in: "a b") == .unique(start: 0, end: 3))
    // Run against run: k pasted spaces need a run of at least k, and a leading
    // pasted space anchors once per host run, not once per unit of it.
    #expect(L.locate(pasted: " a", in: "  a") == .unique(start: 0, end: 3))
    #expect(L.locate(pasted: "a  b", in: "a  b") == .unique(start: 0, end: 4))
    #expect(L.locate(pasted: "a  b", in: "a\n  b") == .unique(start: 0, end: 5))
    #expect(L.locate(pasted: "a  b", in: "a b") == .absent)
    #expect(L.locate(pasted: "a ", in: "a  ") == .unique(start: 0, end: 3))
  }

  @Test(
    "anchors keep up to 64 UTF-16 units a side, less at the edges, and never split a surrogate pair"
  )
  func anchors() {
    let before = String(repeating: "b", count: 100)
    let after = String(repeating: "a", count: 100)
    let value = before + "PASTE" + after
    let a = L.anchors(around: 100, end: 105, in: value)
    #expect(a.before.utf16.count == 64 && a.after.utf16.count == 64)
    #expect(
      a.before == String(repeating: "b", count: 64) && a.after == String(repeating: "a", count: 64))

    let edge = L.anchors(around: 0, end: 5, in: "PASTE tail")
    #expect(edge.before == "" && edge.after == " tail")
    let end = L.anchors(around: 5, end: 10, in: "head PASTE")
    #expect(end.before == "head " && end.after == "")

    // One letter, an emoji (2 units) and 63 letters before the paste: a 64-unit
    // window would start ON the emoji's trail surrogate, so the anchor drops the
    // whole emoji rather than cutting it. Mirror image after the paste.
    let v2 = "x😀" + String(repeating: "x", count: 63) + "PASTE" + String(repeating: "y", count: 63) + "😀zz"
    let b = L.anchors(around: 66, end: 71, in: v2)
    #expect(b.before == String(repeating: "x", count: 63), "\(b.before.utf16.count)")
    #expect(b.after == String(repeating: "y", count: 63), "\(b.after.utf16.count)")
    #expect(Array(b.before.utf16).allSatisfy { !UTF16.isTrailSurrogate($0) && !UTF16.isLeadSurrogate($0) })
  }

  @Test(
    "the region between the anchors follows the edit; missing or doubled anchors are typed outcomes"
  )
  func region() {
    let anchors = PastedRegionAnchors(before: "Ask ", after: " today")
    #expect(L.region(in: "Ask Saira today", anchors: anchors) == .region("Saira"))
    #expect(L.region(in: "Ask Sarah Khan today", anchors: anchors) == .region("Sarah Khan"))
    #expect(L.region(in: "Ask  today", anchors: anchors) == .region(""))
    #expect(L.region(in: "Saira today", anchors: anchors) == .lost)
    #expect(L.region(in: "Ask Saira", anchors: anchors) == .lost)
    #expect(L.region(in: "Ask Saira today Ask again today", anchors: anchors) == .ambiguous)
    // An `after` that also occurs BEFORE the region is not ambiguity.
    #expect(L.region(in: "today Ask Saira today", anchors: anchors) == .region("Saira"))
    // Edge anchors: the region runs to the field's start or end.
    #expect(
      L.region(in: "Saira today", anchors: PastedRegionAnchors(before: "", after: " today"))
        == .region("Saira"))
    #expect(
      L.region(in: "Ask Saira", anchors: PastedRegionAnchors(before: "Ask ", after: ""))
        == .region("Saira"))
    #expect(
      L.region(in: "whole field", anchors: PastedRegionAnchors(before: "", after: ""))
        == .region("whole field"))
  }

  @Test(
    "edit distance: a word fix is within half the pasted length, a rewrite is not, long pastes use the length bound"
  )
  func editDistance() {
    let pasted = "please call sarah about the invoice tomorrow morning"
    #expect(L.editDistance(pasted: pasted, region: "please call Saira about the invoice tomorrow morning") == .within)
    #expect(L.editDistance(pasted: pasted, region: "completely different sentence typed over the paste") == .exceeded)
    #expect(L.editDistance(pasted: pasted, region: "") == .exceeded)
    #expect(L.editDistance(pasted: pasted, region: pasted) == .within)
    // The floor: a short paste keeps a budget that admits a full-token fix
    // (cloud review of PR #3054); the fraction alone would give "Zorab" 2.
    #expect(L.editDistance(pasted: "Zorab", region: "Saurabh") == .within)
    #expect(L.editDistance(pasted: "Zorab", region: "a completely different sentence") == .exceeded)
    #expect(L.editDistance(pasted: "ab", region: "abc", limitFloor: 0) == .within, "one insert within limit 1")
    #expect(L.editDistance(pasted: "ab", region: "abcd", limitFloor: 0) == .exceeded, "two inserts over limit 1")
    // Exact banded distance vs its length lower bound: equal lengths, all letters changed.
    #expect(L.editDistance(pasted: "abcdefgh", region: "ABCDEFGH", limitFloor: 0) == .exceeded)
    // Over the cell budget the answer is INCONCLUSIVE, never "within": a same-length
    // rewrite of a long paste cannot pass as an edit. The length bound still decides
    // what it can.
    let long = String(repeating: "a", count: 5_000)
    let longRewritten = String(repeating: "b", count: long.count)
    #expect(long.utf16.count * (2 * 2_500 + 1) > PastedRegionTiming.editDistanceCellBudget)
    #expect(L.editDistance(pasted: long, region: longRewritten) == .inconclusive)
    #expect(L.editDistance(pasted: long, region: long) == .within)
    #expect(L.editDistance(pasted: long, region: String(long.prefix(100))) == .exceeded)
    // A tiny budget forces the inconclusive branch on a short input too.
    #expect(L.editDistance(pasted: "abcdefgh", region: "abcdefgX", cellBudget: 1) == .inconclusive)
  }

  @Test("the end-reason vocabulary is the plan's thirteen snake_case tokens")
  func endReasons() {
    let expected = [
      "settled", "textbox_emptied", "region_removed", "dictated_text_not_found",
      "anchor_ambiguous", "focus_changed", "element_destroyed", "next_dictation_started",
      "edit_distance_exceeded", "ceiling_elapsed", "capture_unsupported", "permission_lost",
      "app_terminated",
    ]
    #expect(PastedRegionEndReason.allCases.map(\.rawValue) == expected)
    #expect(
      PastedRegionCaptureSkip.allCases.map(\.rawValue) == [
        "secure_field", "no_focused_element", "destination_mismatch",
      ])
  }

  @Test("the timing contract carries the plan's numbers")
  func timing() {
    #expect(PastedRegionTiming.settleMs == 1500)
    #expect(PastedRegionTiming.pollMs == 750)
    #expect(PastedRegionTiming.flushMinQuietMs == 500)
    #expect(PastedRegionTiming.ceilingMs == 60_000)
    #expect(PastedRegionTiming.maxValueUTF16 == 20_000)
    #expect(PastedRegionTiming.anchorUTF16 == 64)
    #expect(PastedRegionTiming.editDistanceLimitFraction == 0.5)
    #expect(PastedRegionTiming.editDistanceCellBudget == 16_000_000)
    #expect(PastedRegionTiming.maxConsecutiveReadFailures == 3)
  }
}

// MARK: - Capture

@MainActor
@Suite(.tags(.productOutcome))
struct PastedRegionObserverCaptureTests {
  let ax = PastedRegionFakeAX()
  let scheduler = PastedRegionFakeScheduler()
  var observer: PastedRegionObserver { PastedRegionObserver(ax: ax, scheduler: scheduler) }
  let pid: pid_t = 42

  init() {
    ax.focused[pid] = .element(PastedRegionFakeAX.field(pid))
    ax.reads = [.text("Ask Sarah today")]
  }

  @Test(
    "a readable field with the pasted text once is captured with its anchors and both timeouts set")
  func captured() throws {
    guard case .captured(let target) = observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) else {
      Issue.record("expected captured")
      return
    }
    #expect(target.pid == pid && target.pastedText == "Sarah")
    #expect(target.anchors == PastedRegionAnchors(before: "Ask ", after: " today"))
    #expect(target.isManualAccessibilityHost == false)
    #expect(CFEqual(target.element, PastedRegionFakeAX.field(pid)))
    // The application and the focused element are bounded separately (#1332).
    #expect(ax.timeoutsSet.map(\.1) == [0.5, 0.5])
    #expect(Set(ax.timeoutsSet.map(\.0)) == [pid, pid + 10_000])
  }

  @Test("no permission, a dead process, no focus and a failed query each refuse without reading")
  func refusals() {
    ax.trusted = false
    #expect(observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) == .ended(.permissionLost))
    ax.trusted = true
    #expect(observer.capture(pid: 7, pastedText: "Sarah", pastedAtMs: 0) == .ended(.appTerminated))
    ax.focused[pid] = .noFocus
    #expect(observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) == .skipped(.noFocusedElement))
    ax.focused[pid] = .queryFailed(.cannotComplete)
    #expect(observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) == .ended(.captureUnsupported))
    ax.focused[pid] = .queryFailed(.apiDisabled)
    #expect(observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) == .ended(.permissionLost))
    #expect(ax.readCount == 0, "nothing was read")
  }

  @Test("the destination must be the active application, and a failed timeout install refuses the read")
  func frontmostAndTimeouts() {
    ax.frontmost = 7
    #expect(observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) == .skipped(.destinationMismatch))
    ax.frontmost = nil
    #expect(observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) == .skipped(.destinationMismatch))
    ax.frontmost = pid
    ax.timeoutFailsFor = [pid]
    #expect(observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) == .ended(.captureUnsupported))
    ax.timeoutFailsFor = [pid + 10_000]
    #expect(observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) == .ended(.captureUnsupported))
    #expect(ax.readCount == 0, "no read behind a missing bound")
    ax.timeoutFailsFor = []
    guard case .captured(let target) = observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 1234) else {
      Issue.record("expected captured")
      return
    }
    #expect(target.pastedAtMs == 1234)
  }

  @Test("a secure field, and a field whose subrole cannot be read, are never observed")
  func secure() {
    ax.subroles["\(CFHash(PastedRegionFakeAX.field(pid)))"] = .subrole(kAXSecureTextFieldSubrole as String)
    #expect(observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) == .skipped(.secureField))
    ax.subroles["\(CFHash(PastedRegionFakeAX.field(pid)))"] = .unreadable
    #expect(observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) == .skipped(.secureField))
    #expect(ax.readCount == 0)
  }

  @Test("value outcomes: too long, absent, not text, failed, not found, ambiguous")
  func valueOutcomes() {
    ax.reads = [.text(String(repeating: "x", count: 20_001))]
    #expect(observer.capture(pid: pid, pastedText: "x", pastedAtMs: 0) == .ended(.captureUnsupported))
    ax.reads = [.text(String(repeating: "x", count: 20_000))]
    #expect(observer.capture(pid: pid, pastedText: "y", pastedAtMs: 0) == .ended(.dictatedTextNotFound))
    ax.reads = [.absent]
    #expect(observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) == .ended(.captureUnsupported))
    ax.reads = [.notText]
    #expect(observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) == .ended(.captureUnsupported))
    ax.reads = [.failed(.cannotComplete)]
    #expect(observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) == .ended(.captureUnsupported))
    ax.reads = [.failed(.notImplemented)]
    #expect(observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) == .ended(.permissionLost))
    ax.reads = [.text("Sarah met Sarah")]
    #expect(observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) == .ended(.anchorAmbiguous))
  }

  @Test("an Electron host gets AXManualAccessibility on every capture, before the first read; a non-Electron host is never asked")
  func manualAccessibility() {
    ax.manualHosts = [pid]
    let o = observer
    guard case .captured(let first) = o.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) else {
      Issue.record("expected captured")
      return
    }
    #expect(first.isManualAccessibilityHost)
    #expect(ax.enableCalls == [pid])
    _ = o.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0)
    #expect(ax.enableCalls == [pid, pid], "asked again: no per-pid memory can go stale across a pid reuse")
    ax.manualHosts = []
    _ = o.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0)
    #expect(ax.enableCalls == [pid, pid], "a host that does not need it is not asked")
  }

  @Test("an Electron host whose focused element appears only after the opt-in is still captured: the opt-in runs before the focus query")
  func manualAccessibilityBeforeFocus() {
    ax.manualHosts = [pid]
    ax.focusOnlyAfterOptIn = [pid]
    let o = observer
    guard case .captured(let target) = o.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) else {
      Issue.record("expected captured; the focus query ran before AXManualAccessibility was enabled")
      return
    }
    #expect(target.isManualAccessibilityHost && ax.enableCalls == [pid])
  }
}

// MARK: - Observation

@MainActor
@Suite(.tags(.productOutcome))
struct PastedRegionObserverWatchTests {
  let ax = PastedRegionFakeAX()
  let scheduler = PastedRegionFakeScheduler()
  let observer: PastedRegionObserver
  let pid: pid_t = 42
  let target: PastedRegionTarget
  final class Events {
    var list: [PastedRegionEvent] = []
  }
  let events = Events()

  init() throws {
    ax.focused[pid] = .element(PastedRegionFakeAX.field(pid))
    // The pasted text is the whole delivered payload (a sentence), so typing
    // through a word inside it stays within the edit-distance bound.
    ax.reads = [.text("Note: Ask Sarah today please")]
    observer = PastedRegionObserver(ax: ax, scheduler: scheduler)
    guard case .captured(let t) = observer.capture(pid: pid, pastedText: "Ask Sarah today", pastedAtMs: 0) else {
      throw TestSetupError.capture
    }
    target = t
    ax.readCount = 0
  }

  enum TestSetupError: Error { case capture }

  func start() {
    let events = events
    observer.start(target) { events.list.append($0) }
  }

  @Test(
    "start registers the AX observer, arms the poll and the ceiling, and reads nothing until the poll"
  )
  func startArms() {
    start()
    #expect(observer.isObserving && observer.isPollOnly == false)
    #expect(ax.registrations.count == 1)
    #expect(scheduler.pending.map(\.dueAt).sorted() == [750, 60_000])
    #expect(ax.readCount == 0)
  }

  @Test(
    "the poll reads every 750 ms while identity holds, reports a change once, and settles 1500 ms after the last change"
  )
  func pollChangeSettle() {
    start()
    scheduler.advance(ms: 750)
    #expect(ax.readCount == 1 && events.list.isEmpty, "unchanged value: no event")
    ax.reads = [.text("Note: Ask Saira today please")]
    scheduler.advance(ms: 750)
    #expect(events.list == [.changed(region: "Ask Saira today")])
    scheduler.advance(ms: 750)
    #expect(events.list == [.changed(region: "Ask Saira today")], "same value again: no duplicate")
    // 1500 ms after the change (poll at 1500, settle due at 1500 + 1500 = 3000).
    scheduler.advance(ms: 750)
    #expect(events.list == [.changed(region: "Ask Saira today"), .settled(region: "Ask Saira today")])
    scheduler.advance(ms: 3000)
    #expect(events.list.count == 2, "no second settle without a new change")
    #expect(observer.isObserving)
  }

  @Test("a change inside the settle window re-arms it; settle fires once, for the latest text")
  func settleRearms() {
    start()
    ax.reads = [.text("Note: Ask Sa today please")]
    scheduler.advance(ms: 750)
    ax.reads = [.text("Note: Ask Sai today please")]
    scheduler.advance(ms: 750)
    ax.reads = [.text("Note: Ask Saira today please")]
    scheduler.advance(ms: 750)
    #expect(
      events.list == [.changed(region: "Ask Sa today"), .changed(region: "Ask Sai today"), .changed(region: "Ask Saira today")])
    // Settle due at 2250 + 1500 = 3750; nothing at 3000.
    scheduler.advance(ms: 750)
    #expect(events.list.count == 3)
    scheduler.advance(ms: 750)
    #expect(events.list.last == .settled(region: "Ask Saira today"))
    #expect(
      events.list.filter { if case .settled = $0 { return true } else { return false } }.count == 1)
  }

  @Test(
    "AX notifications drive the same evaluation: value changed reports, focus changed checks identity, destroyed ends"
  )
  func notifications() throws {
    start()
    let registration = try #require(ax.registrations.first)
    ax.reads = [.text("Note: Ask Saira today please")]
    registration.fire(.valueChanged)
    #expect(events.list == [.changed(region: "Ask Saira today")])
    registration.fire(.focusedElementChanged)
    #expect(events.list.count == 1, "focus still on our element: nothing new")
    ax.focused[pid] = .element(PastedRegionFakeAX.field(99))
    registration.fire(.focusedElementChanged)
    #expect(events.list.count == 1, "focus on another element of the same app: tolerated for the grace, the element still read")
    #expect(observer.isObserving)
    scheduler.jump(ms: PastedRegionTiming.focusGraceMs)
    registration.fire(.focusedElementChanged)
    // The pending change is older than `flushMinQuietMs`, so it is flushed first.
    #expect(events.list.last == .ended(.focusChanged))
    #expect(events.list.contains(.settled(region: "Ask Saira today")))
    #expect(observer.isObserving == false && registration.invalidated == 1)
  }

  @Test("element destroyed ends the watch; a queued callback after the end produces nothing")
  func destroyedThenStale() throws {
    start()
    let registration = try #require(ax.registrations.first)
    registration.fire(.elementDestroyed)
    #expect(events.list == [.ended(.elementDestroyed)])
    ax.reads = [.text("Note: Ask Saira today please")]
    registration.fire(.valueChanged)
    scheduler.advance(ms: 5000)
    #expect(events.list == [.ended(.elementDestroyed)], "nothing after the end")
    #expect(scheduler.pending.isEmpty, "every timer was cancelled")
  }

  @Test(
    "end reasons from the field: emptied, region removed, anchors lost, ambiguous, too long, rewritten"
  )
  func fieldEndReasons() {
    func run(_ read: PastedRegionValueRead, _ expected: PastedRegionEndReason) {
      let o = PastedRegionObserver(ax: ax, scheduler: scheduler)
      let e = Events()
      o.start(target) { e.list.append($0) }
      ax.reads = [read]
      scheduler.advance(ms: 750)
      #expect(e.list == [.ended(expected)], "\(read)")
      #expect(o.isObserving == false)
    }
    run(.text(""), .textboxEmptied)
    run(.text("Note:  please"), .regionRemoved)
    run(.text("Ask Sarah today please"), .regionRemoved)
    run(.text("Note: Ask Sarah today please Note: x please"), .anchorAmbiguous)
    run(.text(String(repeating: "x", count: 20_001)), .captureUnsupported)
    run(.text("Note: a completely rewritten sentence typed over the paste please"), .editDistanceExceeded)
  }

  @Test(
    "three consecutive failed or non-text reads end as capture_unsupported; a good read in between resets the count"
  )
  func readFailurePolicy() {
    start()
    ax.reads = [
      .failed(.cannotComplete), .absent, .text("Note: Ask Sarah today please"), .notText, .failed(.failure),
      .absent,
    ]
    scheduler.advance(ms: 750 * 5)
    #expect(events.list.isEmpty, "two failures, a success, two failures: still watching")
    #expect(observer.isObserving)
    scheduler.advance(ms: 750)
    #expect(events.list == [.ended(.captureUnsupported)])
  }

  @Test(
    "lost permission and a terminated app end at once"
  )
  func permissionAndProcess() {
    ax.manualHosts = [pid]
    _ = observer.capture(pid: pid, pastedText: "Ask Sarah today", pastedAtMs: 0)
    start()
    ax.reads = [.failed(.apiDisabled)]
    scheduler.advance(ms: 750)
    #expect(events.list == [.ended(.permissionLost)])

    let e2 = Events()
    observer.start(target) { e2.list.append($0) }
    ax.runningPIDs = []
    scheduler.advance(ms: 750)
    #expect(e2.list == [.ended(.appTerminated)])

    let e3 = Events()
    ax.runningPIDs = [pid]
    observer.start(target) { e3.list.append($0) }
    ax.trusted = false
    scheduler.advance(ms: 750)
    #expect(e3.list == [.ended(.permissionLost)])
  }

  @Test("a focus query failure during the watch counts as a read failure, not a focus change")
  func focusQueryFailure() {
    start()
    ax.focused[pid] = .queryFailed(.cannotComplete)
    scheduler.advance(ms: 750 * 2)
    #expect(events.list.isEmpty && observer.isObserving)
    scheduler.advance(ms: 750)
    #expect(events.list == [.ended(.captureUnsupported)])
  }

  @Test("the 60-second ceiling ends the watch even when nothing ever changes")
  func ceiling() {
    start()
    scheduler.advance(ms: 59_999)
    #expect(events.list.isEmpty && observer.isObserving)
    scheduler.advance(ms: 1)
    #expect(events.list == [.ended(.ceilingElapsed)])
    #expect(scheduler.pending.isEmpty)
  }

  @Test("when the AX observer cannot be created the poll alone carries the watch")
  func pollOnly() {
    ax.registrationFails = true
    start()
    #expect(observer.isPollOnly && observer.isObserving)
    ax.reads = [.text("Note: Ask Saira today please")]
    scheduler.advance(ms: 750)
    #expect(events.list == [.changed(region: "Ask Saira today")])
  }

  @Test(
    "stop is idempotent: timers cancelled, registration invalidated once, stale timers and callbacks produce nothing"
  )
  func stop() throws {
    start()
    let registration = try #require(ax.registrations.first)
    ax.reads = [.text("Note: Ask Saira today please")]
    scheduler.advance(ms: 750)
    #expect(events.list == [.changed(region: "Ask Saira today")])
    observer.stop()
    observer.stop()
    #expect(observer.isObserving == false && registration.invalidated == 1)
    #expect(scheduler.pending.isEmpty)
    registration.fire(.valueChanged)
    registration.fire(.elementDestroyed)
    scheduler.advance(ms: 120_000)
    #expect(events.list == [.changed(region: "Ask Saira today")], "no event after stop, not even an end")
  }

  @Test("settling re-validates: a value change seen first by the settle read reports instead of settling")
  func settleRevalidates() {
    start()
    // Poll at 750 sees new1; poll at 1500 still sees new1; the settle read at
    // 2250 is the FIRST to see new2 (scripted read order), so it reports a
    // change and a fresh quiet interval starts from there.
    ax.reads = [
      .text("Note: Ask Saira today please"), .text("Note: Ask Saira today please"),
      .text("Note: Ask Sairaa today please"),
    ]
    scheduler.advance(ms: 750)
    #expect(events.list == [.changed(region: "Ask Saira today")])
    scheduler.advance(ms: 1500)
    #expect(events.list == [.changed(region: "Ask Saira today"), .changed(region: "Ask Sairaa today")])
    #expect(ax.readCount == 4, "poll 750, poll 1500, settle 2250, poll 2250")
    scheduler.advance(ms: 1499)
    #expect(events.list.count == 2, "the new text has not been quiet for 1500 ms yet")
    scheduler.advance(ms: 1)
    #expect(events.list.last == .settled(region: "Ask Sairaa today"))
    scheduler.advance(ms: 3000)
    #expect(events.list.count == 3, "one settlement per quiet interval")
  }

  @Test("an app switch ends the watch even while the destination keeps its focused element")
  func appSwitch() {
    start()
    ax.frontmost = 99
    scheduler.advance(ms: 750)
    #expect(events.list == [.ended(.focusChanged)])
    #expect(ax.readCount == 0, "another app's turn: nothing is read")
  }

  @Test("a read failure at the settle instant does not settle; a focus loss at the settle instant is tolerated for the focus grace, then ends")
  func settleFailurePaths() throws {
    start()
    ax.reads = [.text("Note: Ask Saira today please")]
    scheduler.advance(ms: 750)
    // The poll at 1500 fails and cancels the pending settle; the poll at 2250
    // fails too. No settlement, the watch continues.
    ax.reads = [.failed(.cannotComplete), .failed(.cannotComplete), .text("Note: Ask Saira today please")]
    scheduler.advance(ms: 1500)
    #expect(events.list == [.changed(region: "Ask Saira today")], "a failed read cannot establish quiet time")
    #expect(observer.isObserving)
    #expect(ax.readCount == 3, "poll 750, poll 1500, poll 2250; the cancelled settle read nothing")
    // Recovery: the good unchanged poll at 3000 starts a fresh quiet interval,
    // which settles once at 4500 and never again.
    scheduler.advance(ms: 750)
    #expect(events.list.count == 1)
    scheduler.advance(ms: 1499)
    #expect(events.list.count == 1, "1499 ms after recovery is not quiet yet")
    scheduler.advance(ms: 1)
    #expect(events.list == [.changed(region: "Ask Saira today"), .settled(region: "Ask Saira today")])
    scheduler.advance(ms: 6000)
    #expect(events.list.count == 2, "no duplicate settlement while the text stays put")

    let o2 = PastedRegionObserver(ax: ax, scheduler: scheduler)
    let e2 = Events()
    ax.reads = [.text("Note: Ask Sarah today please")]
    o2.start(target) { e2.list.append($0) }
    ax.reads = [.text("Note: Ask Saira today please")]
    scheduler.advance(ms: 750)
    ax.focused[pid] = .element(PastedRegionFakeAX.field(77))
    scheduler.advance(ms: 1500)
    // #996: focus on another element of the SAME app is tolerated for
    // `focusGraceMs` (an autocomplete popup); the element is still read, so the
    // quiet interval settles normally.
    #expect(e2.list == [.changed(region: "Ask Saira today"), .settled(region: "Ask Saira today")])
    #expect(o2.isObserving)
    // Focus that stays away for the whole grace ends the watch.
    scheduler.advance(ms: 1500)
    #expect(e2.list.last == .ended(.focusChanged))
    #expect(o2.isObserving == false)
  }

  @Test("a value-changed notification also re-validates the active application")
  func notificationRevalidates() throws {
    start()
    let registration = try #require(ax.registrations.first)
    ax.frontmost = 99
    ax.reads = [.text("Note: Ask Saira today please")]
    registration.fire(.valueChanged)
    #expect(events.list == [.ended(.focusChanged)])
  }

  @Test("an overdue poll, notification or settle after the deadline ends with ceiling_elapsed and reads nothing new; a change read before it is flushed")
  func deadlineEnforcedAtEveryCallback() throws {
    start()
    let registration = try #require(ax.registrations.first)
    ax.reads = [.text("Note: Ask Saira today please")]
    // The main actor stalls past the deadline; the notification runs first.
    scheduler.jump(ms: 60_000)
    registration.fire(.valueChanged)
    #expect(events.list == [.ended(.ceilingElapsed)])
    #expect(ax.readCount == 0, "nothing is read past the deadline")
    scheduler.advance(ms: 1)
    #expect(events.list.count == 1, "the queued ceiling callback adds nothing")

    // Same for a settle timer that is overdue when it finally runs.
    let e2 = Events()
    let o2 = PastedRegionObserver(ax: ax, scheduler: scheduler)
    ax.reads = [.text("Note: Ask Sarah today please")]
    guard case .captured(let late) = o2.capture(pid: pid, pastedText: "Ask Sarah today", pastedAtMs: scheduler.nowMs) else {
      Issue.record("expected captured")
      return
    }
    ax.reads = [.text("Note: Ask Saira today please")]
    o2.start(late) { e2.list.append($0) }
    scheduler.advance(ms: 750)
    #expect(e2.list == [.changed(region: "Ask Saira today")])
    scheduler.jump(ms: 60_000)
    scheduler.advance(ms: 0)
    // Nothing is READ past the deadline; the change read before it is flushed
    // (#996 `flushesPendingEdit`), then the ceiling ends the watch.
    #expect(
      e2.list == [
        .changed(region: "Ask Saira today"), .settled(region: "Ask Saira today"),
        .ended(.ceilingElapsed),
      ])
    #expect(o2.isObserving == false)
  }

  @Test("a deadline reached between the post-read check and the emission still wins: no changed, one ceiling_elapsed")
  func deadlineCrossedInsideTheCallback() throws {
    start()
    let registration = try #require(ax.registrations.first)
    ax.reads = [.text("Note: Ask Saira today please")]
    // Four `nowMs` reads on the notification path (handle entry, evaluate
    // entry, post-read, pre-emission) at one tick each. Starting at D-3 the
    // first three see D-3, D-2, D-1 and only the pre-emission check sees D.
    scheduler.jump(ms: 60_000 - 3)
    scheduler.tickPerNowRead = 1
    registration.fire(.valueChanged)
    #expect(events.list == [.ended(.ceilingElapsed)], "\(events.list)")
    #expect(ax.readCount == 1, "the read happened; the emission did not")
    scheduler.tickPerNowRead = 0
    scheduler.advance(ms: 10)
    #expect(events.list.count == 1)

    // Control: one tick earlier, every check is before the deadline and the
    // change IS reported, so the assertion above binds the final check.
    let e2 = Events()
    let o2 = PastedRegionObserver(ax: ax, scheduler: scheduler)
    ax.reads = [.text("Note: Ask Sarah today please")]
    guard case .captured(let late) = o2.capture(pid: pid, pastedText: "Ask Sarah today", pastedAtMs: scheduler.nowMs) else {
      Issue.record("expected captured")
      return
    }
    o2.start(late) { e2.list.append($0) }
    let r2 = try #require(ax.registrations.last)
    ax.reads = [.text("Note: Ask Saira today please")]
    scheduler.jump(ms: 60_000 - 4)
    scheduler.tickPerNowRead = 1
    r2.fire(.valueChanged)
    scheduler.tickPerNowRead = 0
    #expect(e2.list == [.changed(region: "Ask Saira today")], "\(e2.list)")

    // A destroyed-element notification after the deadline also ends as
    // ceiling_elapsed, flushing the change that was read before the deadline.
    scheduler.jump(ms: 60_000)
    r2.fire(.elementDestroyed)
    #expect(
      e2.list == [
        .changed(region: "Ask Saira today"), .settled(region: "Ask Saira today"),
        .ended(.ceilingElapsed),
      ])
  }

  @Test("the ceiling counts from the paste: a late start gets only the remainder, an expired deadline ends at once")
  func ceilingFromPaste() {
    // Start 50 s after the paste: 10 s remain.
    scheduler.advance(ms: 50_000)
    start()
    scheduler.advance(ms: 9_999)
    #expect(events.list.isEmpty && observer.isObserving)
    scheduler.advance(ms: 1)
    #expect(events.list == [.ended(.ceilingElapsed)])

    let e2 = Events()
    scheduler.advance(ms: 60_000)
    observer.start(target) { e2.list.append($0) }
    #expect(e2.list == [.ended(.ceilingElapsed)] && observer.isObserving == false)
    #expect(ax.registrations.count == 1, "an expired deadline registers nothing")
  }

  @Test("stop() called from inside a callback is honoured: no settle is armed afterwards")
  func stopInsideCallback() {
    let events = events
    let o = observer
    o.start(target) { event in
      events.list.append(event)
      o.stop()
    }
    ax.reads = [.text("Note: Ask Saira today please")]
    scheduler.advance(ms: 750)
    #expect(events.list == [.changed(region: "Ask Saira today")])
    #expect(o.isObserving == false && scheduler.pending.isEmpty)
    scheduler.advance(ms: 5000)
    #expect(events.list.count == 1)
  }

  @Test(
    "a second start supersedes the first: the old registration is invalidated and its callbacks are ignored"
  )
  func restart() throws {
    start()
    let first = try #require(ax.registrations.first)
    let e2 = Events()
    observer.start(target) { e2.list.append($0) }
    #expect(first.invalidated == 1 && ax.registrations.count == 2)
    first.fire(.elementDestroyed)
    #expect(events.list.isEmpty && e2.list.isEmpty, "the superseded watch's callback is dropped")
    ax.registrations[1].fire(.elementDestroyed)
    #expect(e2.list == [.ended(.elementDestroyed)])
  }

  // MARK: #996 flush on a person-caused end (Wispr Flow parity, baseline 2026-09-20)

  @Test(
    "a fix typed and SENT inside the quiet interval is flushed as one settled burst before textbox_emptied"
  )
  func sendInsideSettleFlushes() {
    start()
    ax.reads = [.text("Note: Ask Saira today please")]
    scheduler.advance(ms: 750)
    #expect(events.list == [.changed(region: "Ask Saira today")])
    // Return sends the message 750 ms later, well inside the 1500 ms settle.
    ax.reads = [.text("")]
    scheduler.advance(ms: 750)
    #expect(
      events.list == [
        .changed(region: "Ask Saira today"), .settled(region: "Ask Saira today"),
        .ended(.textboxEmptied),
      ])
    #expect(observer.isObserving == false)
    scheduler.advance(ms: 3000)
    #expect(events.list.count == 3, "the cancelled settle timer fires nothing after the end")
  }

  @Test("focus moving away and the app quitting flush the same way")
  func focusChangeAndAppQuitFlush() {
    start()
    ax.reads = [.text("Note: Ask Saira today please")]
    scheduler.advance(ms: 750)
    ax.frontmost = 7  // another APPLICATION: ends at once, no grace
    scheduler.advance(ms: 750)
    #expect(
      events.list == [
        .changed(region: "Ask Saira today"), .settled(region: "Ask Saira today"),
        .ended(.focusChanged),
      ])

    let e2 = Events()
    ax.frontmost = pid
    ax.reads = [.text("Note: Ask Sarah today please")]
    observer.start(target) { e2.list.append($0) }
    ax.reads = [.text("Note: Ask Saira today please")]
    scheduler.advance(ms: 750)
    ax.runningPIDs = []
    scheduler.advance(ms: 750)
    #expect(
      e2.list == [
        .changed(region: "Ask Saira today"), .settled(region: "Ask Saira today"),
        .ended(.appTerminated),
      ])
  }

  @Test("nothing pending, nothing flushed: an emptied box after an already settled edit ends plainly")
  func noPendingEditNoFlush() {
    start()
    ax.reads = [.text("Note: Ask Saira today please")]
    scheduler.advance(ms: 750)
    scheduler.advance(ms: 1500)
    #expect(events.list == [.changed(region: "Ask Saira today"), .settled(region: "Ask Saira today")])
    ax.reads = [.text("")]
    scheduler.advance(ms: 750)
    #expect(events.list.last == .ended(.textboxEmptied))
    #expect(events.list.count == 3, "no second settle for the same text")
  }

  @Test("an untouched paste that is sent is not flushed: the last region equals the pasted text")
  func untouchedSendNoFlush() {
    start()
    scheduler.advance(ms: 750)
    ax.reads = [.text("")]
    scheduler.advance(ms: 750)
    #expect(events.list == [.ended(.textboxEmptied)])
  }

  @Test(
    "a send that leaves the composer's PLACEHOLDER (Discord) or a rewrite past the limit still flushes the fix typed before it; a field that stopped answering does not"
  )
  func placeholderAndRewriteFlushUnreadableDoesNot() {
    func run(_ read: PastedRegionValueRead, _ expected: PastedRegionEndReason, flushes: Bool) {
      let o = PastedRegionObserver(ax: ax, scheduler: scheduler)
      let e = Events()
      ax.reads = [.text("Note: Ask Sarah today please")]
      o.start(target) { e.list.append($0) }
      ax.reads = [.text("Note: Ask Saira today please")]
      scheduler.advance(ms: 750)
      ax.reads = [read]
      scheduler.advance(ms: 750)
      let want: [PastedRegionEvent] =
        flushes
        ? [.changed(region: "Ask Saira today"), .settled(region: "Ask Saira today"), .ended(expected)]
        : [.changed(region: "Ask Saira today"), .ended(expected)]
      #expect(e.list == want, "\(read)")
    }
    // Discord after Return: the box reads as its placeholder, not as "".
    run(.text("Message #general"), .regionRemoved, flushes: true)
    run(.text("Note: a completely rewritten sentence typed over the paste please"), .editDistanceExceeded, flushes: true)
    run(.text("Note: Ask Saira today please Note: x please"), .anchorAmbiguous, flushes: true)
    // Too long to read is a host that stopped answering usefully: nothing to act on.
    run(.text(String(repeating: "x", count: 20_001)), .captureUnsupported, flushes: false)
  }

  @Test(
    "a young edit is flushed by a send-shaped end (the box emptied 100 ms after the poll saw it) but not by an app switch that soon (the poll caught a half-typed word)"
  )
  func youngEditFlushDependsOnEndReason() throws {
    start()
    let registration = try #require(ax.registrations.first)
    ax.reads = [.text("Note: Ask Saira today please")]
    scheduler.advance(ms: 750)
    // The age is measured from the READ, and the person typed well before it:
    // a send 100 ms after the poll still delivers the fix.
    scheduler.jump(ms: 100)
    ax.reads = [.text("")]
    registration.fire(.valueChanged)
    #expect(
      events.list == [
        .changed(region: "Ask Saira today"), .settled(region: "Ask Saira today"),
        .ended(.textboxEmptied),
      ], "\(events.list)")

    // The measured partial-word path: the poll caught "S" and the app is
    // switched at once; nothing is flushed.
    let e2 = Events()
    let o2 = PastedRegionObserver(ax: ax, scheduler: scheduler)
    ax.reads = [.text("Note: Ask Sarah today please")]
    o2.start(target) { e2.list.append($0) }
    let r2 = try #require(ax.registrations.last)
    ax.reads = [.text("Note: Ask S today please")]
    scheduler.advance(ms: 750)
    #expect(e2.list == [.changed(region: "Ask S today")])
    scheduler.jump(ms: 100)
    ax.frontmost = 7
    r2.fire(.valueChanged)
    #expect(e2.list == [.changed(region: "Ask S today"), .ended(.focusChanged)], "\(e2.list)")

    // Control: the same app switch 500 ms after the read flushes the finished word.
    ax.frontmost = pid
    let e3 = Events()
    let o3 = PastedRegionObserver(ax: ax, scheduler: scheduler)
    ax.reads = [.text("Note: Ask Sarah today please")]
    o3.start(target) { e3.list.append($0) }
    let r3 = try #require(ax.registrations.last)
    ax.reads = [.text("Note: Ask Saira today please")]
    scheduler.advance(ms: 750)
    scheduler.jump(ms: 500)
    ax.frontmost = 7
    r3.fire(.valueChanged)
    #expect(
      e3.list == [
        .changed(region: "Ask Saira today"), .settled(region: "Ask Saira today"),
        .ended(.focusChanged),
      ], "\(e3.list)")
    #expect(PastedRegionEndReason.focusChanged.minimumPendingEditAgeMs == 500)
    #expect(PastedRegionEndReason.textboxEmptied.minimumPendingEditAgeMs == 0)
  }

  @Test(
    "an autocomplete popup (focus on another element of the same app) does not end the watch: the fix typed through it settles; focus that stays away for the grace ends it"
  )
  func popupFocusIsTolerated() {
    start()
    // The first letter is typed and the suggest widget takes focus.
    ax.reads = [.text("Note: Ask S today please")]
    scheduler.advance(ms: 750)
    ax.focused[pid] = .element(PastedRegionFakeAX.field(77))
    ax.reads = [.text("Note: Ask Saira today please")]
    scheduler.advance(ms: 750)
    #expect(events.list == [.changed(region: "Ask S today"), .changed(region: "Ask Saira today")])
    #expect(observer.isObserving, "focus away for 0 ms: tolerated")
    // Focus returns on the next keystroke; the text sits quiet; it settles.
    ax.focused[pid] = .element(PastedRegionFakeAX.field(pid))
    scheduler.advance(ms: 1500)
    #expect(events.list.last == .settled(region: "Ask Saira today"))
    #expect(observer.isObserving)
    // Now focus leaves for good: one grace interval later the watch ends.
    ax.focused[pid] = .element(PastedRegionFakeAX.field(77))
    scheduler.advance(ms: 1499)
    #expect(observer.isObserving, "1499 ms away is inside the grace")
    scheduler.advance(ms: 751)
    #expect(events.list.last == .ended(.focusChanged))
    #expect(observer.isObserving == false)
    #expect(PastedRegionTiming.focusGraceMs == 1500)
  }

  @Test("the flush set is closed: every end where the last good read still stands flushes; an unreadable field or a lost permission does not")
  func flushSetIsClosed() {
    let flushing = PastedRegionEndReason.allCases.filter(\.flushesPendingEdit)
    #expect(
      Set(flushing) == [
        .textboxEmptied, .focusChanged, .elementDestroyed, .appTerminated, .regionRemoved,
        .anchorAmbiguous, .editDistanceExceeded, .ceilingElapsed,
      ])
    #expect(!PastedRegionEndReason.captureUnsupported.flushesPendingEdit)
    #expect(!PastedRegionEndReason.permissionLost.flushesPendingEdit)
  }

  @Test("the ceiling flushes a fix typed just before it ran out")
  func ceilingFlushesPendingEdit() {
    start()
    scheduler.advance(ms: 58_500)
    #expect(events.list.isEmpty)
    ax.reads = [.text("Note: Ask Saira today please")]
    scheduler.advance(ms: 750)  // the poll at 59 250 sees the fix; its settle would be due at 60 750
    #expect(events.list == [.changed(region: "Ask Saira today")])
    scheduler.advance(ms: 750)  // the 60 000 ceiling comes first
    #expect(
      events.list == [
        .changed(region: "Ask Saira today"), .settled(region: "Ask Saira today"),
        .ended(.ceilingElapsed),
      ])
    #expect(observer.isObserving == false)
  }
}

// MARK: - Range reader (#3073)

/// Editors that expose text only through `AXStringForRange` (Excel in edit
/// mode is the measured candidate) are read through the parameterized
/// attribute when `AXValue` is absent; `AXValue` hosts are untouched.
@MainActor
@Suite(.tags(.productOutcome))
struct PastedRegionRangeReaderCaptureTests {
  let ax = PastedRegionFakeAX()
  let scheduler = PastedRegionFakeScheduler()
  var observer: PastedRegionObserver { PastedRegionObserver(ax: ax, scheduler: scheduler) }
  let pid: pid_t = 42
  let host = "Ask Sarah today"

  init() {
    ax.focused[pid] = .element(PastedRegionFakeAX.field(pid))
  }

  @Test("an AXValue host is captured through the value reader and the range reader is never consulted")
  func valueFirst() {
    ax.reads = [.text(host)]
    ax.counts = [.count(host.utf16.count)]
    ax.rangeReads = [.text(host)]
    guard case .captured(let target) = observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) else {
      Issue.record("expected captured")
      return
    }
    #expect(target.reader == .value)
    #expect(ax.countCalls == 0 && ax.rangeCalls.isEmpty)
  }

  @Test("no AXValue, a count and a range string of exactly that length: captured through the range reader with the unchanged anchors")
  func rangeFallback() {
    ax.reads = [.absent]
    ax.counts = [.count(host.utf16.count)]
    ax.rangeReads = [.text(host)]
    guard case .captured(let target) = observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) else {
      Issue.record("expected captured")
      return
    }
    #expect(target.reader == .range)
    #expect(target.anchors == PastedRegionAnchors(before: "Ask ", after: " today"))
    #expect(target.renderedText == "Sarah")
    #expect(ax.readCount == 1, "the value reader was asked once, first")
    #expect(ax.rangeCalls.map { [$0.location, $0.length] } == [[0, host.utf16.count]])
  }

  @Test("a non-string AXValue also falls through to the range reader")
  func notTextFallsThrough() {
    ax.reads = [.notText]
    ax.counts = [.count(host.utf16.count)]
    ax.rangeReads = [.text(host)]
    guard case .captured(let target) = observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) else {
      Issue.record("expected captured")
      return
    }
    #expect(target.reader == .range)
  }

  @Test("a failed AXValue read is the host not answering: no fallback, the failure's own end reason")
  func failedValueIsNotRetried() {
    ax.counts = [.count(host.utf16.count)]
    ax.rangeReads = [.text(host)]
    ax.reads = [.failed(.cannotComplete)]
    #expect(observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) == .ended(.captureUnsupported))
    ax.reads = [.failed(.apiDisabled)]
    #expect(observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) == .ended(.permissionLost))
    #expect(ax.countCalls == 0 && ax.rangeCalls.isEmpty)
  }

  @Test("a count above the ceiling refuses BEFORE any text is read; the ceiling itself is still readable")
  func ceilingBeforeTheRead() {
    ax.reads = [.absent]
    ax.counts = [.count(PastedRegionTiming.maxValueUTF16 + 1)]
    ax.rangeReads = [.text(host)]
    #expect(observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) == .ended(.captureUnsupported))
    #expect(ax.rangeCalls.isEmpty, "nothing above the ceiling is read into memory")
    let atCeiling = String(repeating: "x", count: PastedRegionTiming.maxValueUTF16 - host.utf16.count) + host
    ax.counts = [.count(PastedRegionTiming.maxValueUTF16)]
    ax.rangeReads = [.text(atCeiling)]
    guard case .captured(let target) = observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) else {
      Issue.record("expected captured at exactly the ceiling")
      return
    }
    #expect(target.reader == .range)
  }

  @Test("fail closed: a range string of any other length than the count, a non-number count, a non-string range answer, a negative count")
  func mismatchesAreAbsent() {
    ax.reads = [.absent]
    ax.counts = [.count(host.utf16.count)]
    ax.rangeReads = [.text(host + "!")]
    #expect(observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) == .ended(.captureUnsupported), "one unit too long")
    ax.rangeReads = [.text(String(host.dropLast()))]
    #expect(observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) == .ended(.captureUnsupported), "one unit too short")
    ax.rangeReads = [.notText]
    #expect(observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) == .ended(.captureUnsupported))
    ax.counts = [.absent]
    ax.rangeReads = [.text(host)]
    let before = ax.rangeCalls.count
    #expect(observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) == .ended(.captureUnsupported))
    #expect(ax.rangeCalls.count == before, "no count, no range read")
    ax.counts = [.count(-1)]
    #expect(observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) == .ended(.captureUnsupported))
    #expect(ax.rangeCalls.count == before)
  }

  @Test("a failed count or range call ends with the failure's own reason")
  func rangeFailures() {
    ax.reads = [.absent]
    ax.counts = [.failed(.cannotComplete)]
    #expect(observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) == .ended(.captureUnsupported))
    ax.counts = [.failed(.apiDisabled)]
    #expect(observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) == .ended(.permissionLost))
    ax.counts = [.count(host.utf16.count)]
    ax.rangeReads = [.failed(.notImplemented)]
    #expect(observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) == .ended(.permissionLost))
  }

  @Test("a count of zero is the empty text, not a refusal: the pasted text is simply not there yet")
  func zeroCount() {
    ax.reads = [.absent]
    ax.counts = [.count(0)]
    #expect(observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) == .ended(.dictatedTextNotFound))
    #expect(ax.rangeCalls.isEmpty, "an empty field is not read")
  }

  @Test("a count that changes across the range read is an unstable snapshot: retryable as dictated_text_not_found, never accepted as a prefix")
  func countChangesAcrossRead() {
    ax.reads = [.absent]
    let n = host.utf16.count
    ax.counts = [.count(n), .count(n + 1)]
    ax.rangeReads = [.text(host)]
    #expect(observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) == .ended(.dictatedTextNotFound))
    #expect(ax.countCalls == 2)
    // The same drift seen through a wrong-length string, or a range read that
    // failed because the range no longer existed: the differing second count
    // is what names the class.
    ax.counts = [.count(n), .count(n - 1)]
    ax.rangeReads = [.text(String(host.dropLast()))]
    #expect(observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) == .ended(.dictatedTextNotFound))
    ax.counts = [.count(n), .count(n - 1)]
    ax.rangeReads = [.failed(.cannotComplete)]
    #expect(observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) == .ended(.dictatedTextNotFound))
    // Under a STABLE count a wrong length is the host disagreeing with itself:
    // absent, final (mismatchesAreAbsent binds the rest of that row).
    ax.counts = [.count(n)]
    ax.rangeReads = [.text(String(host.dropLast()))]
    #expect(observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) == .ended(.captureUnsupported))
    ax.counts = [.count(n), .count(n + 5)]
    ax.rangeReads = [.text(host)]
    #expect(observer.readText(of: PastedRegionFakeAX.field(pid), using: .range) == .unstable)
  }

  @Test("readText is the one owner of the ceiling for both readers")
  func readTextCeiling() {
    let field = PastedRegionFakeAX.field(pid)
    ax.reads = [.text(String(repeating: "x", count: PastedRegionTiming.maxValueUTF16 + 1))]
    #expect(observer.readText(of: field, using: .value) == .tooLong)
    ax.counts = [.count(PastedRegionTiming.maxValueUTF16 + 1)]
    #expect(observer.readText(of: field, using: .range) == .tooLong)
    #expect(ax.rangeCalls.isEmpty)
    // A field that grows past the ceiling between the two counts is oversize, not merely mismatched.
    ax.counts = [.count(host.utf16.count), .count(PastedRegionTiming.maxValueUTF16 + 1)]
    ax.rangeReads = [.text(host)]
    #expect(observer.readText(of: field, using: .range) == .tooLong)
  }
}

/// A watch captured through the range reader keeps reading through it.
@MainActor
@Suite(.tags(.productOutcome))
struct PastedRegionRangeReaderWatchTests {
  let ax = PastedRegionFakeAX()
  let scheduler = PastedRegionFakeScheduler()
  let observer: PastedRegionObserver
  let pid: pid_t = 42
  let target: PastedRegionTarget
  final class Events {
    var list: [PastedRegionEvent] = []
  }
  let events = Events()
  static let host = "Note: Ask Sarah today please"

  init() throws {
    ax.focused[pid] = .element(PastedRegionFakeAX.field(pid))
    ax.reads = [.absent]
    ax.counts = [.count(Self.host.utf16.count)]
    ax.rangeReads = [.text(Self.host)]
    observer = PastedRegionObserver(ax: ax, scheduler: scheduler)
    guard case .captured(let t) = observer.capture(pid: pid, pastedText: "Ask Sarah today", pastedAtMs: 0) else {
      throw SetupError.capture
    }
    target = t
    ax.readCount = 0
    ax.countCalls = 0
    ax.rangeCalls = []
  }

  enum SetupError: Error { case capture }

  func start() {
    let events = events
    observer.start(target) { events.list.append($0) }
  }

  /// The fake answers the host's text through the range reader only.
  func host(_ text: String) {
    ax.counts = [.count(text.utf16.count)]
    ax.rangeReads = [.text(text)]
  }

  @Test("the poll reads through the range reader, never the value reader, and reports an edit then settles")
  func pollsThroughTheRangeReader() {
    #expect(target.reader == .range)
    start()
    scheduler.advance(ms: 750)
    #expect(ax.readCount == 0 && ax.countCalls == 2 && ax.rangeCalls.count == 1, "count, text, count again")
    #expect(events.list.isEmpty)
    host("Note: Ask Saira today please")
    scheduler.advance(ms: 750)
    #expect(events.list == [.changed(region: "Ask Saira today")])
    scheduler.advance(ms: 1500)
    #expect(events.list == [.changed(region: "Ask Saira today"), .settled(region: "Ask Saira today")])
    #expect(ax.readCount == 0, "the value reader was never consulted during the watch")
  }

  @Test("an emptied editor reads as textbox_emptied through the range reader (count zero, nothing read)")
  func emptiedThroughRange() {
    start()
    ax.counts = [.count(0)]
    ax.rangeReads = [.text("unreachable")]
    scheduler.advance(ms: 750)
    #expect(events.list == [.ended(.textboxEmptied)])
    #expect(ax.rangeCalls.isEmpty)
  }

  @Test("a range answer of the wrong length during the watch is a read failure, three in a row end the watch; growth past the ceiling ends it at once")
  func watchFailClosed() {
    start()
    ax.rangeReads = [.text(Self.host + "x")]
    scheduler.advance(ms: 750)
    scheduler.advance(ms: 750)
    #expect(events.list.isEmpty && observer.isObserving)
    scheduler.advance(ms: 750)
    #expect(events.list == [.ended(.captureUnsupported)], "three consecutive read failures")
  }

  @Test("a count past the ceiling during the watch ends it without reading")
  func watchCeiling() {
    start()
    let before = ax.rangeCalls.count
    ax.counts = [.count(PastedRegionTiming.maxValueUTF16 + 1)]
    scheduler.advance(ms: 750)
    #expect(events.list == [.ended(.captureUnsupported)])
    #expect(ax.rangeCalls.count == before)
  }

  @Test("three unstable watch snapshots follow the read-failure policy: a person mid-keystroke is not a lost field until it stays unreadable")
  func unstableDuringWatch() {
    start()
    let n = Self.host.utf16.count
    ax.counts = [.count(n), .count(n + 1), .count(n), .count(n + 1), .count(n), .count(n + 1)]
    ax.rangeReads = [.text(Self.host)]
    scheduler.advance(ms: 1500)
    #expect(events.list.isEmpty && observer.isObserving)
    scheduler.advance(ms: 750)
    #expect(events.list == [.ended(.captureUnsupported)])
  }

  @Test("the remaining range-watch failure rows follow the existing read-failure policy: absent count and a non-string range answer count three times, a failed count ends by its own code")
  func remainingFailureRows() {
    func run(_ counts: [PastedRegionCountRead], _ ranges: [PastedRegionValueRead], ticks: Int)
      -> [PastedRegionEvent]
    {
      let o = PastedRegionObserver(ax: ax, scheduler: scheduler)
      let e = Events()
      ax.counts = counts
      ax.rangeReads = ranges
      o.start(target) { e.list.append($0) }
      scheduler.advance(ms: 750 * ticks)
      o.stop()
      return e.list
    }
    #expect(run([.absent], [.text(Self.host)], ticks: 3) == [.ended(.captureUnsupported)])
    #expect(run([.failed(.cannotComplete)], [], ticks: 3) == [.ended(.captureUnsupported)])
    #expect(run([.failed(.apiDisabled)], [], ticks: 1) == [.ended(.permissionLost)])
    #expect(run([.count(Self.host.utf16.count)], [.notText], ticks: 3) == [.ended(.captureUnsupported)])
  }
}

@MainActor
@Suite(.tags(.productOutcome))
struct PastedRegionRangeReaderDeadlineTests {
  @Test("a deadline that passes during the read beats an emptied box: ceiling_elapsed, not textbox_emptied")
  func deadlineBeatsEmptiedDuringTheRead() throws {
    let ax = PastedRegionFakeAX()
    let scheduler = PastedRegionFakeScheduler()
    let pid: pid_t = 42
    ax.focused[pid] = .element(PastedRegionFakeAX.field(pid))
    ax.reads = [.absent]
    let host = "Note: Ask Sarah today please"
    ax.counts = [.count(host.utf16.count)]
    ax.rangeReads = [.text(host)]
    let observer = PastedRegionObserver(ax: ax, scheduler: scheduler)
    guard case .captured(let target) = observer.capture(pid: pid, pastedText: "Ask Sarah today", pastedAtMs: 0) else {
      Issue.record("expected captured")
      return
    }
    final class Events { var list: [PastedRegionEvent] = [] }
    let events = Events()
    observer.start(target) { events.list.append($0) }
    let registration = try #require(ax.registrations.first)
    // The editor is emptied, and the clock crosses the deadline while the
    // notification is being handled (one tick per clock read: entry, evaluate
    // entry, post-read).
    ax.counts = [.count(0)]
    scheduler.jump(ms: 60_000 - 2)
    scheduler.tickPerNowRead = 1
    registration.fire(.valueChanged)
    scheduler.tickPerNowRead = 0
    #expect(events.list == [.ended(.ceilingElapsed)], "\(events.list)")
  }
}
