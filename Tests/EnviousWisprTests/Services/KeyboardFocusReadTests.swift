import ApplicationServices
import Foundation
import Testing

@testable import EnviousWisprServices

/// Product Outcome (#3423): the one system-wide keyboard-focus read.
///
/// When this fails, a failed or refused read is taken for "nothing focused" (the paste picks the
/// wrong fallback), an owner that cannot be read drops the user's field, a slow app holds the
/// paste longer than its 0.25 s bound, or the process-wide Accessibility timeout stays shortened
/// and every later read in the app gives up early.
@MainActor
@Suite(.tags(.productOutcome))
struct KeyboardFocusReadTests {
  let systemWide = AXUIElementCreateApplication(1)
  let field = AXUIElementCreateApplication(10_042)

  final class Script {
    var trusted = true
    var installSucceeds = true
    var answer: (AXError, CFTypeRef?) = (.cannotComplete, nil)
    var owner: pid_t? = 42
    var calls: [String] = []
    var failures: [AXError] = []
  }

  func operations(_ script: Script) -> PasteService.KeyboardFocusOperations {
    PasteService.KeyboardFocusOperations(
      isTrusted: { script.trusted },
      systemWide: { systemWide },
      setMessagingTimeout: { _, seconds in
        script.calls.append("timeout \(seconds)")
        return seconds == 0 || script.installSucceeds
      },
      copyFocusedElement: { _ in
        script.calls.append("copy")
        return script.answer
      },
      ownerPID: { _ in
        script.calls.append("pid")
        return script.owner
      })
  }

  /// `admits`: nil reads with no budget (the cap is installed directly); otherwise a budget that
  /// answers this.
  func read(_ script: Script, cap: Double? = 0.25, admits: Bool? = nil) -> KeyboardFocusRead {
    var admit: (@MainActor (AXUIElement, Double) -> Bool)?
    if let answer = admits {
      admit = { _, cap in
        script.calls.append("admit \(cap)")
        return answer
      }
    }
    return PasteService.readKeyboardFocus(
      cap: cap, admit: admit, onFailure: { script.failures.append($0) },
      operations: operations(script))
  }

  @Test("a confirmed owner: the cap, one read, one pid read, then the process default back")
  func focused() {
    let script = Script()
    script.answer = (.success, field)
    guard case .focused(let element, let owner) = read(script) else {
      Issue.record("not focused")
      return
    }
    #expect(CFEqual(element, field))
    #expect(owner == 42)
    #expect(script.calls == ["timeout 0.25", "copy", "pid", "timeout 0.0"])
    #expect(PasteService.keyboardFocusReadCapSeconds == 0.25, "the plan's bound")
  }

  @Test("with a budget, the budget installs the bound, given the cap")
  func budgetInstallsTheBound() {
    let script = Script()
    script.answer = (.success, field)
    guard case .focused = read(script, admits: true) else {
      Issue.record("not focused")
      return
    }
    #expect(script.calls == ["admit 0.25", "copy", "pid", "timeout 0.0"])
  }

  @Test("an element whose owner cannot be read, or reads as no process, is kept, never dropped")
  func ownerUnreadableKeepsTheElement() {
    for owner: pid_t? in [nil, 0, -1] {
      let script = Script()
      script.answer = (.success, field)
      script.owner = owner
      guard case .ownerUnreadable(let element) = read(script) else {
        Issue.record("owner \(String(describing: owner)): element dropped or trusted")
        return
      }
      #expect(CFEqual(element, field))
    }
  }

  @Test("'nothing is focused' and 'the read failed' stay apart, and record start hears the error")
  func noElementIsNotUnreadable() {
    let script = Script()
    script.answer = (.noValue, nil)
    guard case .noElement = read(script) else {
      Issue.record("noValue")
      return
    }
    script.answer = (.success, nil)
    guard case .noElement = read(script) else {
      Issue.record("success with nothing")
      return
    }
    script.answer = (.success, "not an element" as CFString)
    guard case .unreadable = read(script) else {
      Issue.record("a value that is not an element confirms nothing")
      return
    }
    for error in [AXError.cannotComplete, .notImplemented, .apiDisabled] {
      script.answer = (error, nil)
      guard case .unreadable = read(script) else {
        Issue.record("\(error.rawValue)")
        return
      }
    }
    #expect(
      script.failures == [
        .noValue, .success, .success, .cannotComplete, .notImplemented, .apiDisabled,
      ])
  }

  @Test("a refused budget or a failed bound reads nothing, and the default still goes back")
  func refusedReadsNothing() {
    let refused = Script()
    refused.answer = (.success, field)
    guard case .unreadable = read(refused, admits: false) else {
      Issue.record("admitted")
      return
    }
    #expect(refused.calls == ["admit 0.25", "timeout 0.0"])

    let failed = Script()
    failed.installSucceeds = false
    guard case .unreadable = read(failed) else {
      Issue.record("unbounded read")
      return
    }
    #expect(failed.calls == ["timeout 0.25", "timeout 0.0"], "no read behind a missing bound")
  }

  @Test("untrusted: no Accessibility call at all")
  func untrusted() {
    let script = Script()
    script.trusted = false
    guard case .unreadable = read(script) else {
      Issue.record("read while untrusted")
      return
    }
    #expect(script.calls.isEmpty)
  }

  @Test("record start's unbounded read installs no bound and asks no budget, as before")
  func unbounded() {
    let script = Script()
    script.answer = (.success, field)
    guard case .focused = read(script, cap: nil, admits: true) else {
      Issue.record("not focused")
      return
    }
    #expect(script.calls == ["copy", "pid", "timeout 0.0"])
  }

  @Test("a budget installs the cap or what it has left, whichever is less")
  func budgetCap() {
    let ax = PastedRegionFakeAX()
    let scheduler = PastedRegionFakeScheduler()
    let roomy = PasteLandingPrepareBudget(scheduler: scheduler, ax: ax)
    #expect(roomy.admit(PastedRegionFakeAX.app(42), cappedAt: 0.25))
    #expect(ax.timeoutsSet.last?.1 == 0.25, "500 ms left: the cap")

    let tight = PasteLandingPrepareBudget(scheduler: scheduler, ax: ax)
    scheduler.advance(ms: 400)
    #expect(tight.admit(PastedRegionFakeAX.app(42), cappedAt: 0.25))
    #expect(ax.timeoutsSet.last?.1 == 0.1, "100 ms left: what is left")
    #expect(tight.admit(PastedRegionFakeAX.app(42)))
    #expect(ax.timeoutsSet.last?.1 == 0.1, "the uncapped admit is unchanged")
  }
}
