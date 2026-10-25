import AppKit
import EnviousWisprPipeline
import EnviousWisprServices
import Testing

@testable import EnviousWisprAppKit

/// #4101: History Paste pastes only into the app the user came from, once it is seen in front.
/// When this fails, the text lands in another app, or a paste happens after the user left History.
/// A fake desktop and clock: a sleep returns at once unless a test holds it open.
@MainActor
@Suite("History Paste confirms its destination (#4101)", .tags(.productOutcome))
struct HistoryPasteTests {

  @MainActor
  private final class Desk {
    var frontmost: NSRunningApplication?
    var terminated: Set<pid_t> = []
    /// The app `activate` brings forward after this many sleeps; nil never.
    var comesForwardAfterSleeps: Int? = 0
    var activated: [pid_t] = []
    var hides = 0
    var axLive = true
    var clock = ContinuousClock.now
    var lag: Duration = .zero
    var sleeps = 0
    var duringSleep: ((Int) -> Void)?
    /// Parks each sleep until released, so a test can act while a paste waits.
    var holdSleeps = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var parkWaiters: [(count: Int, resume: (Bool) -> Void)] = []
    var target: NSRunningApplication?
    var pastes: [String] = []
    var pasteResult: ClipboardCleanup.ManualClipboardResult = .dispatched
    var notices: [String] = []
    var historyShown = 0
    var dispatched = 0

    /// Resumes the oldest parked sleep only.
    func releaseOldest() {
      guard !held.isEmpty else { return }
      held.removeFirst().resume()
    }

    func releaseAll() {
      let waiting = held
      held = []
      for c in waiting { c.resume() }
    }

    /// True once `count` sleeps are parked: the signal comes from the park itself. The deadline
    /// is only a fallback so a paste that never waits fails the test instead of hanging it.
    func parked(_ count: Int) async -> Bool {
      if held.count >= count { return true }
      return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
        var done = false
        let finish: (Bool) -> Void = { value in
          guard !done else { return }
          done = true
          c.resume(returning: value)
        }
        parkWaiters.append((count, finish))
        Task { @MainActor in
          // settle: deadline fallback only; the park decides success.
          try? await Task.sleep(for: .seconds(5))
          finish(false)
        }
      }
    }

    // settle: a fake sleep; it advances the fake clock and returns at once, or parks on a
    // continuation the test releases. No real time passes.
    func fakeSleep(_ duration: Duration) async {
      sleeps += 1
      clock = clock.advanced(by: duration + lag)
      if let after = comesForwardAfterSleeps, sleeps >= after, let target { frontmost = target }
      duringSleep?(sleeps)
      if holdSleeps {
        await withCheckedContinuation { c in
          held.append(c)
          let ready = parkWaiters.filter { $0.count <= held.count }
          parkWaiters.removeAll { $0.count <= held.count }
          for waiter in ready { waiter.resume(true) }
        }
      }
    }
  }

  private func subject(_ desk: Desk) -> HistoryPaste {
    HistoryPaste(
      effects: .init(
        hide: { desk.hides += 1 },
        accessibilityGrantedLive: { desk.axLive },
        confirmation: .init(
          frontmost: { desk.frontmost },
          isTerminated: { desk.terminated.contains($0.processIdentifier) },
          activate: { app in
            desk.activated.append(app.processIdentifier)
            desk.target = app
            if desk.comesForwardAfterSleeps == 0 { desk.frontmost = app }
            return true
          },
          sleep: { await desk.fakeSleep($0) },
          now: { desk.clock }),
        restoreClipboard: { true },
        markTransient: { false },
        manualPaste: { text, _, _ in
          desk.pastes.append(text)
          return desk.pasteResult
        }))
  }

  @discardableResult
  private func press(
    _ paste: HistoryPaste, _ desk: Desk, to destination: NSRunningApplication?,
    allowed: @escaping @MainActor () -> Bool = { true },
    text: @escaping @MainActor () -> String? = { "Send the draft to Maya." }
  ) -> Task<Void, Never>? {
    paste.paste(
      destination: destination, allowed: allowed, text: text,
      showHistory: { desk.historyShown += 1 }, showNotice: { desk.notices.append($0) },
      dispatched: { desk.dispatched += 1 })
  }

  /// Two real, running applications that are not this process. Compared only.
  private static func twoOtherApps() throws -> (NSRunningApplication, NSRunningApplication) {
    let own = ProcessInfo.processInfo.processIdentifier
    let others = NSWorkspace.shared.runningApplications.filter { $0.processIdentifier != own }
    let first = try #require(others.first, "no other application is running")
    let second = try #require(others.dropFirst().first, "needs two other applications")
    return (first, second)
  }

  @Test("the app the user came from, already in front or brought forward, gets the paste once")
  func confirmedDestinationPastes() async throws {
    let (a, b) = try Self.twoOtherApps()
    let front = Desk()
    front.frontmost = a
    let frontPaste = subject(front)
    await press(frontPaste, front, to: a)?.value
    #expect(front.pastes == ["Send the draft to Maya."])
    #expect(front.dispatched == 1)
    #expect(front.hides == 1)
    #expect(front.activated.isEmpty)
    #expect(front.notices.isEmpty)

    let behind = Desk()
    behind.frontmost = b
    behind.comesForwardAfterSleeps = 3
    let behindPaste = subject(behind)
    await press(behindPaste, behind, to: a)?.value
    #expect(behind.activated == [a.processIdentifier])
    #expect(behind.pastes.count == 1)
    #expect(behind.notices.isEmpty)
  }

  @Test("the text pasted is the row's text after the wait, not at the press")
  func textReadAfterWait() async throws {
    let (a, b) = try Self.twoOtherApps()
    let desk = Desk()
    desk.frontmost = b
    desk.comesForwardAfterSleeps = 2
    var waited = false
    desk.duringSleep = { _ in waited = true }
    await press(subject(desk), desk, to: a, text: { waited ? "edited" : "original" })?.value
    #expect(desk.pastes == ["edited"])
  }

  @Test("no remembered app, or one that quit, refuses before anything is hidden")
  func missingDestinationRefuses() throws {
    let (a, _) = try Self.twoOtherApps()
    let none = Desk()
    let nonePaste = subject(none)
    #expect(press(nonePaste, none, to: nil) == nil)
    #expect(none.notices == [HistoryPaste.couldNotPaste])
    #expect(none.hides == 0)

    let quit = Desk()
    quit.terminated = [a.processIdentifier]
    let quitPaste = subject(quit)
    #expect(press(quitPaste, quit, to: a) == nil)
    #expect(quit.notices == [HistoryPaste.couldNotPaste])
    #expect(quit.hides == 0 && quit.pastes.isEmpty)
  }

  @Test("an app never seen in front, seen only after the deadline, or quit mid-wait gets nothing")
  func unconfirmedDestinationRefuses() async throws {
    let (a, b) = try Self.twoOtherApps()
    let never = Desk()
    never.frontmost = b
    never.comesForwardAfterSleeps = nil
    let neverPaste = subject(never)
    await press(neverPaste, never, to: a)?.value
    #expect(never.pastes.isEmpty)
    #expect(never.historyShown == 1)
    #expect(never.notices == [HistoryPaste.couldNotPaste])

    let late = Desk()
    late.frontmost = b
    late.comesForwardAfterSleeps = 1
    late.lag = .seconds(1)
    let latePaste = subject(late)
    await press(latePaste, late, to: a)?.value
    #expect(late.pastes.isEmpty, "a wait resuming past its deadline must not paste")
    #expect(late.notices == [HistoryPaste.couldNotPaste])

    let quits = Desk()
    quits.frontmost = b
    quits.comesForwardAfterSleeps = nil
    quits.duringSleep = { _ in quits.terminated.insert(a.processIdentifier) }
    let quitsPaste = subject(quits)
    await press(quitsPaste, quits, to: a)?.value
    #expect(quits.pastes.isEmpty, "an app that quit during the wait gets nothing")
    #expect(quits.notices == [HistoryPaste.couldNotPaste])
  }

  @Test("focus moving away after confirmation, before the write, refuses with no clipboard write")
  func finalFrontmostMismatch() async throws {
    let (a, b) = try Self.twoOtherApps()
    let desk = Desk()
    desk.frontmost = a
    var reads = 0
    let paste = subject(desk)
    await press(
      paste, desk, to: a,
      allowed: {
        reads += 1
        if reads == 2 { desk.frontmost = b }  // the after-wait check: focus has just moved
        return true
      })?.value
    #expect(desk.pastes.isEmpty)
    #expect(desk.dispatched == 0)
    #expect(desk.notices == [HistoryPaste.couldNotPaste])
  }

  @Test("a row gone, a held row lapsed or Accessibility off during the wait stands down silently")
  func standDownAfterWait() async throws {
    let (a, b) = try Self.twoOtherApps()
    for change in ["text", "allowed", "accessibility"] {
      let desk = Desk()
      desk.frontmost = b
      desk.comesForwardAfterSleeps = 1
      var waited = false
      desk.duringSleep = { _ in
        waited = true
        if change == "accessibility" { desk.axLive = false }
      }
      let paste = subject(desk)
      await press(
        paste, desk, to: a,
        allowed: { change == "allowed" ? !waited : true },
        text: { change == "text" && waited ? nil : "words" })?.value
      #expect(desk.pastes.isEmpty, "\(change)")
      #expect(desk.historyShown == 1, "\(change): History comes back")
      #expect(desk.notices.isEmpty, "\(change): the row's own state explains it")
    }
  }

  @Test("each clipboard result keeps its notice, and only a posted paste reports dispatched")
  func clipboardResults() async throws {
    let (a, _) = try Self.twoOtherApps()
    let expected: [(ClipboardCleanup.ManualClipboardResult, String?, Int)] = [
      (.dispatched, nil, 1),
      (.dispatchFailed, "Copied. Paste it yourself.", 0),
      (.clipboardBusy, HistoryPaste.couldNotPaste, 0),
      (.writeFailed, HistoryPaste.couldNotPaste, 0),
    ]
    for (result, notice, dispatched) in expected {
      let desk = Desk()
      desk.frontmost = a
      desk.pasteResult = result
      let paste = subject(desk)
      await press(paste, desk, to: a)?.value
      #expect(desk.notices == (notice.map { [$0] } ?? []), "\(result)")
      #expect(desk.dispatched == dispatched, "\(result)")
    }
  }

  @Test("the History page's notice stays until dismissed; History Paste only reports it")
  func noticeLifetime() throws {
    let holder = HistoryPasteNotice()
    let desk = Desk()
    let paste = subject(desk)
    _ = paste.paste(
      destination: nil, allowed: { true }, text: { "words" }, showHistory: {},
      showNotice: holder.show)
    #expect(holder.text == HistoryPaste.couldNotPaste)
    holder.dismiss()
    #expect(holder.text == nil)
  }

  @Test("a second press while a paste waits is ignored")
  func secondPressIgnored() async throws {
    let (a, b) = try Self.twoOtherApps()
    let desk = Desk()
    desk.frontmost = b
    desk.comesForwardAfterSleeps = 1
    desk.holdSleeps = true
    let paste = subject(desk)
    let first = try #require(press(paste, desk, to: a))
    try #require(await desk.parked(1), "the paste never waited")
    #expect(press(paste, desk, to: a) == nil)
    #expect(desk.hides == 1, "no second hide")
    desk.holdSleeps = false
    desk.releaseAll()
    await first.value
    #expect(desk.pastes.count == 1)
    #expect(paste.isPending == false)
  }

  @Test("cancelling before the paste runs or while it waits writes, shows and reopens nothing")
  func cancellation() async throws {
    let (a, b) = try Self.twoOtherApps()
    let early = Desk()
    early.frontmost = a
    let paste = subject(early)
    let task = try #require(press(paste, early, to: a))
    paste.cancelPending()
    paste.cancelPending()
    await task.value
    #expect(early.hides == 0 && early.pastes.isEmpty && early.notices.isEmpty)

    let waiting = Desk()
    waiting.frontmost = b
    waiting.comesForwardAfterSleeps = 2
    let waitingPaste = subject(waiting)
    waiting.duringSleep = { if $0 == 1 { waitingPaste.cancelPending() } }
    await press(waitingPaste, waiting, to: a)?.value
    #expect(waiting.pastes.isEmpty)
    #expect(waiting.notices.isEmpty)
    #expect(waiting.historyShown == 0)
    #expect(waitingPaste.isPending == false)
  }

  @Test("closing the window or leaving History ends a waiting paste; staying on History does not")
  func dismissalDecisions() async throws {
    let (a, b) = try Self.twoOtherApps()
    let cases: [(String, (HistoryPaste) -> Void, Bool)] = [
      ("window closed", { $0.windowClosed() }, true),
      ("left History", { $0.navigated(from: .history, to: .aiPolish) }, true),
      ("stayed on History", { $0.navigated(from: .history, to: .history) }, false),
      ("arrived at History", { $0.navigated(from: .aiPolish, to: .history) }, false),
    ]
    for (name, act, cancels) in cases {
      let desk = Desk()
      desk.frontmost = b
      desk.comesForwardAfterSleeps = 1
      desk.holdSleeps = true
      let paste = subject(desk)
      let task = try #require(press(paste, desk, to: a), "\(name)")
      try #require(await desk.parked(1), "\(name): the paste never waited")
      act(paste)
      #expect(paste.isPending == !cancels, "\(name)")
      desk.holdSleeps = false
      desk.releaseAll()
      await task.value
      #expect(desk.pastes.count == (cancels ? 0 : 1), "\(name)")
      #expect(desk.notices.isEmpty, "\(name)")
      #expect(desk.historyShown == 0, "\(name): nothing reopens History")
    }
  }

  @Test("a cancelled paste resuming late does not touch a newer paste")
  func staleCompletion() async throws {
    let (a, b) = try Self.twoOtherApps()
    let desk = Desk()
    desk.frontmost = b
    desk.comesForwardAfterSleeps = nil
    desk.holdSleeps = true
    let paste = subject(desk)
    let old = try #require(press(paste, desk, to: a))
    try #require(await desk.parked(1), "the old paste never waited")
    paste.cancelPending()
    let new = try #require(press(paste, desk, to: a), "a new paste is admitted after cancelling")
    try #require(await desk.parked(2), "the new paste never waited")

    // Only the old paste resumes; the new one stays parked.
    desk.releaseOldest()
    await old.value
    #expect(paste.isPending, "the old paste did not clear the new one")
    #expect(press(paste, desk, to: a) == nil, "a press is still refused while the new one waits")
    #expect(desk.pastes.isEmpty && desk.notices.isEmpty && desk.historyShown == 0)

    desk.comesForwardAfterSleeps = 0
    desk.holdSleeps = false
    desk.releaseAll()
    await new.value
    #expect(desk.pastes.count == 1, "only the new paste writes")
    #expect(desk.dispatched == 1)
    #expect(paste.isPending == false)
  }
}
