import AppKit
import ApplicationServices
import EnviousWisprCore
import Darwin
import Foundation

/// Reads, through Accessibility, whether a call app is really in a call (#4012 §3.3, R4, C2):
/// the meeting page in a browser's front window, or a call app's meeting window. Only the
/// typed evidence, in-memory room key and verified app-run metadata leave this type: no
/// address, title or page text is stored, logged or sent. Every read has a short Accessibility
/// timeout and runs off the main actor; missing trust or timeout is `.unknown`, never "no call".
public enum CallEvidenceReader {
  public enum Evidence: Sendable, Equatable {
    case call(family: CallAppFamily, room: String)
    /// Calling-app microphone activity without independent call proof; eligible only for Ask.
    case microphoneOnly(family: CallAppFamily, room: String)
    case none
    case unknown
  }

  /// Start eligibility and call lifetime are different observations. A URL alone is not ongoing proof.
  package enum Continuity: Sendable, Equatable {
    case ongoing(family: CallAppFamily, room: String)
    case ended(family: CallAppFamily, room: String)
    case unknown
  }

  /// Process birth is an identity discriminator, never an observation/freshness timestamp.
  package struct AppRun: Sendable, Equatable, Hashable {
    package let pid: Int32
    package let bundleIdentifier: String
    package let birthSeconds: UInt64
    package let birthMicroseconds: UInt64

    package init(pid: Int32, bundleIdentifier: String, birthSeconds: UInt64, birthMicroseconds: UInt64) {
      self.pid = pid
      self.bundleIdentifier = bundleIdentifier.lowercased()
      self.birthSeconds = birthSeconds
      self.birthMicroseconds = birthMicroseconds
    }
  }

  /// Historical attribution for one tracked call, not permission to resolve another owner.
  package struct RetainedTarget: Sendable, Equatable {
    package let rule: CallAppCatalog.Rule
    package let holderPID: Int32
    package let owner: AppRun
    package let family: CallAppFamily
    package let room: String

    package init(
      rule: CallAppCatalog.Rule, holderPID: Int32, owner: AppRun, family: CallAppFamily, room: String
    ) {
      self.rule = rule
      self.holderPID = holderPID
      self.owner = owner
      self.family = family
      self.room = room
    }

    package func accepts(_ value: Continuity) -> Bool {
      switch value {
      case .ongoing(let family, let room), .ended(let family, let room):
        return family == self.family && room == self.room
      case .unknown: return true
      }
    }
  }

  package struct Snapshot: Sendable, Equatable {
    package let startEvidence: Evidence
    package let continuity: Continuity
    /// Only the production entry attributes a run; the testable protected scan entries omit it.
    package let owner: AppRun?

    package init(startEvidence: Evidence, continuity: Continuity = .unknown, owner: AppRun? = nil) {
      self.startEvidence = startEvidence
      self.continuity = continuity
      self.owner = owner
    }
  }

  /// Seconds an Accessibility message may take before the read gives up.
  static let messagingTimeout: Float = 0.25

  /// Per-read system boundary. Tests supply local handles and never message another app.
  package struct Access {
    package var now: () -> ContinuousClock.Instant
    package var setTimeout: (AXUIElement, Float) -> AXError
    package var read: (AXUIElement, CFString) -> CopyResult
    package var wake: (pid_t, Double) -> AccessibilityWake.Report
    package var regularTeamsPIDs: () -> [Int32]
    package var isTrusted: () -> Bool
    package var appOwner: (CallAppCatalog.Rule, Int32) -> (pid: Int32, unambiguous: Bool)?
    package var appRun: (Int32) -> AppRun?

    package init(
      now: @escaping () -> ContinuousClock.Instant,
      setTimeout: @escaping (AXUIElement, Float) -> AXError,
      read: @escaping (AXUIElement, CFString) -> CopyResult,
      wake: @escaping (pid_t, Double) -> AccessibilityWake.Report,
      regularTeamsPIDs: @escaping () -> [Int32],
      isTrusted: (() -> Bool)? = nil,
      appOwner: ((CallAppCatalog.Rule, Int32) -> (pid: Int32, unambiguous: Bool)?)? = nil,
      appRun: ((Int32) -> AppRun?)? = nil
    ) {
      self.now = now
      self.setTimeout = setTimeout
      self.read = read
      self.wake = wake
      self.regularTeamsPIDs = regularTeamsPIDs
      self.isTrusted = isTrusted ?? { AXIsProcessTrusted() }
      self.appOwner = appOwner ?? { liveOwner(for: $0, holderPID: $1) }
      self.appRun = appRun ?? { liveAppRun($0) }
    }

    package static var live: Self {
      Self(
        now: { .now },
        setTimeout: { AXUIElementSetMessagingTimeout($0, $1) },
        read: { copy($0, $1) },
        wake: { AccessibilityWake.wake(pid: $0, messagingTimeout: $1) },
        regularTeamsPIDs: { liveTeamsPIDs() })
    }
  }

  /// The evidence for a microphone-holding process of `rule`, `holderPID` being that process.
  public static func evidence(for rule: CallAppCatalog.Rule, holderPID: Int32) -> Evidence {
    snapshot(for: rule, holderPID: holderPID).startEvidence
  }

  package static func snapshot(
    for rule: CallAppCatalog.Rule, holderPID: Int32, access: Access = .live
  ) -> Snapshot {
    let deadline = scanDeadline(access)
    guard access.isTrusted(), access.now() < deadline else { return .init(startEvidence: .unknown) }
    switch rule {
    case .callApp(let family):
      let selected: (pid: Int32, unambiguous: Bool)?
      if family == .teams {
        selected = teamsOwnerPID(holderPID: holderPID, regularTeamsPIDs: access.regularTeamsPIDs())
          .map { (pid: $0, unambiguous: true) }
      } else { selected = access.appOwner(rule, holderPID) }
      guard let selected else {
        return .init(startEvidence: family == .teams
          ? .microphoneOnly(family: family, room: "pid-\(holderPID)")
          : .call(family: family, room: "pid-\(holderPID)"))
      }
      return attributed(selected, rule: rule, until: deadline, access: access) {
        nativeCallSnapshot(family: family, holderPID: holderPID, ownerPID: selected.pid,
          until: deadline, access: access)
      }
    case .callWindow(let family):
      guard let selected = access.appOwner(rule, holderPID)
      else { return .init(startEvidence: .unknown) }
      return attributed(selected, rule: rule, until: deadline, access: access) {
        callWindowSnapshot(family: family, appPID: selected.pid, until: deadline, access: access)
      }
    case .browser:
      guard let selected = access.appOwner(rule, holderPID)
      else { return .init(startEvidence: .unknown) }
      return attributed(selected, rule: rule, until: deadline, access: access) {
        meetingPageSnapshot(appPID: selected.pid, until: deadline, access: access)
      }
    }
  }

  /// No microphone fact or new start eligibility can be obtained from a retained owner.
  package static func snapshot(for target: RetainedTarget, access: Access = .live) -> Snapshot {
    let deadline = scanDeadline(access)
    guard access.isTrusted(), access.now() < deadline else { return .init(startEvidence: .unknown) }
    let value = attributed((pid: target.owner.pid, unambiguous: true), rule: target.rule,
      until: deadline, access: access, requiredOwner: target.owner) {
        switch target.rule {
        case .callApp(let family):
          return nativeCallSnapshot(family: family, holderPID: target.holderPID,
            ownerPID: target.owner.pid, until: deadline, access: access, fixedOwner: true)
        case .callWindow(let family):
          return callWindowSnapshot(family: family, appPID: target.owner.pid,
            until: deadline, access: access)
        case .browser:
          return meetingPageSnapshot(appPID: target.owner.pid, until: deadline, access: access)
        }
      }
    return .init(startEvidence: .unknown,
      continuity: target.accepts(value.continuity) ? value.continuity : .unknown, owner: value.owner)
  }

  private static func attributed(
    _ selected: (pid: Int32, unambiguous: Bool), rule: CallAppCatalog.Rule,
    until deadline: ContinuousClock.Instant, access: Access, requiredOwner: AppRun? = nil,
    read: () -> Snapshot
  ) -> Snapshot {
    guard access.now() < deadline else { return .init(startEvidence: .unknown) }
    let before = selected.unambiguous ? access.appRun(selected.pid) : nil
    guard access.now() < deadline else { return .init(startEvidence: .unknown) }
    if let requiredOwner {
      guard before == requiredOwner, validOwner(requiredOwner, pid: selected.pid, rule: rule)
      else { return .init(startEvidence: .unknown) }
    }
    let value = read()
    guard let before, validOwner(before, pid: selected.pid, rule: rule),
      access.now() < deadline, access.appRun(selected.pid) == before, access.now() < deadline
    else { return .init(startEvidence: value.startEvidence) }
    return .init(startEvidence: value.startEvidence, continuity: value.continuity, owner: before)
  }

  private static func validOwner(_ owner: AppRun, pid: Int32, rule: CallAppCatalog.Rule) -> Bool {
    owner.pid == pid && owner.birthSeconds > 0 && owner.birthMicroseconds < 1_000_000
      && matches(owner.bundleIdentifier, rule: rule)
  }

  private static func matches(_ bundle: String, rule: CallAppCatalog.Rule) -> Bool {
    switch rule {
    case .callApp(let family), .callWindow(let family):
      return CallAppCatalog.nativeApps.filter { $0.family == family }
        .flatMap(\.appBundleIDs).contains { $0.lowercased() == bundle }
    case .browser(let browser):
      return browser.appBundleIDs.contains { $0.lowercased() == bundle }
    }
  }

  package static func nativeCallEvidence(
    family: CallAppFamily, holderPID: Int32, access: Access = .live
  ) -> Evidence {
    nativeCallSnapshot(family: family, holderPID: holderPID, access: access).startEvidence
  }

  package static func nativeCallSnapshot(
    family: CallAppFamily, holderPID: Int32, access: Access = .live
  ) -> Snapshot {
    let owner = family == .teams
      ? teamsOwnerPID(holderPID: holderPID, regularTeamsPIDs: access.regularTeamsPIDs()) : nil
    return nativeCallSnapshot(family: family, holderPID: holderPID, ownerPID: owner,
      until: scanDeadline(access), access: access)
  }

  private static func nativeCallSnapshot(
    family: CallAppFamily, holderPID: Int32, ownerPID: Int32?,
    until deadline: ContinuousClock.Instant, access: Access, fixedOwner: Bool = false
  ) -> Snapshot {
    let room = "pid-\(holderPID)"
    guard family == .teams else {
      // A calling app's microphone use is its call (Wispr Flow's rule); the process is the room.
      return .init(startEvidence: .call(family: family, room: room))
    }
    // Teams' pre-join microphone test also captures audio (#4094). Only the observed exact
    // hang-up button proves a call for automatic recording; uncertainty still permits Ask.
    let unproven = Snapshot(startEvidence: .microphoneOnly(family: family, room: room))
    guard let owner = ownerPID
    else { return unproven }
    let wake = access.wake(owner, Double(messagingTimeout))
    guard wake.roleError == .success, !wake.roleReadExhausted,
      let manual = wake.manual, !manual || wake.manualEnabled,
      access.now() < deadline
    else { return unproven }
    let app = AXUIElementCreateApplication(owner)
    guard case .value(let value) = boundedCopy(
      app, kAXWindowsAttribute as CFString, until: deadline, access: access),
      let windows = value as? [AXUIElement]
    else { return unproven }
    var allHome = !windows.isEmpty
    for window in windows {
      guard access.now() < deadline else { return unproven }
      switch teamsWindow(in: window, until: deadline, access: access) {
      case .ongoing:
        return .init(startEvidence: .call(family: family, room: room),
          continuity: .ongoing(family: family, room: room))
      case .home: break
      case .unknown: allHome = false
      }
    }
    // A home marker never substitutes for the other windows or an unchanged owner/window set.
    guard allHome,
      (fixedOwner || teamsOwnerPID(holderPID: holderPID, regularTeamsPIDs: access.regularTeamsPIDs()) == owner),
      case .value(let currentValue) = boundedCopy(
        app, kAXWindowsAttribute as CFString, until: deadline, access: access),
      let current = currentValue as? [AXUIElement], current.count == windows.count,
      windows.enumerated().allSatisfy({ index, window in
        !windows.prefix(index).contains(where: { CFEqual($0, window) })
          && current.filter { CFEqual($0, window) }.count == 1
      })
    else { return unproven }
    return .init(startEvidence: .none, continuity: .ended(family: family, room: room))
  }

  private enum TeamsWindow { case ongoing, home, unknown }

  private static func teamsWindow(
    in window: AXUIElement, until deadline: ContinuousClock.Instant, access: Access
  ) -> TeamsWindow {
    var complete = true
    var home = false
    var preview = false
    var recognizedWindow = false
    var supportedScope = true
    let visible: Bool
    if case .value(let minimized) = boundedCopy(
      window, kAXMinimizedAttribute as CFString, until: deadline, access: access),
      CFGetTypeID(minimized) == CFBooleanGetTypeID(), (minimized as? Bool) == false
    { visible = true }
    else { visible = false }
    var queue: [(AXUIElement, Int)] = [(window, 0)]
    var cursor = 0
    while cursor < queue.count, cursor < 800, access.now() < deadline {
      let (node, level) = queue[cursor]
      cursor += 1
      let role: String?
      if case .value(let rawRole) = boundedCopy(
        node, kAXRoleAttribute as CFString, until: deadline, access: access),
        let text = rawRole as? String, !text.isEmpty
      { role = text }
      else { role = nil; complete = false }
      if CFEqual(node, window) { recognizedWindow = role == "AXWindow" }
      // A readable subtree is not necessarily supported non-call UI. Modal, nested-window
      // and embedded-document scopes cannot borrow a home table elsewhere in this window.
      // Keep searching them for positive hang-up proof, but never infer end from them.
      if role == "AXSheet" || role == "AXDialog" || role == "AXSystemDialog"
        || role == "AXDrawer" || role == "AXWebArea"
        || (role == "AXWindow" && !CFEqual(node, window))
      { supportedScope = false }
      if role == "AXButton" {
        switch boundedCopy(node, "AXDOMIdentifier" as CFString, until: deadline, access: access) {
        case .value(let value):
          if let identifier = value as? String {
            if identifier == "hangup-button" { return .ongoing }
            if identifier == "prejoin-join-button" { preview = true }
          } else { complete = false }
        case .missing: break
        case .failed, .unavailable: complete = false
        }
      } else if role == "AXTable" {
        let title = controlText(node, kAXTitleAttribute as CFString, until: deadline, access: access)
        let description = controlText(
          node, kAXDescriptionAttribute as CFString, until: deadline, access: access)
        if !title.valid || !description.valid { complete = false }
        if title.text == "Meet navigation", description.text == "Meet navigation" { home = true }
      }
      switch boundedCopy(node, kAXChildrenAttribute as CFString, until: deadline, access: access) {
      case .value(let value):
        guard let children = value as? [AXUIElement] else { complete = false; continue }
        if level < 32 { queue.append(contentsOf: children.map { ($0, level + 1) }) }
        else if !children.isEmpty { complete = false }
      case .missing: break
      case .failed, .unavailable: complete = false
      }
    }
    if cursor < queue.count || access.now() >= deadline { complete = false }
    return complete && supportedScope && recognizedWindow && visible && home && !preview ? .home : .unknown
  }

  /// A helper may hold the microphone; inspect only an unambiguous regular Teams owner.
  package static func teamsOwnerPID(holderPID: Int32, regularTeamsPIDs: [Int32]) -> Int32? {
    let candidates = Set(regularTeamsPIDs)
    if candidates.contains(holderPID) { return holderPID }
    return candidates.count == 1 ? candidates.first : nil
  }

  private static func liveTeamsPIDs() -> [Int32] {
    let ids = Set(CallAppCatalog.nativeApps.filter { $0.family == .teams }
      .flatMap(\.appBundleIDs).map { $0.lowercased() })
    return NSWorkspace.shared.runningApplications.compactMap { app in
      guard app.activationPolicy == .regular,
        let id = app.bundleIdentifier, ids.contains(id.lowercased())
      else { return nil }
      return app.processIdentifier
    }
  }

  private static func liveOwner(
    for rule: CallAppCatalog.Rule, holderPID: Int32
  ) -> (pid: Int32, unambiguous: Bool)? {
    switch rule {
    case .callApp(let family), .callWindow(let family):
      return runningApp(family: family, holderPID: holderPID)
        .map { (pid: $0.app.processIdentifier, unambiguous: $0.unambiguous) }
    case .browser(let browser):
      return browserApp(browser, holderPID: holderPID)
        .map { (pid: $0.processIdentifier, unambiguous: true) }
    }
  }

  private static func liveAppRun(_ pid: Int32) -> AppRun? {
    guard let app = NSRunningApplication(processIdentifier: pid),
      app.activationPolicy == .regular, let bundle = app.bundleIdentifier
    else { return nil }
    // Same Darwin birth lookup as TerminalProcessScanner, retaining microseconds too.
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
      info.pbi_start_tvsec > 0, info.pbi_start_tvusec < 1_000_000
    else { return nil }
    return .init(pid: pid, bundleIdentifier: bundle, birthSeconds: UInt64(info.pbi_start_tvsec),
      birthMicroseconds: UInt64(info.pbi_start_tvusec))
  }

  /// The browser window owner for a microphone holder: the holder itself, else the app bundle
  /// its executable lives in, else the only running copy of that browser. Two copies running
  /// (Chrome and Chrome Beta) with no way to tell which holds the microphone is unknown,
  /// never a guess.
  /// The app call detection reads for a microphone-holding process of `rule`: a browser or
  /// window-checked call app's own app instance. Nil for a native call app (it is read by its
  /// own process) or when no instance can be told.
  package static func app(for rule: CallAppCatalog.Rule, holderPID: Int32) -> NSRunningApplication?
  {
    switch rule {
    case .callApp: return nil
    case .callWindow(let family):
      guard let selected = runningApp(family: family, holderPID: holderPID), selected.unambiguous
      else { return nil }
      return selected.app
    case .browser(let browser): return browserApp(browser, holderPID: holderPID)
    }
  }

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

  private static func runningApp(
    family: CallAppFamily, holderPID: Int32
  ) -> (app: NSRunningApplication, unambiguous: Bool)? {
    if let app = NSRunningApplication(processIdentifier: holderPID),
      app.activationPolicy == .regular
    {
      return (app, true)
    }
    let ids: [String] =
      switch family {
      case .zoom: ["us.zoom.xos"]
      case .slack: ["com.tinyspeck.slackmacgap"]
      default: []
      }
    let candidates = NSWorkspace.shared.runningApplications.filter {
      ids.contains(($0.bundleIdentifier ?? "").lowercased())
    }
    return candidates.first.map { ($0, candidates.count == 1) }
  }

  /// Zoom: a meeting window in any Zoom language (`ZoomCallWindow`, #4036; the main
  /// "Zoom Workplace" window is not a call). Slack: a huddle window.
  package static func callWindow(
    family: CallAppFamily, appPID: pid_t, access: Access = .live
  ) -> Evidence {
    callWindowSnapshot(family: family, appPID: appPID, access: access).startEvidence
  }

  package static func callWindowSnapshot(
    family: CallAppFamily, appPID: pid_t, access: Access = .live
  ) -> Snapshot {
    callWindowSnapshot(family: family, appPID: appPID, until: scanDeadline(access), access: access)
  }

  private static func callWindowSnapshot(
    family: CallAppFamily, appPID: pid_t, until deadline: ContinuousClock.Instant, access: Access
  ) -> Snapshot {
    switch family {
    case .zoom: return zoomMeetingWindow(appPID: appPID, until: deadline, access: access)
    case .slack: return slackHuddleWindow(appPID: appPID, until: deadline, access: access)
    default: return .init(startEvidence: .none)
    }
  }

  /// Slack's Leave control is independent of its UI language and channel/window name (#4036).
  private static func slackHuddleWindow(
    appPID: pid_t, until deadline: ContinuousClock.Instant, access: Access
  ) -> Snapshot {
    // Same one-second budget as CallEvidenceRead.bounded; do not leave its shared lane busy.
    let wake = access.wake(appPID, Double(messagingTimeout))
    guard wake.roleError == .success, !wake.roleReadExhausted,
      let manual = wake.manual, !manual || wake.manualEnabled,
      access.now() < deadline
    else { return .init(startEvidence: .unknown) }
    let app = AXUIElementCreateApplication(appPID)
    guard case .value(let value) = boundedCopy(app, kAXWindowsAttribute as CFString, until: deadline, access: access),
      let windows = value as? [AXUIElement]
    else { return .init(startEvidence: .unknown) }
    let call = Evidence.call(family: .slack, room: "pid-\(appPID)")
    var failed = false
    for window in windows {
      guard access.now() < deadline else { return .init(startEvidence: .unknown) }
      var exact = false
      let verdict = SlackHuddleWindow.classify(
        windowCount: 1,
        identifier: { _ in
          let read = slackHuddleControl(in: window, until: deadline, access: access)
          if case .value(let value) = read, value == SlackHuddleWindow.leaveClass { exact = true }
          return read
        },
        title: { _ in
          switch boundedCopy(window, kAXTitleAttribute as CFString, until: deadline, access: access) {
          case .value(let value): (value as? String).map { .value($0) } ?? .failed
          case .missing: .missing
          case .failed, .unavailable: .failed
          }
        })
      if exact {
        return .init(startEvidence: call, continuity: .ongoing(family: .slack, room: "pid-\(appPID)"))
      }
      switch verdict {
      // Preserve immediate admission at the outer worker boundary. Optional lookahead
      // can exhaust that worker's budget and discard an already justified prompt.
      case .call: return .init(startEvidence: call)
      case .unknown: failed = true
      case .none: break
      }
    }
    return .init(startEvidence: failed ? .unknown : .none)
  }

  private static func slackHuddleControl(
    in window: AXUIElement, until deadline: ContinuousClock.Instant, access: Access
  ) -> SlackHuddleWindow.Read {
    switch callButton(
      in: window, until: deadline, access: access, attribute: "AXDOMClassList" as CFString,
      matches: { value in
        switch SlackHuddleWindow.classRead(value) {
        case .value: true
        case .missing: false
        case .failed: nil
        }
      })
    {
    case .found: return .value(SlackHuddleWindow.leaveClass)
    case .missing: return .missing
    case .failed: return .failed
    }
  }

  private enum ButtonSearch { case found, missing, failed }

  /// The saved Slack trees reach depth 27. Unsearched children never mean no huddle.
  private static func callButton(
    in window: AXUIElement, until deadline: ContinuousClock.Instant, access: Access,
    attribute: CFString, matches: (CFTypeRef) -> Bool?
  ) -> ButtonSearch {
    var queue: [(AXUIElement, Int)] = [(window, 0)]
    var visited = 0
    var complete = true
    while !queue.isEmpty, visited < 800, access.now() < deadline {
      let (node, level) = queue.removeFirst()
      visited += 1
      switch boundedCopy(node, kAXRoleAttribute as CFString, until: deadline, access: access) {
      case .value(let role) where (role as? String) == "AXButton":
        switch boundedCopy(node, attribute, until: deadline, access: access) {
        case .value(let value):
          switch matches(value) {
          case true?: return .found
          case false?: break
          case nil: complete = false
          }
        case .missing: break
        case .failed, .unavailable: complete = false
        }
      case .value(let role) where role is String: break
      default: complete = false
      }
      switch boundedCopy(node, kAXChildrenAttribute as CFString, until: deadline, access: access) {
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
  private static func zoomMeetingWindow(
    appPID: pid_t, until deadline: ContinuousClock.Instant, access: Access
  ) -> Snapshot {
    let app = AXUIElementCreateApplication(appPID)
    guard case .value(let value) = boundedCopy(
      app, kAXWindowsAttribute as CFString, until: deadline, access: access),
      let windows = value as? [AXUIElement]
    else { return .init(startEvidence: .unknown) }
    let call = Evidence.call(family: .zoom, room: "pid-\(appPID)")
    var failed = false
    var leaveOngoing = false
    var homeIdentifierMissing = false
    for window in windows {
      guard access.now() < deadline else { return .init(startEvidence: .unknown) }
      // The classifier's count-one form preserves identifier-first/positive-wins behavior;
      // this reader owns iteration so an expired budget stops the remaining windows too.
      var exact = false
      let verdict = ZoomCallWindow.classify(
        windowCount: 1,
        identifier: { _ in
          // Legacy start fallback may project malformed metadata to missing. Terminal
          // support must retain the raw distinction, not inherit that projection.
          let read = boundedCopy(window, kAXIdentifierAttribute as CFString, until: deadline, access: access)
          switch read {
          case .value(let raw):
            guard let value = raw as? String else { return .missing }
            if value == ZoomCallWindow.meetingIdentifier { exact = true }
            if value == "zm.meeting.window.leave" { leaveOngoing = true }
            return .value(value)
          case .missing:
            homeIdentifierMissing = windows.count == 1
            return .missing
          case .failed, .unavailable: return .failed
          }
        },
        title: { _ in
          stringRead(window, kAXTitleAttribute as CFString, until: deadline, access: access)
        })
      if exact {
        return .init(startEvidence: call, continuity: .ongoing(family: .zoom, room: "pid-\(appPID)"))
      }
      switch verdict {
      case .call:
        return .init(startEvidence: call, continuity: leaveOngoing
          ? .ongoing(family: .zoom, room: "pid-\(appPID)") : .unknown)
      case .unknown: failed = true
      case .none: break
      }
    }
    let start: Evidence = failed ? .unknown : .none
    if leaveOngoing {
      return .init(startEvidence: start, continuity: .ongoing(family: .zoom, room: "pid-\(appPID)"))
    }
    // A minimized live Zoom call can lose its main identifier and report minimized=false.
    // Only a positively scoped Home control, never missing call UI, can establish end.
    guard !failed, windows.count == 1, homeIdentifierMissing else { return .init(startEvidence: start) }
    switch zoomHomeWindow(windows[0], until: deadline, access: access) {
    case .ongoing:
      return .init(startEvidence: start, continuity: .ongoing(family: .zoom, room: "pid-\(appPID)"))
    case .home:
      guard case .value(let current) = boundedCopy(
        app, kAXWindowsAttribute as CFString, until: deadline, access: access),
        let current = current as? [AXUIElement], current.count == 1, CFEqual(current[0], windows[0])
      else { return .init(startEvidence: start) }
      return .init(startEvidence: .none, continuity: .ended(family: .zoom, room: "pid-\(appPID)"))
    case .unknown: return .init(startEvidence: start)
    }
  }

  private enum ZoomHome { case home, ongoing, unknown }

  /// Zoom's observed Home route owns this positive control state. Native chrome and
  /// embedded AI/chat documents cannot lend a label; this is not a negative tree scan.
  private static func zoomHomeWindow(
    _ window: AXUIElement, until deadline: ContinuousClock.Instant, access: Access
  ) -> ZoomHome {
    var remainingNodes = 800
    func role(_ element: AXUIElement) -> String? {
      guard remainingNodes > 0 else { return nil }
      remainingNodes -= 1
      guard case .value(let raw) = boundedCopy(
        element, kAXRoleAttribute as CFString, until: deadline, access: access),
        let value = raw as? String
      else { return nil }
      return value
    }
    func children(_ element: AXUIElement) -> [AXUIElement]? {
      guard case .value(let raw) = boundedCopy(
        element, kAXChildrenAttribute as CFString, until: deadline, access: access),
        let value = raw as? [AXUIElement], value.count <= 800
      else { return nil }
      return value
    }
    func homeURL(_ root: AXUIElement) -> Bool {
      guard case .value(let raw) = boundedCopy(
        root, kAXURLAttribute as CFString, until: deadline, access: access),
        let address = (raw as? URL)?.absoluteString ?? (raw as? String)
      else { return false }
      // Match only the fixed observed route spellings. Decoding URL components could
      // accept an unobserved encoded path/fragment that the app routes differently.
      return address == "https://new-home-page.localhost/index.html#/home"
        || address == "http://new-home-page.localhost/index.html#/home"
    }
    func pathToHome() -> [AXUIElement]? {
      guard role(window) == "AXWindow",
        case .value(let rawSubrole) = boundedCopy(
          window, kAXSubroleAttribute as CFString, until: deadline, access: access),
        (rawSubrole as? String) == "AXStandardWindow",
        case .missing = boundedCopy(window, kAXIdentifierAttribute as CFString, until: deadline, access: access),
        case .value(let minimized) = boundedCopy(
          window, kAXMinimizedAttribute as CFString, until: deadline, access: access),
        CFGetTypeID(minimized) == CFBooleanGetTypeID(), (minimized as? Bool) == false
      else { return nil }
      var paths = [[window]]
      for required in ["AXSplitGroup", "AXGroup", "AXGroup", "AXScrollArea", "AXWebArea"] {
        var next: [[AXUIElement]] = []
        for path in paths {
          guard let last = path.last, let values = children(last) else { return nil }
          for value in values {
            guard let valueRole = role(value) else { return nil }
            // Zoom Home includes readable empty-role chrome; it cannot be a typed path node.
            if valueRole.isEmpty { continue }
            if ["AXWindow", "AXSheet", "AXDialog", "AXSystemDialog", "AXDrawer"].contains(valueRole) {
              return nil
            }
            if valueRole == required {
              guard !path.contains(where: { CFEqual($0, value) }) else { return nil }
              next.append(path + [value])
            }
          }
        }
        guard !next.isEmpty else { return nil }
        paths = next
      }
      guard paths.count == 1, let root = paths[0].last, homeURL(root) else { return nil }
      return paths[0]
    }
    func control(_ root: AXUIElement) -> (button: AXUIElement, ongoing: Bool)? {
      guard let values = children(root) else { return nil }
      var meets: [AXUIElement] = []
      var backs: [AXUIElement] = []
      var uncertain = false
      for value in values {
        guard let valueRole = role(value) else { uncertain = true; continue }
        guard ["AXGroup", "AXButton", "AXStaticText", "AXPopUpButton"].contains(valueRole) else {
          uncertain = true; continue
        }
        guard valueRole == "AXButton" else { continue }
        let title = controlText(value, kAXTitleAttribute as CFString, until: deadline, access: access)
        let description = controlText(value, kAXDescriptionAttribute as CFString, until: deadline, access: access)
        guard title.valid, description.valid, let titleText = title.text,
          let descriptionText = description.text
        else { uncertain = true; continue }
        let mentionsMeet = titleText == "Meet" || descriptionText == "Meet"
        let mentionsBack = titleText == "Back to meeting" || descriptionText == "Back to meeting"
        if titleText == "Back to meeting", descriptionText == "Back to meeting" { backs.append(value) }
        else if titleText == "Meet", descriptionText == "Meet" { meets.append(value) }
        else if mentionsMeet || mentionsBack {
          uncertain = true
        }
      }
      if let back = backs.first { return (back, true) }
      guard !uncertain, meets.count == 1 else { return nil }
      return (meets[0], false)
    }
    guard let path = pathToHome(), let root = path.last, let first = control(root), homeURL(root)
    else { return .unknown }
    if first.ongoing { return .ongoing }
    // Old readable handles do not prove current membership: repeat the typed window
    // connection and the root's direct children, then require the same unique button.
    guard let currentPath = pathToHome(), currentPath.count == path.count,
      zip(path, currentPath).allSatisfy({ CFEqual($0.0, $0.1) }),
      let current = control(root), !current.ongoing, CFEqual(current.button, first.button), homeURL(root)
    else { return .unknown }
    return .home
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
    meetingPageSnapshot(appPID: appPID, access: access).startEvidence
  }

  package static func meetingPageSnapshot(appPID: pid_t, access: Access = .live) -> Snapshot {
    meetingPageSnapshot(appPID: appPID, until: scanDeadline(access), access: access)
  }

  private static func meetingPageSnapshot(
    appPID: pid_t, until deadline: ContinuousClock.Instant, access: Access
  ) -> Snapshot {
    let app = AXUIElementCreateApplication(appPID)
    // AXRole itself wakes Chromium (#3802). Its value/error is not a capability gate:
    // preserve the old quick-error continuation, but never message without a checked allowance.
    if case .unavailable = boundedCopy(
      app, kAXRoleAttribute as CFString, until: deadline, access: access)
    { return .init(startEvidence: .unknown) }
    guard case .value(let windowRef) = boundedCopy(
      app, kAXFocusedWindowAttribute as CFString, until: deadline, access: access),
      CFGetTypeID(windowRef) == AXUIElementGetTypeID()
    else { return .init(startEvidence: .unknown) }
    let window = windowRef as! AXUIElement
    let walk = url(in: window, until: deadline, access: access)
    var address = walk.url
    if address == nil {
      switch boundedCopy(window, kAXDocumentAttribute as CFString, until: deadline, access: access) {
      case .value(let value): address = value as? String
      case .missing: break
      case .failed, .unavailable: return .init(startEvidence: .unknown)
      }
    }
    guard let address else { return .init(startEvidence: walk.complete ? .none : .unknown) }
    guard let match = CallMeetingURL.classify(address) else { return .init(startEvidence: .none) }
    let start = Evidence.call(family: match.family, room: match.room)
    // A document fallback has no web-area scope, so it cannot authorize a window-wide state scan.
    guard match.family == .googleMeet, let page = walk.webArea
    else { return .init(startEvidence: start) }
    // Optional lifetime interpretation must not spend the legacy start's entire
    // return path. Reserve one exact-handle allowance for URL revalidation and
    // 100ms for the existing owner bookend/return; the worker still expires at 1s.
    let returnReserve: Duration = .milliseconds(100)
    let stateBudget = Duration.seconds(Double(messagingTimeout))
    let revalidationDeadline = deadline.advanced(by: .zero - returnReserve)
    let stateDeadline = min(access.now().advanced(by: stateBudget),
      revalidationDeadline.advanced(by: .zero - stateBudget))
    guard access.now() < stateDeadline else { return .init(startEvidence: start) }
    return meetSnapshot(in: page, match: match, until: stateDeadline,
      revalidateUntil: revalidationDeadline, access: access)
  }

  private static let meetEndTitles: Set<String> = [
    "You left the meeting", "You've ended the meeting for everyone",
  ]

  /// Only the matched page's own UI is eligible. No body-text or nested-document search.
  private static func meetSnapshot(
    in page: AXUIElement, match: CallMeetingURL.Match,
    until deadline: ContinuousClock.Instant, revalidateUntil revalidationDeadline: ContinuousClock.Instant,
    access: Access
  ) -> Snapshot {
    let start = Evidence.call(family: match.family, room: match.room)
    var queue: [(AXUIElement, Int)] = [(page, 0)]
    var cursor = 0
    var complete = true
    var ended = false
    while cursor < queue.count, cursor < 800, access.now() < deadline {
      let (node, level) = queue[cursor]
      cursor += 1
      guard case .value(let rawRole) = boundedCopy(
        node, kAXRoleAttribute as CFString, until: deadline, access: access),
        let role = rawRole as? String
      else { complete = false; continue }
      if CFEqual(node, page), role != "AXWebArea" { return .init(startEvidence: .unknown) }
      if role == "AXWebArea", !CFEqual(node, page) {
        complete = false
        continue
      }
      if role == "AXButton" {
        let title = controlText(node, kAXTitleAttribute as CFString, until: deadline, access: access)
        if !title.valid { complete = false }
        let description: (text: String?, valid: Bool) = title.text == "Leave call" ? (text: nil, valid: true)
          : controlText(node, kAXDescriptionAttribute as CFString, until: deadline, access: access)
        if !description.valid { complete = false }
        if title.text == "Leave call" || description.text == "Leave call" {
          guard sameRoom(page, match: match, until: revalidationDeadline, access: access)
          else { return .init(startEvidence: .unknown) }
          return .init(
            startEvidence: start, continuity: .ongoing(family: match.family, room: match.room))
        }
        if (title.text ?? "").isEmpty, (description.text ?? "").isEmpty { complete = false }
      } else if role == "AXHeading" {
        let title = controlText(node, kAXTitleAttribute as CFString, until: deadline, access: access)
        if !title.valid { complete = false }
        if let text = title.text, meetEndTitles.contains(text) {
          if case .value(let rawLevel) = boundedCopy(
            node, kAXValueAttribute as CFString, until: deadline, access: access),
            let level = rawLevel as? NSNumber,
            CFGetTypeID(rawLevel) != CFBooleanGetTypeID(), level.doubleValue == 1
          {
            ended = true
          } else {
            complete = false
          }
        }
      }
      switch boundedCopy(node, kAXChildrenAttribute as CFString, until: deadline, access: access) {
      case .value(let value):
        guard let children = value as? [AXUIElement] else { complete = false; continue }
        if level < 32 { queue.append(contentsOf: children.map { ($0, level + 1) }) }
        else if !children.isEmpty { complete = false }
      case .missing: break
      case .failed, .unavailable: complete = false
      }
    }
    if cursor < queue.count || access.now() >= deadline { complete = false }
    if complete, ended {
      guard sameRoom(page, match: match, until: revalidationDeadline, access: access)
      else { return .init(startEvidence: .unknown) }
      return .init(startEvidence: .none, continuity: .ended(family: match.family, room: match.room))
    }
    return .init(startEvidence: start)
  }

  private static func controlText(
    _ element: AXUIElement, _ attribute: CFString, until deadline: ContinuousClock.Instant,
    access: Access
  ) -> (text: String?, valid: Bool) {
    switch boundedCopy(element, attribute, until: deadline, access: access) {
    case .value(let value):
      guard let text = value as? String else { return (nil, false) }
      return (text, true)
    case .missing: return (nil, true)
    case .failed, .unavailable: return (nil, false)
    }
  }

  private static func sameRoom(
    _ page: AXUIElement, match: CallMeetingURL.Match,
    until deadline: ContinuousClock.Instant, access: Access
  ) -> Bool {
    guard case .value(let value) = boundedCopy(
      page, kAXURLAttribute as CFString, until: deadline, access: access),
      let address = (value as? URL)?.absoluteString ?? (value as? String)
    else { return false }
    return CallMeetingURL.classify(address) == match
  }

  /// Breadth-first, at most 12 levels and 400 elements: browser trees are deep, and a page
  /// with a huge tree must not stall the read. `complete` is false when a read on the way failed.
  private static func url(
    in root: AXUIElement, until deadline: ContinuousClock.Instant, access: Access
  ) -> (url: String?, webArea: AXUIElement?, complete: Bool) {
    var queue: [(AXUIElement, Int, Bool)] = [(root, 0, true)]
    var visited = 0
    var complete = true
    while !queue.isEmpty, visited < 400, access.now() < deadline {
      let (node, level, eligibleRoot) = queue.removeFirst()
      visited += 1
      var eligibleDescendants = eligibleRoot
      switch boundedCopy(node, kAXRoleAttribute as CFString, until: deadline, access: access) {
      case .value(let role) where (role as? String) == "AXWebArea":
        // Preserve legacy address discovery below documents, but never promote an embedded
        // document into the trusted continuity root when its ancestor has no readable URL.
        eligibleDescendants = false
        switch boundedCopy(node, kAXURLAttribute as CFString, until: deadline, access: access) {
        case .value(let value):
          if let link = (value as? URL)?.absoluteString ?? (value as? String) {
            return (link, eligibleRoot ? node : nil, true)
          }
        case .missing: break
        case .failed, .unavailable: complete = false
        }
      case .value(let role):
        if (role as? String)?.isEmpty != false { eligibleDescendants = false }
      case .failed, .unavailable:
        complete = false
        eligibleDescendants = false
      case .missing: eligibleDescendants = false
      }
      switch boundedCopy(node, kAXChildrenAttribute as CFString, until: deadline, access: access) {
      case .value(let value):
        let children = (value as? [AXUIElement]) ?? []
        // A level the walk will not enter is part of the page it did not see (r6 F5).
        guard level < 12 else {
          if !children.isEmpty { complete = false }
          continue
        }
        queue.append(contentsOf: children.map { ($0, level + 1, eligibleDescendants) })
      case .missing: break
      case .failed, .unavailable: complete = false
      }
    }
    // Stopped at the element limit with elements still waiting: not a full search (r6 F5).
    if !queue.isEmpty { complete = false }
    return (nil, nil, complete)
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
