import EnviousWisprAppKitTestSupport
import Foundation
import Testing

@testable import EnviousWisprAppKit

// MARK: - The late clipboard notice (#3106 PR B)
//
// When a paste went nowhere and the clipboard cleanup kept the words, the EXISTING "Copied. Press
// ⌘V to paste" notice shows, about 0.3 s after the paste, but only on an idle, empty overlay, only
// for the latest take, and only while the board still holds the kept text.

/// Product Outcome: when these fail, the user is told their words are on the clipboard when they are
/// not (a newer take, or they copied since), a notice about an old paste displaces something on
/// screen, or the notice is missing after a real miss.
@MainActor
@Suite("Late clipboard notice: admission (#3106 PR B)", .tags(.productOutcome))
struct RetainedPasteNoticeReducerTests {

  @Test(
    "An idle, empty overlay admits it with the clipboard-fallback copy, width, dwell and sentence")
  func admittedOnAnEmptySlot() throws {
    let id = PresentationID()
    var r = OverlayReducer(makeID: { id })
    let plan = r.reduce(.retainedClipboardFallback(takeID: "take-1"))
    let shown = try #require(plan.presentation)
    let base = PillCatalog.entry(for: .clipboardFallback, id: id)
    let baseDefinition = try #require(base.definition)
    guard case .notice(let baseNotice) = baseDefinition.content else {
      Issue.record("the clipboard fallback is not a notice")
      return
    }
    #expect(shown.content == .retainedClipboardFallback(baseNotice, takeID: "take-1"))
    #expect(shown.expiry == baseDefinition.expiry)
    #expect(shown.requestedWidth == baseDefinition.requestedWidth)
    #expect(plan.announcement == base.announcement)
    #expect(shown.content.reChecksOwnerBeforeRender)
    #expect(r.state.pipelineIntent == .hidden, "a feature, not a pipeline state")
  }

  @Test("It never displaces anything: another feature, a notice, or a busy pipeline refuses it")
  func refusedWhenTheSlotIsTakenOrBusy() {
    var bluetooth = OverlayReducer()
    _ = bluetooth.reduce(.bluetoothAwareness)
    #expect(bluetooth.reduce(.retainedClipboardFallback(takeID: "t")) == .noChange)
    #expect(bluetooth.state.current?.content == .bluetoothAwareness)

    var status = OverlayReducer()
    _ = status.reduce(.importStatus(message: "Imported 12 words"))
    let before = status.state.current
    #expect(status.reduce(.retainedClipboardFallback(takeID: "t")) == .noChange)
    #expect(status.state.current == before)

    var recovery = OverlayReducer()
    _ = recovery.reduce(.pipeline(.escapeRecovery(transcriptID: UUID())))
    let offer = recovery.state.current
    #expect(recovery.reduce(.retainedClipboardFallback(takeID: "t")) == .noChange)
    #expect(recovery.state.current == offer)

    var processing = OverlayReducer()
    _ = processing.reduce(.pipeline(.processing(phase: .transcribing)))
    #expect(processing.reduce(.retainedClipboardFallback(takeID: "t")) == .noChange)

    var recording = OverlayReducer()
    recording.startRecordingForTests(audioLevel: 0.2)
    #expect(recording.reduce(.retainedClipboardFallback(takeID: "t")) == .noChange)
  }
}

@MainActor
@Suite("Late clipboard notice: owner and render (#3106 PR B)", .tags(.productOutcome))
struct RetainedPasteNoticeDirectorTests {

  // Held by the suite: the clock's scheduler captures itself unowned, and the director does not
  // keep its host alive for the test.
  let clock = LearnedPillClock()
  let host = WindowlessOverlayHost()

  private final class Log {
    var shown: [(String, Bool)] = []
    var announcements: [OverlayAnnouncement] = []
  }

  /// A director whose first render runs when the test says so (`deferred`), or at once.
  private func director(_ log: Log, deferring: Bool) -> (OverlayDirector, () -> (() -> Void)?) {
    var deferred: (() -> Void)?
    let d = OverlayDirector(
      host: host, scheduler: clock.scheduler,
      announce: { log.announcements.append($0) },
      livePreview: .disabled, grantAccessibility: {}, openMicrophoneSettings: {},
      advisoryHint: { _ in nil }, selections: { .shipped },
      firstRenderSchedule: { deferring ? (deferred = $0) : $0() })
    return (d, { deferred })
  }

  private func isShowing(_ d: OverlayDirector) -> Bool {
    if case .retainedClipboardFallback? = d.renderModel.state.presentation?.content { return true }
    return false
  }

  @MainActor
  private final class Board { var count = 10 }

  private func notice(_ board: Board, _ log: Log) -> RetainedPasteNotice {
    let n = RetainedPasteNotice(boardChangeCount: { board.count })
    n.onPresentation = { log.shown.append(($0, $1)) }
    return n
  }

  @Test("A kept dictation for the latest take shows the notice once and reports it shown")
  func latestTakeIsShown() {
    let log = Log()
    let (d, _) = director(log, deferring: false)
    let board = Board()
    let n = notice(board, log)
    n.connect(d)
    n.takeAccepted("take-1")
    n.retained(takeID: "take-1", changeCount: 10)
    #expect(isShowing(d))
    #expect(log.announcements.count == 1)
    #expect(log.shown.count == 1 && log.shown.first?.0 == "take-1" && log.shown.first?.1 == true)
  }

  @Test("The user copies before a deferred first render: nothing renders, nothing is spoken")
  func userCopyBeforeRenderRefuses() throws {
    let log = Log()
    let (d, deferred) = director(log, deferring: true)
    let board = Board()
    let n = notice(board, log)
    n.connect(d)
    n.takeAccepted("take-1")
    n.retained(takeID: "take-1", changeCount: 10)
    #expect(log.shown.isEmpty, "nothing answered before the render")
    board.count = 11
    let render = try #require(deferred())
    render()
    #expect(isShowing(d) == false)
    #expect(log.announcements.isEmpty)
    #expect(log.shown.count == 1 && log.shown.first?.1 == false)
  }

  @Test("A newer take starts before a deferred first render: the old notice never renders")
  func newerTakeBeforeRenderRefuses() throws {
    let log = Log()
    let (d, deferred) = director(log, deferring: true)
    let n = notice(Board(), log)
    n.connect(d)
    n.takeAccepted("take-1")
    n.retained(takeID: "take-1", changeCount: 10)
    n.takeAccepted("take-2")
    let render = try #require(deferred())
    render()
    #expect(isShowing(d) == false)
    #expect(log.announcements.isEmpty)
    #expect(log.shown.first?.1 == false)
  }

  @Test("A report for an older take, a moved board, or no overlay yet is dropped without asking")
  func staleReportsAreDropped() {
    let log = Log()
    let (d, _) = director(log, deferring: false)
    let board = Board()
    let n = notice(board, log)

    n.takeAccepted("take-1")
    n.retained(takeID: "take-1", changeCount: 10)  // not connected yet
    n.connect(d)
    n.takeAccepted("take-2")
    n.retained(takeID: "take-1", changeCount: 10)  // older take
    n.retained(takeID: "take-2", changeCount: 9)  // board moved since
    #expect(isShowing(d) == false)
    #expect(log.announcements.isEmpty)
    #expect(log.shown.map(\.1) == [false, false, false])
  }

  @Test("An occupied overlay refuses it, and the notice reports it not shown")
  func occupiedOverlayIsReported() {
    let log = Log()
    let (d, _) = director(log, deferring: false)
    _ = d.present(.importStatus(message: "Imported 12 words"))
    let announcedBefore = log.announcements.count
    let n = notice(Board(), log)
    n.connect(d)
    n.takeAccepted("take-1")
    n.retained(takeID: "take-1", changeCount: 10)
    #expect(isShowing(d) == false)
    #expect(log.announcements.count == announcedBefore)
    #expect(log.shown.first?.1 == false)
  }

  @Test("The pre-render question exists only for a matching binding with a predicate; otherwise it refuses")
  func ownerRecheckFailsClosed() {
    let id = PresentationID()
    let other = PresentationID()
    #expect(OverlayDirector.ownerRecheck(for: id, bindingID: nil, predicate: { true }) == nil)
    #expect(OverlayDirector.ownerRecheck(for: id, bindingID: other, predicate: { true }) == nil)
    #expect(OverlayDirector.ownerRecheck(for: id, bindingID: id, predicate: nil) == nil)
    let found = OverlayDirector.ownerRecheck(for: id, bindingID: id, predicate: { false })
    #expect(found?() == false, "the owner's own answer is what is returned")
  }
}
