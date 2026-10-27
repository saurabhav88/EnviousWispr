import AppKit
import ApplicationServices
import EnviousWisprCore
import Darwin
import Foundation

/// Reads, through Accessibility, whether a call app is really in a call (#4012 §3.3, R4, C2):
/// the meeting page in a browser's front window, or a call app's meeting window. Only the
/// classification and an in-memory room key leave this type: no address, title or page text
/// is stored, logged or sent. Every read has a short Accessibility timeout and runs off the
/// main actor; a timeout or missing trust is `.unknown`, never "no call".
public enum CallEvidenceReader {
  public enum Evidence: Sendable, Equatable {
    case call(family: CallAppFamily, room: String)
    case none
    case unknown
  }

  /// Seconds an Accessibility message may take before the read gives up.
  static let messagingTimeout: Float = 0.25

  /// Per-read system boundary. Tests supply local handles and never message another app.
  package struct Access {
    package var now: () -> ContinuousClock.Instant
    package var setTimeout: (AXUIElement, Float) -> AXError
    package var read: (AXUIElement, CFString) -> CopyResult

    package init(
      now: @escaping () -> ContinuousClock.Instant,
      setTimeout: @escaping (AXUIElement, Float) -> AXError,
      read: @escaping (AXUIElement, CFString) -> CopyResult
    ) {
      self.now = now
      self.setTimeout = setTimeout
      self.read = read
    }

    package static var live: Self {
      Self(
        now: { .now },
        setTimeout: { AXUIElementSetMessagingTimeout($0, $1) },
        read: { copy($0, $1) })
    }
  }

  /// The evidence for a microphone-holding process of `rule`, `holderPID` being that process.
  public static func evidence(for rule: CallAppCatalog.Rule, holderPID: Int32) -> Evidence {
    guard AXIsProcessTrusted() else { return .unknown }
    switch rule {
    case .callApp(let family):
      // A calling app's microphone use is its call (Wispr Flow's rule); the process is the room.
      return .call(family: family, room: "pid-\(holderPID)")
    case .callWindow(let family):
      guard let app = runningApp(family: family, holderPID: holderPID) else { return .unknown }
      return callWindow(family: family, appPID: app.processIdentifier)
    case .browser(let browser):
      guard let app = browserApp(browser, holderPID: holderPID) else { return .unknown }
      return meetingPage(appPID: app.processIdentifier)
    }
  }

  /// The browser window owner for a microphone holder: the holder itself, else the app bundle
  /// its executable lives in, else the only running copy of that browser. Two copies running
  /// (Chrome and Chrome Beta) with no way to tell which holds the microphone is unknown,
  /// never a guess.
  private static func browserApp(_ browser: CallAppCatalog.Browser, holderPID: Int32)
    -> NSRunningApplication?
  {
    let running = NSWorkspace.shared.runningApplications.filter {
      browser.appBundleIDs.contains(($0.bundleIdentifier ?? "").lowercased())
    }
    if let own = running.first(where: { $0.processIdentifier == holderPID }) { return own }
    if let path = executablePath(holderPID),
      let appPath = CallAppCatalog.owningAppPath(ofExecutable: path),
      let owner = running.first(where: { $0.bundleURL?.path == appPath })
    {
      return owner
    }
    return running.count == 1 ? running[0] : nil
  }

  private static func executablePath(_ pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(cString: buffer)
  }

  private static func runningApp(family: CallAppFamily, holderPID: Int32) -> NSRunningApplication? {
    if let app = NSRunningApplication(processIdentifier: holderPID),
      app.activationPolicy == .regular
    {
      return app
    }
    let ids: [String] =
      switch family {
      case .zoom: ["us.zoom.xos"]
      case .slack: ["com.tinyspeck.slackmacgap"]
      default: []
      }
    return NSWorkspace.shared.runningApplications.first {
      ids.contains(($0.bundleIdentifier ?? "").lowercased())
    }
  }

  /// Zoom: a meeting window in any Zoom language (`ZoomCallWindow`, #4036; the main
  /// "Zoom Workplace" window is not a call). Slack: a huddle window.
  package static func callWindow(
    family: CallAppFamily, appPID: pid_t, access: Access = .live
  ) -> Evidence {
    let isCall: Bool
    switch family {
    case .zoom:
      switch zoomMeetingWindow(appPID: appPID, access: access) {
      case .call: isCall = true
      case .none: isCall = false
      case .unknown: return .unknown
      }
    case .slack:
      switch slackHuddleWindow(appPID: appPID) {
      case .call: isCall = true
      case .none: isCall = false
      case .unknown: return .unknown
      }
    default:
      isCall = false
    }
    return isCall ? .call(family: family, room: "pid-\(appPID)") : .none
  }

  /// Slack's Leave control is independent of its UI language and channel/window name (#4036).
  private static func slackHuddleWindow(appPID: pid_t) -> SlackHuddleWindow.Verdict {
    // Same one-second budget as CallEvidenceRead.bounded; do not leave its shared lane busy.
    let deadline = scanDeadline(.live)
    let wake = AccessibilityWake.wake(pid: appPID, messagingTimeout: Double(messagingTimeout))
    guard wake.roleError == .success, !wake.roleReadExhausted,
      let manual = wake.manual, !manual || wake.manualEnabled
    else { return .unknown }
    let app = AXUIElementCreateApplication(appPID)
    guard case .value(let value) = boundedCopy(app, kAXWindowsAttribute as CFString, until: deadline),
      let windows = value as? [AXUIElement]
    else { return .unknown }
    return SlackHuddleWindow.classify(
      windowCount: windows.count,
      identifier: { slackHuddleControl(in: windows[$0], until: deadline) },
      title: {
        switch boundedCopy(windows[$0], kAXTitleAttribute as CFString, until: deadline) {
        case .value(let value): (value as? String).map { .value($0) } ?? .failed
        case .missing: .missing
        case .failed, .unavailable: .failed
        }
      })
  }

  /// The saved Slack trees reach depth 27. Unsearched children never mean no huddle.
  private static func slackHuddleControl(
    in window: AXUIElement, until deadline: ContinuousClock.Instant
  ) -> SlackHuddleWindow.Read {
    var queue: [(AXUIElement, Int)] = [(window, 0)]
    var visited = 0
    var complete = true
    while !queue.isEmpty, visited < 800, ContinuousClock.now < deadline {
      let (node, level) = queue.removeFirst()
      visited += 1
      switch boundedCopy(node, kAXRoleAttribute as CFString, until: deadline) {
      case .value(let role) where (role as? String) == "AXButton":
        switch boundedCopy(node, "AXDOMClassList" as CFString, until: deadline) {
        case .value(let value):
          switch SlackHuddleWindow.classRead(value) {
          case .value(let token): return .value(token)
          case .failed: complete = false
          case .missing: break
          }
        case .missing: break
        case .failed, .unavailable: complete = false
        }
      case .value(let role) where role is String: break
      default: complete = false
      }
      switch boundedCopy(node, kAXChildrenAttribute as CFString, until: deadline) {
      case .value(let value):
        guard let children = value as? [AXUIElement] else { complete = false; continue }
        guard level < 32 else {
          if !children.isEmpty { complete = false }
          continue
        }
        queue.append(contentsOf: children.map { ($0, level + 1) })
      case .missing: break
      case .failed, .unavailable: complete = false
      }
    }
    if !queue.isEmpty { complete = false }
    return complete ? .missing : .failed
  }

  /// AX timeouts belong to each exact handle, not to equal handles or app descendants (#4127).
  /// An unavailable budget/setup is distinct from an attempted read failing: browser wake
  /// preserves its side effect even when the role read quickly returns an error.
  package static func boundedCopy(
    _ element: AXUIElement, _ attribute: CFString, until deadline: ContinuousClock.Instant,
    access: Access = .live
  ) -> CopyResult {
    let remaining = access.now().duration(to: deadline).components
    let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
    guard seconds > 0,
      access.setTimeout(element, min(messagingTimeout, Float(seconds))) == .success,
      access.now() < deadline
    else { return .unavailable }
    let result = access.read(element, attribute)
    return access.now() < deadline ? result : .unavailable
  }

  /// Matches the caller's existing one-second allowance. This bounds AX work, not OS scheduling.
  private static func scanDeadline(_ access: Access) -> ContinuousClock.Instant {
    access.now().advanced(by: .seconds(1))
  }

  /// Reads each Zoom window's identifier, then its title, only until one proves a meeting.
  private static func zoomMeetingWindow(appPID: pid_t, access: Access) -> ZoomCallWindow.Verdict {
    let deadline = scanDeadline(access)
    let app = AXUIElementCreateApplication(appPID)
    guard case .value(let value) = boundedCopy(
      app, kAXWindowsAttribute as CFString, until: deadline, access: access),
      let windows = value as? [AXUIElement]
    else { return .unknown }
    var failed = false
    for window in windows {
      guard access.now() < deadline else { return .unknown }
      // The classifier's count-one form preserves identifier-first/positive-wins behavior;
      // this reader owns iteration so an expired budget stops the remaining windows too.
      switch ZoomCallWindow.classify(
        windowCount: 1,
        identifier: { _ in
          stringRead(window, kAXIdentifierAttribute as CFString, until: deadline, access: access)
        },
        title: { _ in
          stringRead(window, kAXTitleAttribute as CFString, until: deadline, access: access)
        })
      {
      case .call: return .call
      case .unknown: failed = true
      case .none: break
      }
    }
    return failed ? .unknown : .none
  }

  private static func stringRead(
    _ element: AXUIElement, _ attribute: CFString, until deadline: ContinuousClock.Instant,
    access: Access
  ) -> ZoomCallWindow.Read {
    switch boundedCopy(element, attribute, until: deadline, access: access) {
    case .value(let value): (value as? String).map { .value($0) } ?? .missing
    case .missing: .missing
    case .failed, .unavailable: .failed
    }
  }

  /// The front window's web page address: the first `AXWebArea`'s `AXURL` within a bounded
  /// walk, else the window's `AXDocument`. Without a readable address, an incomplete walk
  /// is `.unknown`; a readable document address remains authoritative after a partial walk.
  package static func meetingPage(appPID: pid_t, access: Access = .live) -> Evidence {
    let deadline = scanDeadline(access)
    let app = AXUIElementCreateApplication(appPID)
    // AXRole itself wakes Chromium (#3802). Its value/error is not a capability gate:
    // preserve the old quick-error continuation, but never message without a checked allowance.
    if case .unavailable = boundedCopy(
      app, kAXRoleAttribute as CFString, until: deadline, access: access)
    { return .unknown }
    guard case .value(let windowRef) = boundedCopy(
      app, kAXFocusedWindowAttribute as CFString, until: deadline, access: access),
      CFGetTypeID(windowRef) == AXUIElementGetTypeID()
    else { return .unknown }
    let window = windowRef as! AXUIElement
    let walk = url(in: window, until: deadline, access: access)
    var address = walk.url
    if address == nil {
      switch boundedCopy(window, kAXDocumentAttribute as CFString, until: deadline, access: access) {
      case .value(let value): address = value as? String
      case .missing: break
      case .failed, .unavailable: return .unknown
      }
    }
    guard let address else { return walk.complete ? .none : .unknown }
    guard let match = CallMeetingURL.classify(address) else { return .none }
    return .call(family: match.family, room: match.room)
  }

  /// Breadth-first, at most 12 levels and 400 elements: browser trees are deep, and a page
  /// with a huge tree must not stall the read. `complete` is false when a read on the way failed.
  private static func url(
    in root: AXUIElement, until deadline: ContinuousClock.Instant, access: Access
  ) -> (url: String?, complete: Bool) {
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    var visited = 0
    var complete = true
    while !queue.isEmpty, visited < 400, access.now() < deadline {
      let (node, level) = queue.removeFirst()
      visited += 1
      switch boundedCopy(node, kAXRoleAttribute as CFString, until: deadline, access: access) {
      case .value(let role) where (role as? String) == "AXWebArea":
        switch boundedCopy(node, kAXURLAttribute as CFString, until: deadline, access: access) {
        case .value(let value):
          if let link = (value as? URL)?.absoluteString ?? (value as? String) { return (link, true) }
        case .missing: break
        case .failed, .unavailable: complete = false
        }
      case .failed, .unavailable: complete = false
      default: break
      }
      switch boundedCopy(node, kAXChildrenAttribute as CFString, until: deadline, access: access) {
      case .value(let value):
        let children = (value as? [AXUIElement]) ?? []
        // A level the walk will not enter is part of the page it did not see (r6 F5).
        guard level < 12 else {
          if !children.isEmpty { complete = false }
          continue
        }
        queue.append(contentsOf: children.map { ($0, level + 1) })
      case .missing: break
      case .failed, .unavailable: complete = false
      }
    }
    // Stopped at the element limit with elements still waiting: not a full search (r6 F5).
    if !queue.isEmpty { complete = false }
    return (nil, complete)
  }

  // MARK: - Accessibility reads

  package enum CopyResult {
    case value(CFTypeRef)
    /// The element has no such attribute, or no value for it now.
    case missing
    /// The read itself failed (timeout, app busy, API off): could not tell.
    case failed
    /// Timeout setup was refused, or the scan's deadline made the response unusable.
    case unavailable
  }

  private static func copy(_ element: AXUIElement, _ attribute: CFString) -> CopyResult {
    var value: CFTypeRef?
    switch AXUIElementCopyAttributeValue(element, attribute, &value) {
    case .success: return value.map { .value($0) } ?? .missing
    case .noValue, .attributeUnsupported: return .missing
    default: return .failed
    }
  }
}
