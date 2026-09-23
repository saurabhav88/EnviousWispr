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
  /// Runs after each landing notification is added: lets a test spend time INSIDE the last call.
  var afterLandingNotification: ((PastedRegionAXNotification) -> Void)?

  static func app(_ pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }
  static func field(_ pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid + 10_000) }

  func isTrusted() -> Bool { trusted }
  func isProcessRunning(_ pid: pid_t) -> Bool { runningPIDs.contains(pid) }
  func applicationElement(pid: pid_t) -> AXUIElement { Self.app(pid) }
  /// Electron-shaped: a pid listed here answers `.noFocus` until
  /// `enableManualAccessibility` has SUCCEEDED for it.
  var focusOnlyAfterOptIn: Set<pid_t> = []
  private(set) var enabledPIDs: Set<pid_t> = []
  func focusedElement(pid: pid_t) -> PastedRegionFocus {
    if focusOnlyAfterOptIn.contains(pid), !enabledPIDs.contains(pid) { return .noFocus }
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
  /// pids whose attribute-name read fails (the answer is unreadable, not "no").
  var manualReadFails: Set<pid_t> = []
  /// Every manual-accessibility question, by pid, in order.
  var manualQueries: [pid_t] = []
  func supportsManualAccessibility(_ application: AXUIElement) -> Bool? {
    var pid: pid_t = 0
    AXUIElementGetPid(application, &pid)
    manualQueries.append(pid)
    if manualReadFails.contains(pid) { return nil }
    return manualHosts.contains(pid)
  }
  func enableManualAccessibility(_ application: AXUIElement) -> Bool {
    var pid: pid_t = 0
    AXUIElementGetPid(application, &pid)
    enableCalls.append(pid)
    if enableSucceeds { enabledPIDs.insert(pid) }
    return enableSucceeds
  }
  /// Answer for `selectedRange(of:)`; unavailable by default so every test
  /// written before cursor-aware settling keeps the quiet-only rule.
  var selectedRange: PastedRegionSelectedRange = .unavailable
  private(set) var selectedRangeReads = 0
  /// Runs on every caret read: tests use it to move the logical clock while
  /// the observer is "inside" the AX call.
  var onSelectedRangeRead: (() -> Void)?
  func selectedRange(of element: AXUIElement) -> PastedRegionSelectedRange {
    selectedRangeReads += 1
    onSelectedRangeRead?()
    return selectedRange
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

  // MARK: #3106 arrival-session reads. Defaults are FAILURES, never a successful read.

  /// Every arrival-session AX call in order, with the pid of the handle it messaged. Tests assert
  /// that nothing is called after the budget refuses.
  var landingCalls: [(call: String, pid: pid_t)] = []
  /// Runs before each arrival-session AX call: a test advances the clock here to model a slow host.
  var onLandingCall: ((String) -> Void)?
  var focusedByApplication: [pid_t: PastedRegionFocus] = [:]
  /// Window answers keyed by the pid of the handle asked (field handles are pid + 10_000).
  var windows: [pid_t: PastedRegionWindowRead] = [:]
  var focusedWindows: [pid_t: PastedRegionWindowRead] = [:]
  /// Notifications whose `AXObserverAddNotification` fails in `registerLanding`.
  var landingNotificationFailures: Set<PastedRegionAXNotification> = []
  var landingRegistrations: [PastedRegionFakeRegistration] = []
  /// Observers `registerLanding` created (the live `AXObserverCreate`).
  var landingObserversCreated = 0
  /// The owning pid each handle reports, keyed by the handle's own pid. Unscripted: a field handle
  /// (pid + 10_000) belongs to its application, any other handle to itself.
  var elementOwners: [pid_t: pid_t?] = [:]

  private func noteLanding(_ call: String, _ handle: AXUIElement) {
    var pid: pid_t = 0
    AXUIElementGetPid(handle, &pid)
    onLandingCall?(call)
    landingCalls.append((call, pid))
  }

  func focusedElement(ofApplication application: AXUIElement) -> PastedRegionFocus {
    noteLanding("focusedElement", application)
    var pid: pid_t = 0
    AXUIElementGetPid(application, &pid)
    return focusedByApplication[pid] ?? .queryFailed(.cannotComplete)
  }
  func pid(of element: AXUIElement) -> pid_t? {
    noteLanding("pid", element)
    var handle: pid_t = 0
    AXUIElementGetPid(element, &handle)
    if let scripted = elementOwners[handle] { return scripted }
    return handle >= 10_000 ? handle - 10_000 : handle
  }
  func window(of element: AXUIElement) -> PastedRegionWindowRead {
    noteLanding("window", element)
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    return windows[pid] ?? .failed(.cannotComplete)
  }
  func focusedWindow(of application: AXUIElement) -> PastedRegionWindowRead {
    noteLanding("focusedWindow", application)
    var pid: pid_t = 0
    AXUIElementGetPid(application, &pid)
    return focusedWindows[pid] ?? .failed(.cannotComplete)
  }
  func registerLanding(
    pid: pid_t, element: AXUIElement?, application: AXUIElement,
    admit: @MainActor (AXUIElement) -> Bool,
    handler: @escaping @MainActor (PastedRegionAXNotification) -> Void
  ) -> (any PastedRegionAXRegistration)? {
    // The live order: the budget before the observer exists, then value-changed and destroyed on
    // the element, then focus on the application.
    guard admit(application) else { return nil }
    guard !registrationFails else { return nil }
    landingObserversCreated += 1
    var wanted: [(AXUIElement, PastedRegionAXNotification)] = []
    if let element {
      wanted.append((element, .valueChanged))
      wanted.append((element, .elementDestroyed))
    }
    wanted.append((application, .focusedElementChanged))
    var registered: Set<PastedRegionAXNotification> = []
    for (target, kind) in wanted {
      guard admit(target) else { break }
      noteLanding("add:\(kind)", target)
      afterLandingNotification?(kind)
      if !landingNotificationFailures.contains(kind) { registered.insert(kind) }
    }
    guard !registered.isEmpty else { return nil }
    let registration = PastedRegionFakeRegistration(handler: handler, registered: registered)
    landingRegistrations.append(registration)
    return registration
  }
}

@MainActor
final class PastedRegionFakeRegistration: PastedRegionAXRegistration {
  let handler: @MainActor (PastedRegionAXNotification) -> Void
  /// Empty by default: a fake never claims a complete registration it was not scripted to have.
  let registeredNotifications: Set<PastedRegionAXNotification>
  private(set) var invalidated = 0
  init(
    handler: @escaping @MainActor (PastedRegionAXNotification) -> Void,
    registered: Set<PastedRegionAXNotification> = []
  ) {
    self.handler = handler
    self.registeredNotifications = registered
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

  /// The terminal screen the founder dictates into: an agent CLI input box
  /// drawn between two rules of one repeated glyph. Rows carry no trailing
  /// padding, which is what Ghostty's `AXTextArea` value reports.
  static func terminalScreen(input: String) -> String {
    let rule = String(repeating: "\u{2500}", count: 68)
    return "\u{23FA} An earlier answer from the agent.\n\n"
      + rule + "\n"
      + "\u{276F}\u{00A0}" + input + "\n"
      + rule + "\n"
      + "  auto mode on"
  }

  @Test(
    "#3100 Ghostty: a dictation's trailing space must not carry the region past the row's line break and onto the drawn rule under the CLI input box"
  )
  func terminalTrailingSpaceStopsAtTheEndOfTheWords() {
    // The dictation carries a trailing space; the terminal row does not.
    let pasted = "I just got access to Quen on my laptop. "
    let words = "I just got access to Quen on my laptop."
    let screen = Self.terminalScreen(input: words)
    guard case .unique(let start, let end) = L.locate(pasted: pasted, in: screen) else {
      Issue.record("the pasted text must locate once in the screen")
      return
    }
    let units = Array(screen.utf16)
    // The region stops at the last word, so the line break is still ahead of it.
    #expect(String(decoding: units[start..<end], as: UTF16.self) == words)
    #expect(units[end] == 0x000A)
    let anchors = L.anchors(around: start, end: end, in: screen)
    // The landmark below the region now starts with the row break, so it is not
    // a slice of the rule and it occurs exactly once. (On the founder's screen
    // the probe counted four hits of the old rule-only landmark, so the run it
    // sliced was 67 effective units, not the 68 drawn here.)
    #expect(anchors.after.hasPrefix("\n"))
    #expect(Set(anchors.after.unicodeScalars.map(\.value)).count > 1)
    #expect(L.locateRegion(in: screen, anchors: anchors) == .located(.init(text: words, start: start, end: end)))
    #expect(L.ambiguityReport(in: screen, anchors: anchors) == nil)
  }

  @Test(
    "#3100 only the line break stops the region: a trailing space still takes a host's whole run of ordinary spaces"
  )
  func trailingSpaceStopsOnlyAtALineBreak() {
    // Padding inside the same row stays in the region.
    #expect(L.locate(pasted: "a ", in: "a   ") == .unique(start: 0, end: 4))
    // A row that IS padded before it breaks stops at the break, not after it.
    #expect(L.locate(pasted: "a ", in: "a   \nb") == .unique(start: 0, end: 4))
    // An inner space still crosses a wrap, which is what locates a wrapped paste.
    #expect(L.locate(pasted: "a b", in: "a\n  b") == .unique(start: 0, end: 5))
    // A whitespace-only paste meeting a run that BEGINS with the break keeps the
    // consumed end: clamping there would report a region of nothing.
    #expect(L.locate(pasted: "  ", in: "\r\n  x") == .unique(start: 0, end: 4))
    // The whole trailing run must still be CONSUMED before the end is reported
    // at the break. An implementation that stopped consuming at the break would
    // fall through to the trimmed retry and find the lone "a" twice.
    #expect(L.locate(pasted: "a  ", in: "a\n a and a") == .unique(start: 0, end: 1))
  }

  @Test(
    "#3100 a landmark that vanished is reported by side and shape, with no text in the report"
  )
  func missingAnchorIsReportedBySideAndShape() throws {
    let after = String(repeating: "\u{2500}", count: 64)
    let value = "prefix words\n" + String(repeating: "\u{2500}", count: 63)
    let report = try #require(
      L.missingAnchorReport(
        in: value, anchors: PastedRegionAnchors(before: "prefix ", after: after)))
    #expect(report.side == "after")
    #expect(report.hits == 0)
    #expect(report.needleUTF16 == 64)
    #expect(report.distinctUnits == 1)
    #expect(report.longestRun == 64)
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

  // MARK: Occurrence counting (#3106 PR A)

  /// `[start, end)` pairs of a complete count, or nil when the count is incomplete. Expected
  /// offsets below are literal UTF-16 positions worked out by hand, never produced by the
  /// enumerator.
  private func spans(_ result: L.Occurrences) -> [[Int]]? {
    guard case .complete(let hits) = result else { return nil }
    return hits.map { [$0.start, $0.end] }
  }

  @Test("an identical chunk pasted twice counts twice")
  func occurrencesCountAnIdenticalRepeat() {
    #expect(spans(L.occurrences(ofPasted: "thanks ", in: "thanks ")) == [[0, 7]])
    #expect(spans(L.occurrences(ofPasted: "thanks ", in: "thanks thanks ")) == [[0, 7], [7, 14]])
  }

  @Test("a phrase already earlier in the field counts with the new one")
  func occurrencesCountAnEarlierPhrase() {
    // "Please " 0-6, "Send it " 7-14, "now. " 15-19, "Send it " 20-27.
    #expect(
      spans(L.occurrences(ofPasted: "Send it ", in: "Please Send it now. Send it "))
        == [[7, 15], [20, 28]])
  }

  @Test("one full and one trailing-space-omitted rendering both count; locate keeps its full match")
  func occurrencesCountMixedRenderings() {
    // At 0 the full "Saira " matches; at 10 only "Saira" fits (the field ends there).
    #expect(spans(L.occurrences(ofPasted: "Saira ", in: "Saira and Saira")) == [[0, 6], [10, 15]])
    // Characterization: `locate` still tries the omitted form only when the full form is absent
    // everywhere, so it reports the one full match as unique (#996's exact-first rule).
    #expect(L.locate(pasted: "Saira ", in: "Saira and Saira") == .unique(start: 0, end: 6))
  }

  @Test("one occurrence rendered with its trailing space counts once, not once per form")
  func occurrencesCountOnePositionOnce() {
    #expect(spans(L.occurrences(ofPasted: "Saira ", in: "Ask Saira today")) == [[4, 10]])
  }

  @Test("host space variants, a terminal wrap and a preceding emoji keep the value's offsets")
  func occurrencesKeepTheValuesOffsets() {
    #expect(spans(L.occurrences(ofPasted: "hi there", in: "hi\u{00A0}there")) == [[0, 8]])
    // The needle's one space meets the host's "\n  " run of three units.
    #expect(spans(L.occurrences(ofPasted: "one two", in: "one\n  two")) == [[0, 9]])
    // U+1F600 is two UTF-16 units, then a space: "Saira" starts at 3.
    #expect(spans(L.occurrences(ofPasted: "Saira", in: "\u{1F600} Saira")) == [[3, 8]])
  }

  @Test("empty text, and a trim that leaves nothing, invent no match")
  func occurrencesInventNothing() {
    #expect(spans(L.occurrences(ofPasted: "", in: "anything")) == [])
    #expect(spans(L.occurrences(ofPasted: "Saira", in: "Ask Sarah today")) == [])
    #expect(spans(L.occurrences(ofPasted: " ", in: "ab")) == [])
  }

  @Test("an oversized value or a spent work budget is incomplete, never a partial count")
  func occurrencesRefuseRatherThanUndercount() {
    let oversized = String(repeating: "a", count: PastedRegionTiming.maxValueUTF16 + 1)
    #expect(L.occurrences(ofPasted: "a", in: oversized) == .incomplete(.tooLong))
    #expect(L.occurrences(ofPasted: "aaab", in: "aaaaaaaaaaaaaaaa", workBudget: 10) == .incomplete(.workBudget))
    // Near the size limit, a value that repeats a long prefix of the text costs about
    // 19,900 starts x 101 units, past the default budget: the count refuses instead of running on.
    let repeated = String(repeating: "a", count: PastedRegionTiming.maxValueUTF16 - 1) + "b"
    let needle = String(repeating: "a", count: 100) + "c"
    #expect(L.occurrences(ofPasted: needle, in: repeated) == .incomplete(.workBudget))
    // Every unit the matcher walks is charged, including a long space run in the TEXT: about
    // 100 starts x 53 units here, past a 1,000 budget (uncharged, it cost about 300 and answered).
    let spaced = String(repeating: "a ", count: 100)
    let wide = "a" + String(repeating: " ", count: 50) + "b"
    #expect(L.occurrences(ofPasted: wide, in: spaced, workBudget: 1_000) == .incomplete(.workBudget))
    let oversizedText = String(repeating: "b", count: PastedRegionTiming.maxValueUTF16 + 1)
    #expect(L.occurrences(ofPasted: oversizedText, in: "b") == .incomplete(.tooLong))
    #expect(L.occurrences(ofPasted: "a", in: "a", workBudget: -1) == .incomplete(.workBudget))
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

  // MARK: The typed arrival attempt (#3106 PR A)

  /// `[start, end)` pairs of a readable attempt's complete count; nil for anything else.
  private func spans(_ attempt: PastedRegionArrivalAttempt) -> [[Int]]? {
    guard case .readable(let field) = attempt, case .complete(let hits) = field.occurrences else {
      return nil
    }
    return hits.map { [$0.start, $0.end] }
  }

  @Test("a stable read without the text keeps its field, reader and value: a zero count, not a refusal")
  func arrivalZeroHitsKeepTheField() throws {
    let attempt = observer.attemptArrival(pid: pid, pastedText: "Saira")
    guard case .readable(let field) = attempt else {
      Issue.record("expected a readable field, got \(attempt)")
      return
    }
    #expect(CFEqual(field.element, PastedRegionFakeAX.field(pid)))
    #expect(CFEqual(field.application, PastedRegionFakeAX.app(pid)))
    #expect(field.reader == .value)
    #expect(field.value == "Ask Sarah today")
    #expect(field.occurrences == .complete([]))
    // The legacy capture of the same read is the collapsed cause #996 retries.
    #expect(observer.capture(pid: pid, pastedText: "Saira", pastedAtMs: 0) == .ended(.dictatedTextNotFound))
  }

  @Test("a repeated phrase is a readable field with every position; the legacy capture still calls it ambiguous")
  func arrivalCountsARepeat() {
    ax.reads = [.text("Sarah met Sarah")]
    #expect(spans(observer.attemptArrival(pid: pid, pastedText: "Sarah")) == [[0, 5], [10, 15]])
    #expect(observer.capture(pid: pid, pastedText: "Sarah", pastedAtMs: 0) == .ended(.anchorAmbiguous))
  }

  @Test("the attempt never writes AXManualAccessibility, and an unreadable support answer stays unknown")
  func arrivalNeverOptsIn() {
    ax.manualHosts = [pid]
    guard case .readable(let host) = observer.attemptArrival(pid: pid, pastedText: "Sarah") else {
      Issue.record("expected a readable field")
      return
    }
    #expect(host.manualAccessibility == true)
    #expect(ax.enableCalls == [], "the arrival session opts in once after dispatch, never per attempt")
    ax.manualReadFails = [pid]
    guard case .readable(let unknown) = observer.attemptArrival(pid: pid, pastedText: "Sarah") else {
      Issue.record("expected a readable field")
      return
    }
    #expect(unknown.manualAccessibility == nil, "could not read is not 'does not support it'")
  }

  @Test("refusals keep their cause and read nothing: permission, focus, frontmost, bound, secure, failed query")
  func arrivalRefusalsKeepTheirCause() {
    ax.trusted = false
    guard case .permissionLost = observer.attemptArrival(pid: pid, pastedText: "Sarah") else {
      Issue.record("expected permissionLost")
      return
    }
    ax.trusted = true
    guard case .appTerminated = observer.attemptArrival(pid: 7, pastedText: "Sarah") else {
      Issue.record("expected appTerminated")
      return
    }
    ax.frontmost = 7
    guard case .destinationMismatch = observer.attemptArrival(pid: pid, pastedText: "Sarah") else {
      Issue.record("expected destinationMismatch")
      return
    }
    ax.frontmost = pid
    ax.timeoutFailsFor = [pid + 10_000]
    guard case .unsupported(.timeoutNotInstalled) = observer.attemptArrival(pid: pid, pastedText: "Sarah") else {
      Issue.record("expected unsupported(timeoutNotInstalled)")
      return
    }
    ax.timeoutFailsFor = []
    ax.subroles["\(CFHash(PastedRegionFakeAX.field(pid)))"] = .subrole(kAXSecureTextFieldSubrole as String)
    guard case .secureField = observer.attemptArrival(pid: pid, pastedText: "Sarah") else {
      Issue.record("expected secureField")
      return
    }
    ax.subroles = [:]
    ax.focused[pid] = .noFocus
    guard case .noFocus = observer.attemptArrival(pid: pid, pastedText: "Sarah") else {
      Issue.record("expected noFocus")
      return
    }
    ax.focused[pid] = .queryFailed(.cannotComplete)
    guard case .queryFailed(.cannotComplete) = observer.attemptArrival(pid: pid, pastedText: "Sarah") else {
      Issue.record("expected queryFailed(cannotComplete)")
      return
    }
    #expect(ax.readCount == 0, "nothing was read behind any refusal")
  }

  @Test("an over-limit value is unsupported, not a zero count")
  func arrivalTooLongIsUnsupported() {
    ax.reads = [.text(String(repeating: "x", count: 20_001))]
    guard case .unsupported(.tooLong) = observer.attemptArrival(pid: pid, pastedText: "x") else {
      Issue.record("expected unsupported(tooLong)")
      return
    }
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
    var lines: [String] = []
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

  @Test(
    "#3100 a terminal-shaped capture survives its first poll: a word fixed inside an agent CLI input box is reported and settles"
  )
  func terminalCorrectionSurvivesTheRuleBelowTheInput() throws {
    let terminalAX = PastedRegionFakeAX()
    let terminalScheduler = PastedRegionFakeScheduler()
    let original = "I just got access to Quen on my laptop."
    let corrected = "I just got access to Qwen on my laptop."
    terminalAX.focused[pid] = .element(PastedRegionFakeAX.field(pid))
    terminalAX.reads = [.text(PastedRegionLocatorTests.terminalScreen(input: original))]
    let terminalObserver = PastedRegionObserver(ax: terminalAX, scheduler: terminalScheduler)
    // The dictation carries the trailing space the terminal never renders.
    guard
      case .captured(let terminalTarget) = terminalObserver.capture(
        pid: pid, pastedText: original + " ", pastedAtMs: 0)
    else {
      throw TestSetupError.capture
    }
    #expect(terminalTarget.renderedText == original)
    #expect(terminalTarget.anchors.after.hasPrefix("\n"))

    let seen = Events()
    terminalObserver.start(terminalTarget) { seen.list.append($0) }
    terminalAX.reads = [.text(PastedRegionLocatorTests.terminalScreen(input: corrected))]
    terminalScheduler.advance(ms: 750)
    #expect(seen.list == [.changed(region: corrected)])
    terminalScheduler.advance(ms: 750)
    terminalScheduler.advance(ms: 750)
    #expect(seen.list == [.changed(region: corrected), .settled(region: corrected)])
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
    "a box that stops answering right after a good read saw the fix flushes that fix (a send in another shape); the same three failures with no fix seen flush nothing"
  )
  func lostBoxAfterSeenFixFlushes() {
    // WhatsApp 2026-09-21: fix typed, Return pressed inside the settle window,
    // the old composer element answered nothing three times. Every failure
    // kind the poll can record is a lost box, except `unstable` (next test).
    let runs: [[PastedRegionValueRead]] = [
      [.failed(.cannotComplete), .failed(.cannotComplete), .failed(.cannotComplete)],
      [.failed(.invalidUIElement), .absent, .notText],
      [.absent, .absent, .absent],
    ]
    for run in runs {
      let o = PastedRegionObserver(ax: ax, scheduler: scheduler)
      let e = Events()
      ax.reads = [.text("Note: Ask Sarah today please")]
      o.start(target) { e.list.append($0) }
      ax.reads = [.text("Note: Ask Saira today please")]
      scheduler.advance(ms: 750)
      ax.reads = run
      scheduler.advance(ms: 750 * 3)
      #expect(
        e.list == [.changed(region: "Ask Saira today"), .settled(region: "Ask Saira today"), .ended(.captureUnsupported)],
        "\(run)")
    }
    // No fix seen before the box went away: nothing to act on.
    let o = PastedRegionObserver(ax: ax, scheduler: scheduler)
    let e = Events()
    ax.reads = [.text("Note: Ask Sarah today please")]
    o.start(target) { e.list.append($0) }
    scheduler.advance(ms: 750)
    ax.reads = [.absent, .absent, .absent]
    scheduler.advance(ms: 750 * 3)
    #expect(e.list == [.ended(.captureUnsupported)])
  }

  @Test(
    "an unstable read (a person still typing) or a failed focus query (the element was never read) in the failure run withholds the lost-box flush"
  )
  func lostBoxWithUnstableOrFocusFailureDoesNotFlush() {
    let o = PastedRegionObserver(ax: ax, scheduler: scheduler)
    let e = Events()
    ax.reads = [.text("Note: Ask Sarah today please")]
    o.start(target) { e.list.append($0) }
    ax.reads = [.text("Note: Ask Saira today please")]
    scheduler.advance(ms: 750)
    ax.reads = [.absent, .unstable, .absent]
    scheduler.advance(ms: 750 * 3)
    #expect(e.list == [.changed(region: "Ask Saira today"), .ended(.captureUnsupported)])

    // Three failed focus queries: the box may be fine; nothing was read.
    let o2 = PastedRegionObserver(ax: ax, scheduler: scheduler)
    let e2 = Events()
    ax.reads = [.text("Note: Ask Sarah today please")]
    o2.start(target) { e2.list.append($0) }
    ax.reads = [.text("Note: Ask Saira today please")]
    scheduler.advance(ms: 750)
    ax.focused[pid] = .queryFailed(.cannotComplete)
    scheduler.advance(ms: 750 * 3)
    ax.focused[pid] = .element(PastedRegionFakeAX.field(pid))
    #expect(e2.list == [.changed(region: "Ask Saira today"), .ended(.captureUnsupported)])
  }

  @Test("the diagnostic log names each failed read's kind and the lost-box verdict, never the text")
  func lostBoxLogLines() {
    let lines = Events()
    let o = PastedRegionObserver(ax: ax, scheduler: scheduler, log: { lines.lines.append($0) })
    let e = Events()
    ax.reads = [.text("Note: Ask Sarah today please")]
    o.start(target) { e.list.append($0) }
    ax.reads = [.text("Note: Ask Saira today please")]
    scheduler.advance(ms: 750)
    ax.reads = [.failed(.cannotComplete), .absent, .notText]
    scheduler.advance(ms: 750 * 3)
    #expect(lines.lines.count == 5)
    #expect(lines.lines[0] == "learn_read_changed source=poll")
    #expect(lines.lines[1] == "learn_read_failed n=1/3 kind=failed(\(AXError.cannotComplete.rawValue)) pending_fix=true")
    #expect(lines.lines[2] == "learn_read_failed n=2/3 kind=absent pending_fix=true")
    #expect(lines.lines[3] == "learn_read_failed n=3/3 kind=notText pending_fix=true")
    #expect(lines.lines[4] == "learn_lost_box reason=capture_unsupported flushed=true reads=failed(\(AXError.cannotComplete.rawValue)),absent,notText")
    #expect(lines.lines.allSatisfy { !$0.contains("Saira") && !$0.contains("Sarah") })
  }

  @Test("lost-box recovery requires 500 ms of quiet and never derives from a focus-query failure")
  func lostBoxRequiresQuietReadableEvidence() throws {
    // Three notification-driven failures 0 ms after the poll saw the fix:
    // younger than `flushMinQuietMs`, so no flush.
    let o = PastedRegionObserver(ax: ax, scheduler: scheduler)
    let e = Events()
    ax.reads = [.text("Note: Ask Sarah today please")]
    o.start(target) { e.list.append($0) }
    let registration = try #require(ax.registrations.last)
    ax.reads = [.text("Note: Ask Saira today please")]
    registration.fire(.valueChanged)
    ax.reads = [.failed(.cannotComplete), .failed(.cannotComplete), .failed(.cannotComplete)]
    registration.fire(.valueChanged)
    registration.fire(.valueChanged)
    registration.fire(.valueChanged)
    #expect(e.list == [.changed(region: "Ask Saira today"), .ended(.captureUnsupported)])

    // The same three failures 500 ms after the fix was seen: flushed.
    let o2 = PastedRegionObserver(ax: ax, scheduler: scheduler)
    let e2 = Events()
    ax.reads = [.text("Note: Ask Sarah today please")]
    o2.start(target) { e2.list.append($0) }
    let registration2 = try #require(ax.registrations.last)
    ax.reads = [.text("Note: Ask Saira today please")]
    registration2.fire(.valueChanged)
    scheduler.jump(ms: PastedRegionTiming.flushMinQuietMs)
    ax.reads = [.failed(.cannotComplete), .failed(.cannotComplete), .failed(.cannotComplete)]
    registration2.fire(.valueChanged)
    registration2.fire(.valueChanged)
    registration2.fire(.valueChanged)
    #expect(
      e2.list == [
        .changed(region: "Ask Saira today"), .settled(region: "Ask Saira today"), .ended(.captureUnsupported),
      ])
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
    // `focusGraceMs` (an autocomplete popup); the element is still read. The
    // quiet interval fires but cursor-aware settling cannot read a caret on
    // the watched element while focus is on the popup, so it WAITS (Codex
    // r30) rather than settling a word the popup may still be completing.
    #expect(e2.list == [.changed(region: "Ask Saira today")])
    #expect(o2.isObserving)
    // Focus that stays away for the whole grace ends the watch, flushing the
    // fix it was waiting on.
    scheduler.advance(ms: 1500)
    #expect(
      e2.list == [
        .changed(region: "Ask Saira today"), .settled(region: "Ask Saira today"), .ended(.focusChanged),
      ])
    #expect(o2.isObserving == false)
  }

  // MARK: Cursor-aware settling (#996, founder UAT 2026-09-21, Codex r30)
  //
  // Field "Note: Ask Sarah today please": the region "Ask Sarah today" starts
  // at UTF-16 offset 6. After the fix "Ask Saira today", the changed envelope
  // is "ira" at region offsets 6..<9, absolute 12..<15. A caret at 12...15 is
  // inside or immediately after it; 16 (after the space) and 3 are outside.

  private func startWithFix(_ o: PastedRegionObserver, _ e: Events) {
    ax.reads = [.text("Note: Ask Sarah today please")]
    o.start(target) { e.list.append($0) }
    ax.reads = [.text("Note: Ask Saira today please")]
    scheduler.advance(ms: 750)
    #expect(e.list == [.changed(region: "Ask Saira today")])
  }

  @Test("the changed envelope is the span between the common prefix and suffix, in UTF-16 units of the region")
  func changedEnvelope() {
    #expect(PastedRegionLocator.changedEnvelope(pasted: "Ask Sarah today", region: "Ask Saira today") == 6..<9)
    #expect(PastedRegionLocator.changedEnvelope(pasted: "Ask Sarah today", region: "Ask Sarah today") == 15..<15)
    // Two separate edits become one envelope from the first to the last.
    #expect(PastedRegionLocator.changedEnvelope(pasted: "Ask Sarah today", region: "Asx Sarah todxy") == 2..<14)
    // Appended text: the envelope is the tail.
    #expect(PastedRegionLocator.changedEnvelope(pasted: "Ask Sarah", region: "Ask Sarahs") == 9..<10)
    // Deleted text: an empty envelope at the cut.
    #expect(PastedRegionLocator.changedEnvelope(pasted: "Ask Sarah today", region: "Ask today") == 4..<4)
    // Never inside a surrogate pair: two emoji sharing a lead unit.
    #expect(
      PastedRegionLocator.changedEnvelope(pasted: "X😀Y", region: "X😁Y") == 1..<3,
      "the envelope includes the complete changed scalar")
  }

  @Test("the same changed region at a new absolute offset (text inserted before the anchor) keeps deferring at the new span end")
  func movedRegionKeepsDeferring() {
    let o = PastedRegionObserver(ax: ax, scheduler: scheduler)
    let e = Events()
    startWithFix(o, e)
    ax.selectedRange = .range(location: 15, length: 0)
    scheduler.advance(ms: 1500)
    #expect(e.list.count == 1)
    // "PS " typed before the note: the unchanged region moves right by 3.
    ax.reads = [.text("PS Note: Ask Saira today please")]
    ax.selectedRange = .range(location: 18, length: 0)  // still right after "Saira"
    scheduler.advance(ms: 1500)
    #expect(e.list.count == 1, "stale coordinates would read 18 as outside 12...15 and settle")
    ax.selectedRange = .range(location: 8, length: 0)  // in "PS Note:", outside the moved span 15...18
    scheduler.advance(ms: 1500)
    #expect(e.list.last == .settled(region: "Ask Saira today"))
  }

  @Test("the cap or the ceiling crossed inside the caret read is honoured before any settle or re-arm")
  func deadlineCrossedInsideCaretRead() {
    // Cap: the clock jumps past the cap deadline during the caret read.
    let lines = Events()
    let o = PastedRegionObserver(ax: ax, scheduler: scheduler, log: { lines.lines.append($0) })
    let e = Events()
    startWithFix(o, e)
    ax.selectedRange = .range(location: 15, length: 0)
    scheduler.advance(ms: 1500)  // first deferral: deadline now + 10 s
    ax.onSelectedRangeRead = { [scheduler] in scheduler.jump(ms: PastedRegionTiming.caretCapMs) }
    scheduler.advance(ms: 1500)
    #expect(e.list.last == .settled(region: "Ask Saira today"))
    #expect(lines.lines.contains("learn_settle trigger=cap"))
    ax.onSelectedRangeRead = nil
    o.stop()

    // Ceiling: the clock crosses the 60 s ceiling during the caret read.
    let o2 = PastedRegionObserver(ax: ax, scheduler: scheduler)
    let e2 = Events()
    ax.reads = [.text("Note: Ask Sarah today please")]
    // A target captured NOW, so the 60 s ceiling is measured from here.
    guard case .captured(let fresh) = o2.capture(pid: pid, pastedText: "Ask Sarah today", pastedAtMs: scheduler.nowMs)
    else {
      Issue.record("fixture capture failed")
      return
    }
    o2.start(fresh) { e2.list.append($0) }
    ax.reads = [.text("Note: Ask Saira today please")]
    scheduler.advance(ms: 750)
    ax.onSelectedRangeRead = { [scheduler] in scheduler.jump(ms: PastedRegionTiming.ceilingMs) }
    scheduler.advance(ms: 1500)
    ax.onSelectedRangeRead = nil
    #expect(
      e2.list == [
        .changed(region: "Ask Saira today"), .settled(region: "Ask Saira today"), .ended(.ceilingElapsed),
      ], "the ceiling flushes the pending fix and ends; no re-arm")
    #expect(o2.isObserving == false)
  }

  @Test("the locator retains the region's absolute UTF-16 offsets")
  func locateRegionOffsets() {
    let anchors = PastedRegionAnchors(before: "Note: ", after: " please")
    #expect(
      PastedRegionLocator.locateRegion(in: "Note: Ask Saira today please", anchors: anchors)
        == .located(.init(text: "Ask Saira today", start: 6, end: 21)))
    #expect(PastedRegionLocator.locateRegion(in: "Message #general", anchors: anchors) == .lost)
  }

  @Test("a caret inside or immediately after the changed span defers settling; a caret outside settles at the next quiet check")
  func caretInsideSpanDefers() {
    let lines = Events()
    let o = PastedRegionObserver(ax: ax, scheduler: scheduler, log: { lines.lines.append($0) })
    let e = Events()
    startWithFix(o, e)
    ax.selectedRange = .range(location: 15, length: 0)  // right after "Saira"
    scheduler.advance(ms: 1500)
    #expect(e.list == [.changed(region: "Ask Saira today")], "caret still on the word: wait")
    #expect(o.isObserving)
    ax.selectedRange = .range(location: 12, length: 0)  // inside the span
    scheduler.advance(ms: 1500)
    #expect(e.list.count == 1)
    ax.selectedRange = .range(location: 16, length: 0)  // after the space: moved on
    scheduler.advance(ms: 1500)
    #expect(e.list == [.changed(region: "Ask Saira today"), .settled(region: "Ask Saira today")])
    #expect(lines.lines.contains("learn_settle trigger=caretLeft"))
    #expect(ax.selectedRangeReads == 3, "one caret read per quiet check")
  }

  @Test("a selection overlapping the changed span defers; a selection elsewhere settles")
  func selectionOverSpanDefers() {
    let o = PastedRegionObserver(ax: ax, scheduler: scheduler)
    let e = Events()
    startWithFix(o, e)
    ax.selectedRange = .range(location: 10, length: 5)  // "Saira" selected
    scheduler.advance(ms: 1500)
    #expect(e.list.count == 1)
    ax.selectedRange = .range(location: 0, length: 4)  // "Note" selected
    scheduler.advance(ms: 1500)
    #expect(e.list.last == .settled(region: "Ask Saira today"))
  }

  @Test("an unavailable, malformed or unreadable caret falls back to today's quiet-only settling")
  func caretFallbacks() {
    for answer in [
      PastedRegionSelectedRange.unavailable, .range(location: -1, length: 0), .range(location: 3, length: -2),
      .range(location: 10_000, length: 0), .range(location: Int.max, length: 1),
    ] {
      let lines = Events()
      let o = PastedRegionObserver(ax: ax, scheduler: scheduler, log: { lines.lines.append($0) })
      let e = Events()
      startWithFix(o, e)
      ax.selectedRange = answer
      scheduler.advance(ms: 1500)
      #expect(e.list.last == .settled(region: "Ask Saira today"), "\(answer)")
      #expect(lines.lines.contains("learn_settle trigger=fallbackQuiet"), "\(answer)")
    }
  }

  @Test("the cap: ten seconds after the first deferral of a revision, the region settles with the caret still inside; a new revision starts a new cap")
  func caretCapIsAbsolutePerRevision() {
    let lines = Events()
    let o = PastedRegionObserver(ax: ax, scheduler: scheduler, log: { lines.lines.append($0) })
    let e = Events()
    startWithFix(o, e)
    ax.selectedRange = .range(location: 15, length: 0)
    // First deferral at 2250 (poll 750 + settle 1500): deadline 12250.
    scheduler.advance(ms: 1500)
    #expect(e.list.count == 1)
    scheduler.advance(ms: 12000 - 2250)  // now 12000: quiet checks at 3750 ... 11250 all deferred
    #expect(e.list.count == 1, "deadline not reached at 12000")
    scheduler.advance(ms: 750)  // 12750: the check at 12750 sees the deadline passed
    #expect(e.list == [.changed(region: "Ask Saira today"), .settled(region: "Ask Saira today")])
    #expect(lines.lines.contains("learn_settle trigger=cap"))
    o.stop()

    // A new revision after a long deferral resets the cap.
    let o2 = PastedRegionObserver(ax: ax, scheduler: scheduler)
    let e2 = Events()
    startWithFix(o2, e2)
    scheduler.advance(ms: 1500)  // deferral 1 at t+2250
    scheduler.advance(ms: 6000)  // still deferred
    #expect(e2.list.count == 1)
    ax.reads = [.text("Note: Ask Sairah today please")]  // keeps typing: new revision
    scheduler.advance(ms: 750)
    #expect(e2.list.count == 2 && e2.list.last == .changed(region: "Ask Sairah today"))
    // "Ask Sairah today" vs the paste: the envelope is the inserted "i" at
    // absolute 12..<13; a caret at 13 is immediately after it.
    ax.selectedRange = .range(location: 13, length: 0)
    scheduler.advance(ms: 4500)  // past the OLD deadline; the new one is 10 s from this revision's first deferral
    #expect(e2.list.count == 2, "old cap must not fire for the new revision")
    scheduler.advance(ms: 10_000)
    #expect(e2.list.last == .settled(region: "Ask Sairah today"))
  }

  @Test("a send-shaped end while the caret is still on the word flushes at once; the caret never delays a flush")
  func terminalFlushBeatsCaretWait() {
    let o = PastedRegionObserver(ax: ax, scheduler: scheduler)
    let e = Events()
    startWithFix(o, e)
    ax.selectedRange = .range(location: 15, length: 0)
    scheduler.advance(ms: 1500)
    #expect(e.list.count == 1)
    ax.reads = [.text("")]  // Return in a chat composer
    scheduler.advance(ms: 750)
    #expect(
      e.list == [
        .changed(region: "Ask Saira today"), .settled(region: "Ask Saira today"), .ended(.textboxEmptied),
      ])
  }

  @Test("finish(nextDictationStarted) reads the box once more, flushes the pending fix as it is NOW and ends; with nothing pending it only ends; when not observing it is a no-op")
  func finishFlushesPendingFix() {
    let o = PastedRegionObserver(ax: ax, scheduler: scheduler)
    let e = Events()
    startWithFix(o, e)
    // Typed since the last poll (a poll-only host): the flush must carry the
    // finished word, not the half the last poll saw (cloud review of #3090).
    ax.reads = [.text("Note: Ask Sairah today please")]
    o.finish(.nextDictationStarted)
    #expect(
      e.list == [
        .changed(region: "Ask Saira today"), .changed(region: "Ask Sairah today"),
        .settled(region: "Ask Sairah today"), .ended(.nextDictationStarted),
      ])
    #expect(o.isObserving == false)
    o.finish(.nextDictationStarted)
    #expect(e.list.count == 4, "no-op after the end")

    let o2 = PastedRegionObserver(ax: ax, scheduler: scheduler)
    let e2 = Events()
    ax.reads = [.text("Note: Ask Sarah today please")]
    o2.start(target) { e2.list.append($0) }
    scheduler.advance(ms: 750)
    o2.finish(.nextDictationStarted)
    #expect(e2.list == [.ended(.nextDictationStarted)])

    // The fresh read can end the watch itself (the box was sent meanwhile):
    // that end stands and carries the flush; finish adds nothing.
    let o3 = PastedRegionObserver(ax: ax, scheduler: scheduler)
    let e3 = Events()
    startWithFix(o3, e3)
    ax.reads = [.text("")]
    o3.finish(.nextDictationStarted)
    #expect(
      e3.list == [
        .changed(region: "Ask Saira today"), .settled(region: "Ask Saira today"), .ended(.textboxEmptied),
      ])
    #expect(o3.isObserving == false)
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
        .anchorAmbiguous, .editDistanceExceeded, .ceilingElapsed, .nextDictationStarted,
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

  @Test("a count that changes across the range read is an UNSTABLE arrival attempt, never a stable zero count (#3106 PR A)")
  func arrivalUnstableIsNotAbsent() {
    ax.reads = [.absent]
    let n = host.utf16.count
    ax.counts = [.count(n), .count(n + 1)]
    ax.rangeReads = [.text(host)]
    guard case .unstable(let element, let reader) = observer.attemptArrival(pid: pid, pastedText: "Saira")
    else {
      Issue.record("expected unstable")
      return
    }
    #expect(CFEqual(element, PastedRegionFakeAX.field(pid)) && reader == .range)
    // The same host, stable: a readable field through the range reader with a zero count.
    ax.counts = [.count(n)]
    ax.rangeReads = [.text(host)]
    guard case .readable(let field) = observer.attemptArrival(pid: pid, pastedText: "Saira") else {
      Issue.record("expected readable")
      return
    }
    #expect(field.reader == .range && field.occurrences == .complete([]))
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
