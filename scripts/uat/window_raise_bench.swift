// #3304 pre-build bench: does raising the recorded window of a SLEEPING Chrome put keyboard focus
// back in its text box, so a Cmd+V lands there? Plan §11.0
// (docs/feature-requests/issue-3304-2026-09-29-sleeping-host-window-target.md, main checkout).
//
// Standalone and deliberately rough: edit freely. It reproduces the production calls it cites;
// if those change, change them here too.
//
//   swiftc -O scripts/uat/window_raise_bench.swift -o /tmp/window_raise_bench
//   /tmp/window_raise_bench [--trials N] [--cases C1,C2,...] [--variants textarea,editable]
//
// Needs Accessibility for the terminal that runs it, a hands-off Mac (it sends Cmd+V to its own
// Chrome, checked before every key), and no EnviousWispr or other accessibility client that could
// wake Chrome. Writes a JSON line per attempt to stdout and a summary at the end.

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

// MARK: - Production constants (Sources/EnviousWisprCore/Constants.swift:375, :381, :384)

let activationTimeoutMs = 1000
let activationPollIntervalMs = 50
let reissueEveryMs = 300  // PasteCascadeExecutor.activate re-issues raise + activate every ~300 ms
let perCallCapMs = 500  // PasteLandingPrepareBudget.defaultMs cap per AX call
let recordBudgetMs = 250  // plan §3 step 2

// MARK: - Small helpers

func nowMs() -> Int { Int(DispatchTime.now().uptimeNanoseconds / 1_000_000) }

/// Turns the run loop for `seconds`. Every caller is either a deliberate stand-in for user time
/// (the switch, the ASR/polish wait) or a production poll interval; the observable result is
/// always read afterwards from Chrome itself.
func pump(_ seconds: Double) {
  RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))  // settle: bench stands in for user and pipeline time; results are read from Chrome after
}

func log(_ dict: [String: Any]) {
  if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
    let line = String(data: data, encoding: .utf8)
  {
    print(line)
    fflush(stdout)
  }
}

func stderr(_ message: String) {
  FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

func fail(_ message: String) -> Never {
  stderr("ABORT: " + message)
  Bench.shared?.cleanup()
  exit(2)
}

func copyAttr(_ element: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
  var value: CFTypeRef?
  let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
  return (error, value)
}

func stringAttr(_ element: AXUIElement, _ name: String) -> String? {
  let (error, value) = copyAttr(element, name)
  guard error == .success else { return nil }
  return value as? String
}

func elementAttr(_ element: AXUIElement, _ name: String) -> AXUIElement? {
  let (error, value) = copyAttr(element, name)
  guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
    return nil
  }
  return (value as! AXUIElement)
}

// MARK: - Fixture pages

// Passive handlers only: they never focus after load, never preventDefault, never insert. The window
// title is the oracle (AXTitle stays readable while Chrome's accessibility sleeps).
func pageA(editable: Bool) -> String {
  let field =
    editable
    ? "<div id=f contenteditable=true style='border:1px solid;min-height:80px'></div>"
    : "<textarea id=f autofocus style='width:90%;height:80px'></textarea>"
  let read = editable ? "f.innerText" : "f.value"
  return """
    <html><body><h3>BENCH A</h3>\(field)<script>
    var f=document.getElementById('f');var ins=0,pas=0;
    function t(){document.title='A|v='+encodeURIComponent(\(read))+'|i='+ins+'|p='+pas+'|f='+(document.activeElement?document.activeElement.tagName:'none')+'|end';}
    f.addEventListener('input',function(){ins++;t();});
    document.addEventListener('paste',function(){pas++;setTimeout(t,0);});
    \(editable ? "f.focus();" : "")t();
    </script></body></html>
    """
}

func pageB(withField: Bool) -> String {
  let field = withField ? "<textarea id=g autofocus style='width:90%;height:80px'></textarea>" : ""
  let read = withField ? "g.value" : "''"
  let tag = withField ? "BF" : "B"
  return """
    <html><body><h3>BENCH \(tag)</h3>\(field)<script>
    var g=document.getElementById('g');var ins=0,pas=0;
    function t(){document.title='\(tag)|v='+encodeURIComponent(\(read))+'|i='+ins+'|p='+pas+'|end';}
    if(g){g.addEventListener('input',function(){ins++;t();});}
    document.addEventListener('paste',function(){pas++;setTimeout(t,0);});
    t();
    </script></body></html>
    """
}

func dataURL(_ html: String) -> String {
  "data:text/html;base64," + Data(html.utf8).base64EncodedString()
}

struct PageState: Equatable {
  var value: String
  var inputs: Int
  var pastes: Int

  static func parse(_ title: String?) -> PageState? {
    // Chrome appends " - Google Chrome" to the page title; the pages end theirs with "|end".
    guard let raw = title, let end = raw.range(of: "|end") else { return nil }
    let title = String(raw[..<end.lowerBound])
    var fields: [String: String] = [:]
    for part in title.split(separator: "|").dropFirst() {
      let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
      if kv.count == 2 { fields[kv[0]] = kv[1] } else if kv.count == 1 { fields[kv[0]] = "" }
    }
    guard let v = (fields["v"] ?? "").removingPercentEncoding,
      let i = fields["i"].flatMap(Int.init), let p = fields["p"].flatMap(Int.init)
    else { return nil }
    return PageState(value: v, inputs: i, pastes: p)
  }
}

func occurrences(_ needle: String, in haystack: String) -> Int {
  haystack.components(separatedBy: needle).count - 1
}

// MARK: - Pasteboard save / restore

enum Board {
  static func save() -> [[NSPasteboard.PasteboardType: Data]] {
    (NSPasteboard.general.pasteboardItems ?? []).map { item in
      var map: [NSPasteboard.PasteboardType: Data] = [:]
      for type in item.types { if let data = item.data(forType: type) { map[type] = data } }
      return map
    }
  }

  static func restore(_ items: [[NSPasteboard.PasteboardType: Data]]) {
    let board = NSPasteboard.general
    board.clearContents()
    let restored: [NSPasteboardItem] = items.map { map in
      let item = NSPasteboardItem()
      for (type, data) in map { item.setData(data, forType: type) }
      return item
    }
    if !restored.isEmpty { board.writeObjects(restored) }
  }
}

// MARK: - Bench

final class Bench {
  static var shared: Bench?

  let profile: String
  var chromePid: pid_t = 0
  var app: AXUIElement { AXUIElementCreateApplication(chromePid) }
  var savedBoard: [[NSPasteboard.PasteboardType: Data]]? = nil
  var ourChangeCount = -1

  init() {
    profile = NSTemporaryDirectory() + "ew-3304-bench-" + UUID().uuidString.prefix(8)
    Bench.shared = self
  }

  // MARK: Chrome process

  func openWindow(_ url: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = [
      "-na", "Google Chrome", "--args", "--user-data-dir=\(profile)", "--no-first-run",
      "--no-default-browser-check", "--disable-extensions", "--new-window", url,
    ]
    try? p.run()
    p.waitUntilExit()
  }

  /// The main Chrome process for our profile: exact `--user-data-dir=<profile>` argument and the
  /// Chrome main executable, never a helper. Refuses ambiguity.
  func findPid() -> pid_t? {
    let p = Process()
    let out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-axww", "-o", "pid=,command="]
    p.standardOutput = out
    try? p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let exe = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome "
    var hits: [pid_t] = []
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]) else {
        continue
      }
      let command = String(trimmed[trimmed.index(after: space)...])
      let args = command.split(separator: " ").map(String.init)
      if command.hasPrefix(exe), args.contains("--user-data-dir=\(profile)") { hits.append(pid) }
    }
    if hits.count > 1 { fail("more than one main Chrome for the bench profile: \(hits)") }
    return hits.first
  }

  func launch(pages: [String]) {
    openWindow(pages[0])
    let deadline = Date(timeIntervalSinceNow: 15)
    while Date() < deadline, findPid() == nil { pump(0.25) }
    guard let pid = findPid() else { fail("bench Chrome did not start") }
    chromePid = pid
    pump(2.0)
    log(["event": "launch_sample", "after": "window_1", "focus": Int(focusSample())])
    for (index, url) in pages.dropFirst().enumerated() {
      openWindow(url)
      pump(1.5)
      log(["event": "launch_sample", "after": "window_\(index + 2)", "focus": Int(focusSample())])
    }
  }

  func restoreBoard() {
    guard let saved = savedBoard else { return }
    if ourChangeCount < 0 || NSPasteboard.general.changeCount == ourChangeCount {
      Board.restore(saved)
    } else {
      stderr("pasteboard changed by someone else; not restored")
    }
    savedBoard = nil
    ourChangeCount = -1
  }

  func quitChrome() {
    if chromePid > 0, findPid() == chromePid {
      kill(chromePid, SIGTERM)
      let deadline = Date(timeIntervalSinceNow: 10)
      while Date() < deadline, findPid() != nil { pump(0.25) }
    }
    chromePid = 0
  }

  func cleanup() {
    restoreBoard()
    quitChrome()
    if findPid() != nil {
      stderr("bench Chrome still running; profile kept at \(profile)")
      return
    }
    let attrs = try? FileManager.default.attributesOfItem(atPath: profile)
    guard profile.hasPrefix(NSTemporaryDirectory()), profile.contains("ew-3304-bench-"),
      (attrs?[.type] as? FileAttributeType) == .typeDirectory
    else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/find")
    p.arguments = [profile, "-xdev", "-delete"]
    try? p.run()
    p.waitUntilExit()
    if FileManager.default.fileExists(atPath: profile) {
      stderr("profile not fully removed: \(profile)")
    }
  }

  // MARK: Windows

  func windows() -> [AXUIElement] {
    let (error, value) = copyAttr(app, kAXWindowsAttribute)
    guard error == .success, let list = value as? [AXUIElement] else { return [] }
    return list
  }

  func window(tag: String) -> AXUIElement? {
    let hits = windows().filter { (stringAttr($0, kAXTitleAttribute) ?? "").hasPrefix(tag + "|") }
    if hits.count > 1 { fail("more than one window titled \(tag)|") }
    return hits.first
  }

  func state(_ window: AXUIElement?) -> PageState? {
    window.flatMap { PageState.parse(stringAttr($0, kAXTitleAttribute)) }
  }

  /// The raw AXFocusedUIElement error on the app: -25212 (noValue) is the sleep signature
  /// (accessibility-macos.md FACT: electron-accessibility-switches-on-macos-26).
  func focusSample() -> Int32 {
    copyAttr(app, kAXFocusedUIElementAttribute).0.rawValue
  }

  func focusedWindow() -> (AXError, AXUIElement?) {
    let (error, value) = copyAttr(app, kAXFocusedWindowAttribute)
    guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
      return (error == .success ? .noValue : error, nil)
    }
    return (.success, (value as! AXUIElement))
  }

  func frontmostPid() -> pid_t? {
    pump(0.01)  // NSWorkspace needs a turning run loop (accessibility-macos.md, stale frontmost)
    return NSWorkspace.shared.frontmostApplication?.processIdentifier
  }

  // MARK: Production calls

  /// PasteService.raiseWindow (PasteService.swift:2437): AXRaise then AXMain=true, each bounded.
  func raiseWindow(_ window: AXUIElement, boundMs: Int) {
    AXUIElementSetMessagingTimeout(window, Float(boundMs) / 1000)
    _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    AXUIElementSetMessagingTimeout(window, 0)
  }

  /// PasteService.forceActivateApp (PasteService.swift:2389): AXFrontmost=true, bounded.
  func forceActivate(boundMs: Int) {
    let element = AXUIElementCreateApplication(chromePid)
    AXUIElementSetMessagingTimeout(element, Float(boundMs) / 1000)
    _ = AXUIElementSetAttributeValue(element, "AXFrontmost" as CFString, true as CFTypeRef)
  }

  /// PasteCascadeExecutor.raiseAndActivate (:1547): raise, force-activate, then activate() always.
  func raiseAndActivate(_ window: AXUIElement?, remainingMs: Int) {
    if let window, remainingMs > 0 { raiseWindow(window, boundMs: min(perCallCapMs, remainingMs)) }
    if remainingMs > 0 { forceActivate(boundMs: min(perCallCapMs, remainingMs)) }
    NSRunningApplication(processIdentifier: chromePid)?.activate()
  }

  enum Gate: String {
    case equal, mismatch, unreadable
    case notFront = "not_front"
  }

  /// Plan §3 step 6 for `.recordedWindow`: only a READ different window refuses.
  func gate(_ recorded: AXUIElement) -> Gate {
    let (error, focused) = focusedWindow()
    guard error == .success, let focused else { return .unreadable }
    return CFEqual(focused, recorded) ? .equal : .mismatch
  }

  /// PasteCascadeExecutor.activate (:1498-1542): 1000 ms wall clock, 50 ms polls, re-issue ~300 ms.
  func activate(recorded: AXUIElement) -> (front: Bool, gate: Gate, elapsedMs: Int) {
    let start = nowMs()
    func remaining() -> Int { activationTimeoutMs - (nowMs() - start) }
    raiseAndActivate(recorded, remainingMs: remaining())
    var lastIssue = nowMs()
    var front = false
    var last: Gate = .notFront
    while remaining() > 0 {
      pump(Double(activationPollIntervalMs) / 1000)
      front = frontmostPid() == chromePid
      if front {
        last = gate(recorded)
        if last != .mismatch { break }  // unreadable passes (§3 step 6)
      }
      if nowMs() - lastIssue >= reissueEveryMs, remaining() > 0 {
        raiseAndActivate(recorded, remainingMs: remaining())
        lastIssue = nowMs()
      }
    }
    return (front, front ? last : .notFront, nowMs() - start)
  }

  /// PasteService.dispatchCmdV (:2451).
  func cmdV() {
    let source = CGEventSource(stateID: .combinedSessionState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: UInt16(kVK_ANSI_V), keyDown: false)
    down?.flags = .maskCommand
    up?.flags = .maskCommand
    down?.post(tap: .cgAnnotatedSessionEventTap)
    up?.post(tap: .cgAnnotatedSessionEventTap)
  }

  /// Every key goes through here: the frontmost app must be the bench's own Chrome, re-read just
  /// before the key. A global CGEvent still has a race after this check, hence hands-off.
  func safeCmdV() {
    guard frontmostPid() == chromePid, findPid() == chromePid else {
      fail("frontmost is not the bench Chrome; no key sent")
    }
    cmdV()
  }

  func setToken(_ token: String) {
    let board = NSPasteboard.general
    board.clearContents()
    board.setString(token, forType: .string)
    ourChangeCount = board.changeCount
    guard board.types?.contains(.string) == true, board.string(forType: .string) == token else {
      fail("pasteboard did not take the token")
    }
  }

  /// Record per plan §3 step 2: AXFocusedWindow + AXStandardWindow, one 250 ms budget.
  func record() -> (AXUIElement?, Int, String) {
    let start = nowMs()
    let element = app
    AXUIElementSetMessagingTimeout(element, Float(recordBudgetMs) / 1000)
    let (error, value) = copyAttr(element, kAXFocusedWindowAttribute)
    guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
      return (nil, nowMs() - start, "focused_window_\(error.rawValue)")
    }
    let window = value as! AXUIElement
    let left = recordBudgetMs - (nowMs() - start)
    guard left > 0 else { return (nil, nowMs() - start, "budget") }
    AXUIElementSetMessagingTimeout(window, Float(left) / 1000)
    let subrole = stringAttr(window, kAXSubroleAttribute)
    AXUIElementSetMessagingTimeout(window, 0)
    guard subrole == (kAXStandardWindowSubrole as String) else {
      return (nil, nowMs() - start, "subrole_\(subrole ?? "nil")")
    }
    return (window, nowMs() - start, "recorded")
  }

  /// Bring a staging window front (setup and the user's "switch"; not the code under test).
  func stageFront(_ window: AXUIElement) -> Bool {
    for _ in 0..<10 {
      raiseAndActivate(window, remainingMs: 500)
      pump(0.15)
      if frontmostPid() == chromePid, gate(window) == .equal { return true }
    }
    return false
  }
}

// MARK: - Main

var trials = 10
var caseFilter: Set<String>? = nil
var variants = ["textarea", "editable"]
var argIterator = CommandLine.arguments.dropFirst().makeIterator()
while let arg = argIterator.next() {
  switch arg {
  case "--trials": trials = Int(argIterator.next() ?? "") ?? trials
  case "--cases":
    caseFilter = Set((argIterator.next() ?? "").split(separator: ",").map(String.init))
  case "--variants": variants = (argIterator.next() ?? "").split(separator: ",").map(String.init)
  default: fail("unknown argument \(arg)")
  }
}

guard AXIsProcessTrusted() else { fail("this terminal needs Accessibility") }
let ew = NSWorkspace.shared.runningApplications.filter {
  ($0.bundleIdentifier ?? "").hasPrefix("com.enviouswispr.app")
}
if !ew.isEmpty {
  fail(
    "EnviousWispr is running (\(ew.compactMap(\.bundleIdentifier))); quit it so nothing wakes Chrome"
  )
}

signal(SIGINT) { _ in
  Bench.shared?.cleanup()
  exit(130)
}

let bench = Bench()
var summary: [String: [String: Int]] = [:]
let waits = [0, 2, 5]
let chromeVersion =
  Bundle(path: "/Applications/Google Chrome.app")?.infoDictionary?["CFBundleShortVersionString"]
  as? String ?? "?"

for variant in variants {
  let editable = variant == "editable"
  let urlA = dataURL(pageA(editable: editable))
  bench.savedBoard = Board.save()
  bench.launch(pages: [urlA, dataURL(pageB(withField: false)), dataURL(pageB(withField: true))])
  pump(1.0)
  guard var winA = bench.window(tag: "A"), let winB = bench.window(tag: "B"),
    let winBF = bench.window(tag: "BF")
  else {
    fail(
      "fixture windows not found: \(bench.windows().map { stringAttr($0, kAXTitleAttribute) ?? "?" })"
    )
  }
  log([
    "event": "setup", "variant": variant, "chrome": chromeVersion,
    "macos": ProcessInfo.processInfo.operatingSystemVersionString, "pid": Int(bench.chromePid),
    "focus_sample": Int(bench.focusSample()),
  ])

  // Calibration: a direct paste into each fixture must be reported by its title.
  func calibrate(_ window: AXUIElement, tag: String, expectInsert: Bool) -> Bool {
    guard bench.stageFront(window) else {
      let (error, focused) = bench.focusedWindow()
      log([
        "event": "calibration", "variant": variant, "window": tag, "ok": false,
        "why": "stage_front", "front_is_chrome": bench.frontmostPid() == bench.chromePid,
        "focused_window_error": Int(error.rawValue),
        "focused_title": focused.flatMap { stringAttr($0, kAXTitleAttribute) } ?? "nil",
      ])
      return false
    }
    guard let before = bench.state(window) else {
      log([
        "event": "calibration", "variant": variant, "window": tag, "ok": false,
        "why": "title_unparsed", "title": stringAttr(window, kAXTitleAttribute) ?? "nil",
      ])
      return false
    }
    let token = "cal\(Int.random(in: 100000...999999))"
    bench.setToken(token)
    bench.safeCmdV()
    pump(0.6)
    guard let after = bench.state(window) else { return false }
    let ok =
      expectInsert
      ? occurrences(token, in: after.value) == 1 && after.inputs > before.inputs
      : after.pastes == before.pastes + 1 && after.value == before.value
    log([
      "event": "calibration", "variant": variant, "window": tag, "ok": ok,
      "before": "\(before)", "after": "\(after)",
    ])
    return ok
  }
  let calibrated =
    calibrate(winA, tag: "A", expectInsert: true)
    && calibrate(winB, tag: "B", expectInsert: false)
    && calibrate(winBF, tag: "BF", expectInsert: true)
  if !calibrated {
    log(["event": "harness_failure", "variant": variant, "reason": "calibration"])
    bench.cleanup()
    continue
  }

  for caseID in ["C1", "C2", "C3", "C5", "C6", "C4"] where caseFilter?.contains(caseID) ?? true {
    let n = caseID == "C4" ? min(5, trials) : trials
    var inconclusive = 0
    var valid = 0
    var attempt = 0
    var passes = 0
    while valid < n, inconclusive <= 2 {
      attempt += 1
      let wait = waits[attempt % waits.count]
      let settleMs = attempt % 2 == 0 ? 0 : 200
      var samples: [String: Int] = [:]
      guard bench.stageFront(winA) else { fail("could not stage A") }
      pump(0.3)
      samples["before_record"] = Int(bench.focusSample())
      guard let aBefore = bench.state(winA), let bBefore = bench.state(winB),
        let bfBefore = bench.state(winBF)
      else { fail("titles unreadable") }
      let (recordedOrNil, recordMs, recordReason) = bench.record()
      guard let recorded = recordedOrNil else {
        log([
          "event": "attempt", "variant": variant, "case": caseID, "attempt": attempt,
          "verdict": "inconclusive", "why": "record_\(recordReason)",
        ])
        inconclusive += 1
        continue
      }
      let identityAtRecord = CFEqual(recorded, winA)
      // The user's move during the take.
      switch caseID {
      case "C2": _ = bench.stageFront(winB)
      case "C3": _ = bench.stageFront(winBF)
      case "C5":
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?
          .activate()
      case "C6":
        _ = AXUIElementSetAttributeValue(winA, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
      case "C4":
        if let close = elementAttr(winA, kAXCloseButtonAttribute) {
          _ = AXUIElementPerformAction(close, kAXPressAction as CFString)
        }
      default: break
      }
      pump(Double(wait))
      samples["before_activation"] = Int(bench.focusSample())
      let token = "tok\(Int.random(in: 100000...999999))"
      bench.setToken(token)
      let activation = bench.activate(recorded: recorded)
      samples["after_raise"] = Int(bench.focusSample())
      pump(Double(settleMs) / 1000)
      // dispatchGate (:1571): front, window, front again. Only a positive mismatch refuses.
      var dispatched = false
      var dispatchGate = "not_front"
      if bench.frontmostPid() == bench.chromePid {
        let g = bench.gate(recorded)
        dispatchGate = g.rawValue
        if g != .mismatch, bench.frontmostPid() == bench.chromePid {
          bench.safeCmdV()
          dispatched = true
        }
      }
      pump(0.6)
      samples["after_paste"] = Int(bench.focusSample())
      var late: [Int] = []
      for _ in 0..<6 {
        pump(0.5)
        late.append(Int(bench.focusSample()))
      }
      let aAfter = caseID == "C4" ? nil : bench.state(winA)
      let bAfter = bench.state(winB)
      let bfAfter = bench.state(winBF)
      let asleep = samples.values.allSatisfy { $0 == -25212 } && late.allSatisfy { $0 == -25212 }
      let landedInA =
        aAfter.map { occurrences(token, in: $0.value) == 1 && $0.inputs > aBefore.inputs } ?? false
      let elsewhere = bAfter != bBefore || bfAfter != bfBefore
      var verdict: String
      if !asleep {
        verdict = "inconclusive"
        inconclusive += 1
      } else {
        valid += 1
        switch caseID {
        case "C4":
          verdict =
            activation.gate == .mismatch && dispatchGate == "mismatch" && !dispatched
            ? "pass" : "fail"
        case "C6": verdict = landedInA && !elsewhere ? "pass_info" : "fail_info"
        default: verdict = landedInA && !elsewhere ? "pass" : "fail"
        }
        if verdict.hasPrefix("pass") { passes += 1 }
      }
      log([
        "event": "attempt", "variant": variant, "case": caseID, "attempt": attempt, "wait_s": wait,
        "settle_ms": settleMs, "record_ms": recordMs, "identity_at_record": identityAtRecord,
        "activation_front": activation.front, "activation_gate": activation.gate.rawValue,
        "activation_ms": activation.elapsedMs, "dispatch_gate": dispatchGate,
        "dispatched": dispatched, "landed_in_a": landedInA, "elsewhere": elsewhere,
        "samples": samples, "late_samples": late, "verdict": verdict,
      ])
      // Undo the move for the next attempt.
      if caseID == "C6" {
        _ = AXUIElementSetAttributeValue(winA, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        pump(0.5)
      }
      if caseID == "C4" {
        bench.openWindow(urlA)
        pump(1.5)
        guard let reopened = bench.window(tag: "A") else { fail("could not reopen A") }
        winA = reopened
      }
    }
    summary["\(variant)/\(caseID)"] = [
      "valid": valid, "pass": passes, "inconclusive": inconclusive, "attempts": attempt,
    ]
    if inconclusive > 2 { log(["event": "sleep_unavailable", "variant": variant, "case": caseID]) }
  }
  bench.cleanup()
}

log(["event": "summary", "results": summary])
bench.cleanup()
