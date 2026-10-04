import ApplicationServices
import Foundation
import Testing

@testable import EnviousWisprServices

/// Product Outcome (#3423): the one system-wide keyboard-focus read.
///
/// When this fails, a failed or refused read is taken for "nothing focused" (the paste picks the
/// wrong fallback), an owner that cannot be read drops the user's field, or the process-wide
/// Accessibility timeout stays shortened and every later read in the app gives up early.
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

  func read(_ script: Script, bound: Double? = 0.5, admits: Bool = true) -> KeyboardFocusRead {
    PasteService.readKeyboardFocus(
      bound: bound,
      admit: { _ in
        script.calls.append("admit")
        return admits
      }, operations: operations(script))
  }

  @Test(
    "a confirmed owner: bound, then admit, then one read and one pid read, then the default back")
  func focused() {
    let script = Script()
    script.answer = (.success, field)
    guard case .focused(let element, let owner) = read(script) else {
      Issue.record("not focused")
      return
    }
    #expect(CFEqual(element, field))
    #expect(owner == 42)
    #expect(script.calls == ["timeout 0.5", "admit", "copy", "pid", "timeout 0.0"])
  }

  @Test("an element whose owner cannot be read is kept, never dropped")
  func ownerUnreadableKeepsTheElement() {
    let script = Script()
    script.answer = (.success, field)
    script.owner = nil
    guard case .ownerUnreadable(let element) = read(script) else {
      Issue.record("element dropped")
      return
    }
    #expect(CFEqual(element, field))
  }

  @Test("'nothing is focused' and 'the read failed' stay apart")
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
    guard case .noElement = read(script) else {
      Issue.record("success with a string")
      return
    }
    for error in [AXError.cannotComplete, .notImplemented, .apiDisabled] {
      script.answer = (error, nil)
      guard case .unreadable = read(script) else {
        Issue.record("\(error.rawValue)")
        return
      }
    }
  }

  @Test("a refused budget or a failed bound reads nothing, and the default still goes back")
  func refusedReadsNothing() {
    let refused = Script()
    refused.answer = (.success, field)
    guard case .unreadable = read(refused, admits: false) else {
      Issue.record("admitted")
      return
    }
    #expect(refused.calls == ["timeout 0.5", "admit", "timeout 0.0"])

    let failed = Script()
    failed.installSucceeds = false
    guard case .unreadable = read(failed) else {
      Issue.record("unbounded read")
      return
    }
    #expect(failed.calls == ["timeout 0.5", "timeout 0.0"], "no admission and no read")
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

  @Test("record start's unbounded read installs no bound but still puts the default back")
  func unbounded() {
    let script = Script()
    script.answer = (.success, field)
    guard case .focused = read(script, bound: nil) else {
      Issue.record("not focused")
      return
    }
    #expect(script.calls == ["admit", "copy", "pid", "timeout 0.0"])
  }
}
