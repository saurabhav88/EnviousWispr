import ApplicationServices
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// A remote window must not monopolize evidence reads and hide the user's next call (#4127).
@Suite("Call evidence AX reads", .tags(.productOutcome))
struct CallEvidenceReaderTests {
  typealias Reader = CallEvidenceReader

  /// AX handles are local stand-ins. Every message goes to these closures, never to an app.
  final class Fixture {
    let window = AXUIElementCreateApplication(70_001)
    let page = AXUIElementCreateApplication(70_002)
    let heading = AXUIElementCreateApplication(80_001)
    let leave = AXUIElementCreateApplication(80_002)
    let pid: Int32 = 70_000
    var instant = ContinuousClock.now
    var requireExactTimeout = true
    var timeouts: [ObjectIdentifier: Float] = [:]
    var issued: [Float] = []
    var refused: [String] = []
    var messages: [String] = []
    var refuseSetup = false
    var identifier: String? = "zm.meeting.window.main"
    var title: String?
    var pageURL: String? = "https://meet.google.com/abc-defg-hij"
    var document: String?
    var meetHeading: String?
    var meetHeadingLevel: Reader.CopyResult = .value(NSNumber(value: 1))
    var leaveTitle: String?
    var leaveDescription: String?
    lazy var windows: [AXUIElement] = [window]
    var response: ((Fixture, AXUIElement, String) -> Reader.CopyResult?)?

    var access: Reader.Access {
      Reader.Access(
        now: { self.instant },
        setTimeout: { element, seconds in
          self.issued.append(seconds)
          guard self.refuseSetup == false else { return .cannotComplete }
          self.timeouts[ObjectIdentifier(element)] = seconds
          return .success
        },
        read: { element, attribute in self.read(element, attribute) },
        wake: { _, _ in
          AccessibilityWake.Report(
            roleError: .success, roleReadExhausted: false, manual: false, manualEnabled: false)
        },
        regularTeamsPIDs: { [self.pid] })
    }

    func read(_ element: AXUIElement, _ attribute: CFString) -> Reader.CopyResult {
      // Record every attempted message, including one the transport refuses for missing setup.
      let name = attribute as String
      messages.append(name)
      // Consume the installed allowance: a later message on this same handle must refresh it.
      let allowance = timeouts.removeValue(forKey: ObjectIdentifier(element))
      if requireExactTimeout, allowance == nil {
        refused.append(attribute as String)
        return .failed
      }
      if let replacement = response?(self, element, name) { return replacement }
      switch name {
      case "AXWindows": return .value(windows as CFArray)
      case "AXFocusedWindow": return .value(window)
      case "AXIdentifier": return identifier.map { .value($0 as CFString) } ?? .missing
      case "AXTitle":
        let text = CFEqual(element, heading) ? meetHeading : CFEqual(element, leave) ? leaveTitle : title
        return text.map { .value($0 as CFString) } ?? .missing
      case "AXDescription":
        return CFEqual(element, leave)
          ? leaveDescription.map { .value($0 as CFString) } ?? .missing : .missing
      case "AXValue": return CFEqual(element, heading) ? meetHeadingLevel : .missing
      case "AXRole":
        let role = CFEqual(element, heading) ? "AXHeading"
          : CFEqual(element, leave) ? "AXButton" : CFEqual(element, page) ? "AXWebArea" : "AXWindow"
        return .value(role as CFString)
      case "AXChildren":
        if CFEqual(element, window) { return .value([page] as CFArray) }
        if CFEqual(element, page) {
          var children: [AXUIElement] = []
          if meetHeading != nil { children.append(heading) }
          if leaveTitle != nil || leaveDescription != nil { children.append(leave) }
          return children.isEmpty ? .missing : .value(children as CFArray)
        }
        return .missing
      case "AXURL": return pageURL.map { .value($0 as CFString) } ?? .missing
      case "AXDocument": return document.map { .value($0 as CFString) } ?? .missing
      default: return .missing
      }
    }
  }

  @Test("Healthy browser descendant URL still proves the call")
  func healthyBrowserURL() {
    let fixture = Fixture()
    #expect(Reader.meetingPage(appPID: fixture.pid, access: fixture.access)
      == .call(family: .googleMeet, room: "abc-defg-hij"))
  }

  @Test("A proved Meet post-call page is not eligible to start another recording",
    .bug("https://github.com/saurabhav88/EnviousWispr/issues/4142"))
  func endedMeetPageIsNotStartEvidence() {
    let fixture = Fixture()
    let heading = AXUIElementCreateApplication(70_003)
    fixture.response = { f, element, attribute in
      if CFEqual(element, f.page), attribute == "AXChildren" {
        return .value([heading] as CFArray)
      }
      guard CFEqual(element, heading) else { return nil }
      switch attribute {
      case "AXRole": return .value("AXHeading" as CFString)
      case "AXTitle": return .value("You left the meeting" as CFString)
      case "AXValue": return .value(NSNumber(value: 1))
      case "AXChildren": return .missing
      default: return .missing
      }
    }

    #expect(Reader.meetingPage(appPID: fixture.pid, access: fixture.access) == .none)
  }

  @Test("A meeting URL alone never becomes independent ongoing-call proof")
  func urlOnlySnapshotIsUncertain() {
    let fixture = Fixture()
    #expect(Reader.meetingPageSnapshot(appPID: fixture.pid, access: fixture.access)
      == .init(startEvidence: .call(family: .googleMeet, room: "abc-defg-hij")))
  }

  @Test("Normal Meet Leave has attributed ended continuity and suppresses start admission")
  func normalMeetLeaveSnapshot() {
    let fixture = Fixture()
    fixture.meetHeading = "You left the meeting"
    #expect(Reader.meetingPageSnapshot(appPID: fixture.pid, access: fixture.access)
      == .init(startEvidence: .none, continuity: .ended(family: .googleMeet, room: "abc-defg-hij")))
    #expect(fixture.refused.isEmpty, "every exact handle must receive its own timeout")
  }

  @Test("Meet host End-for-everyone has the separate verified ended heading")
  func hostMeetEndSnapshot() {
    let fixture = Fixture()
    fixture.meetHeading = "You've ended the meeting for everyone"
    #expect(Reader.meetingPageSnapshot(appPID: fixture.pid, access: fixture.access)
      == .init(startEvidence: .none, continuity: .ended(family: .googleMeet, room: "abc-defg-hij")))
  }

  @Test("A same-page Leave control wins even when an end-like heading was encountered first",
    arguments: [true, false])
  func ongoingMeetWins(title: Bool) {
    let fixture = Fixture()
    fixture.meetHeading = "You left the meeting"
    fixture.leaveTitle = title ? "Leave call" : ""
    fixture.leaveDescription = title ? nil : "Leave call"
    #expect(Reader.meetingPageSnapshot(appPID: fixture.pid, access: fixture.access)
      == .init(startEvidence: .call(family: .googleMeet, room: "abc-defg-hij"),
        continuity: .ongoing(family: .googleMeet, room: "abc-defg-hij")))
  }

  @Test("Near-match, confirmation and unsupported headings are not ended proof",
    arguments: ["You left the meeting early", "End the call or just leave?", "Unrecognized localized UI"])
  func unrecognizedMeetHeading(_ text: String) {
    let fixture = Fixture()
    fixture.meetHeading = text
    #expect(Reader.meetingPageSnapshot(appPID: fixture.pid, access: fixture.access).continuity == .unknown)
  }

  @Test("Malformed, missing and non-level-one end metadata remains unknown")
  func invalidMeetHeadingMetadata() {
    let levels: [Reader.CopyResult] = [
      .missing, .failed, .value("1" as CFString), .value(NSNumber(value: true)),
      .value(NSNumber(value: 2)),
    ]
    for level in levels {
      let fixture = Fixture()
      fixture.meetHeading = "You left the meeting"
      fixture.meetHeadingLevel = level
      #expect(Reader.meetingPageSnapshot(appPID: fixture.pid, access: fixture.access).continuity == .unknown)
    }
    let malformed = Fixture()
    malformed.meetHeading = "You left the meeting"
    malformed.response = { f, node, attribute in
      CFEqual(node, f.heading) && attribute == "AXTitle" ? .value(NSNumber(value: 1)) : nil
    }
    #expect(Reader.meetingPageSnapshot(appPID: malformed.pid, access: malformed.access).continuity == .unknown)
  }

  @Test("A heading elsewhere in the browser window cannot end the matched page")
  func meetEndCueOutsidePage() {
    let fixture = Fixture()
    fixture.meetHeading = "You left the meeting"
    fixture.response = { f, node, attribute in
      guard attribute == "AXChildren" else { return nil }
      if CFEqual(node, f.window) { return .value([f.page, f.heading] as CFArray) }
      return CFEqual(node, f.page) ? .missing : nil
    }
    #expect(Reader.meetingPageSnapshot(appPID: fixture.pid, access: fixture.access).continuity == .unknown)
  }

  @Test("A nested embedded document cannot lend its heading to the Meet page")
  func meetEndCueInNestedDocument() {
    let fixture = Fixture()
    fixture.meetHeading = "You left the meeting"
    let nested = AXUIElementCreateApplication(80_003)
    fixture.response = { f, node, attribute in
      if CFEqual(node, f.page), attribute == "AXChildren" { return .value([nested] as CFArray) }
      guard CFEqual(node, nested) else { return nil }
      switch attribute {
      case "AXRole": return .value("AXWebArea" as CFString)
      case "AXChildren": return .value([f.heading] as CFArray)
      default: return .missing
      }
    }
    #expect(Reader.meetingPageSnapshot(appPID: fixture.pid, access: fixture.access).continuity == .unknown)
    #expect(!fixture.messages.contains("AXTitle"), "embedded document labels must not be read")
  }

  @Test("Nested or ancestry-unverified URL roots retain legacy admission without continuity",
    arguments: ["embedded", "failed", "missing", "malformed"])
  func nestedURLCannotBecomeContinuityRoot(_ ancestor: String) {
    let fixture = Fixture()
    fixture.meetHeading = "You left the meeting"
    let nested = AXUIElementCreateApplication(80_003)
    fixture.response = { f, node, attribute in
      if CFEqual(node, f.page) {
        switch attribute {
        case "AXRole":
          switch ancestor {
          case "failed": return .failed
          case "missing": return .missing
          case "malformed": return .value(NSNumber(value: 1))
          default: return .value("AXWebArea" as CFString)
          }
        case "AXURL": return .missing
        case "AXChildren": return .value([nested] as CFArray)
        default: return nil
        }
      }
      guard CFEqual(node, nested) else { return nil }
      switch attribute {
      case "AXRole": return .value("AXWebArea" as CFString)
      case "AXURL": return .value("https://meet.google.com/abc-defg-hij" as CFString)
      case "AXChildren": return .value([f.heading] as CFArray)
      default: return .missing
      }
    }
    #expect(Reader.meetingPageSnapshot(appPID: fixture.pid, access: fixture.access)
      == .init(startEvidence: .call(family: .googleMeet, room: "abc-defg-hij")))
    #expect(!fixture.messages.contains("AXTitle"), "untrusted descendants cannot supply state cues")
  }

  @Test("A document fallback remains start evidence but cannot authorize an end scan")
  func meetDocumentHasNoContinuityScope() {
    let fixture = Fixture()
    fixture.pageURL = nil
    fixture.document = "https://meet.google.com/abc-defg-hij"
    fixture.meetHeading = "You left the meeting"
    #expect(Reader.meetingPageSnapshot(appPID: fixture.pid, access: fixture.access)
      == .init(startEvidence: .call(family: .googleMeet, room: "abc-defg-hij")))
  }

  @Test("A changed room invalidates ended proof before return")
  func meetRoomRevalidation() {
    let fixture = Fixture()
    fixture.meetHeading = "You left the meeting"
    var reads = 0
    fixture.response = { f, node, attribute in
      guard CFEqual(node, f.page), attribute == "AXURL" else { return nil }
      reads += 1
      let url = reads == 1 ? "https://meet.google.com/abc-defg-hij" : "https://meet.google.com/xyz-wxyz-xyz"
      return .value(url as CFString)
    }
    #expect(Reader.meetingPageSnapshot(appPID: fixture.pid, access: fixture.access)
      == .init(startEvidence: .unknown))
  }

  @Test("A page whose role changes after URL lookup cannot supply ended proof")
  func meetRootRoleChanges() {
    let fixture = Fixture()
    fixture.meetHeading = "You left the meeting"
    var roleReads = 0
    fixture.response = { f, node, attribute in
      guard CFEqual(node, f.page), attribute == "AXRole" else { return nil }
      roleReads += 1
      return .value((roleReads == 1 ? "AXWebArea" : "AXGroup") as CFString)
    }
    #expect(Reader.meetingPageSnapshot(appPID: fixture.pid, access: fixture.access)
      == .init(startEvidence: .unknown))
  }

  @Test("Native NSURL addresses work for the observed ended-page route")
  func meetNSURLSnapshot() throws {
    let fixture = Fixture()
    fixture.meetHeading = "You left the meeting"
    let address = try #require(URL(string: "https://meet.google.com/meet/abc-defg-hij")) as NSURL
    fixture.response = { f, node, attribute in
      CFEqual(node, f.page) && attribute == "AXURL" ? .value(address) : nil
    }
    #expect(Reader.meetingPageSnapshot(appPID: fixture.pid, access: fixture.access).continuity
      == .ended(family: .googleMeet, room: "abc-defg-hij"))
  }

  @Test("Partial or exhausted state scans do not claim an ended call", arguments: [true, false])
  func incompleteMeetStateScan(partial: Bool) {
    let fixture = Fixture()
    fixture.meetHeading = "You left the meeting"
    let unreadable = AXUIElementCreateApplication(80_003)
    fixture.response = { f, node, attribute in
      if partial {
        if CFEqual(node, f.page), attribute == "AXChildren" {
          return .value([f.heading, unreadable] as CFArray)
        }
        if CFEqual(node, unreadable), attribute == "AXRole" { return .failed }
      } else if CFEqual(node, f.heading), attribute == "AXValue" {
        f.instant = f.instant.advanced(by: .seconds(1))
      }
      return nil
    }
    #expect(Reader.meetingPageSnapshot(appPID: fixture.pid, access: fixture.access).continuity == .unknown)
  }

  @Test("Unsearched depth or node-limit descendants cannot prove a Meet call ended",
    arguments: [true, false])
  func boundedMeetStateScan(depth: Bool) {
    let fixture = Fixture()
    fixture.meetHeading = "You left the meeting"
    let nodes = (0..<(depth ? 34 : 800)).map { AXUIElementCreateApplication(Int32(81_000 + $0)) }
    fixture.response = { f, node, attribute in
      if CFEqual(node, f.page), attribute == "AXChildren" {
        return .value(([f.heading] + (depth ? [nodes[0]] : nodes)) as CFArray)
      }
      guard let index = nodes.firstIndex(where: { CFEqual($0, node) }) else { return nil }
      if attribute == "AXRole" { return .value("AXGroup" as CFString) }
      if attribute == "AXChildren", depth, index + 1 < nodes.count {
        return .value([nodes[index + 1]] as CFArray)
      }
      return .missing
    }
    #expect(Reader.meetingPageSnapshot(appPID: fixture.pid, access: fixture.access).continuity == .unknown)
  }

  @Test("Other browser vendors keep start admission without borrowing Meet's end language")
  func otherBrowserVendorHasUnknownContinuity() {
    let fixture = Fixture()
    fixture.pageURL = "https://zoom.us/j/123456789"
    fixture.meetHeading = "You left the meeting"
    #expect(Reader.meetingPageSnapshot(appPID: fixture.pid, access: fixture.access)
      == .init(startEvidence: .call(family: .zoom, room: "123456789")))
    #expect(!fixture.messages.contains("AXTitle"))
  }

  @Test("#4135 a signed-in Meet address /meet/<code> proves the call, from the page or the document")
  func meetPrefixedAddress() {
    let page = Fixture()
    page.pageURL = "https://meet.google.com/meet/abc-defg-hij"
    #expect(Reader.meetingPage(appPID: page.pid, access: page.access)
      == .call(family: .googleMeet, room: "abc-defg-hij"))
    let document = Fixture()
    document.pageURL = nil
    document.document = "https://meet.google.com/meet/abc-defg-hij"
    document.response = { _, _, attribute in attribute == "AXChildren" ? .failed : nil }
    #expect(Reader.meetingPage(appPID: document.pid, access: document.access)
      == .call(family: .googleMeet, room: "abc-defg-hij"))
  }

  @Test("Each Zoom window gets its own timeout",
    .bug("https://github.com/saurabhav88/EnviousWispr/issues/4127"))
  func zoomWindowTimeout() {
    let fixture = Fixture()
    fixture.requireExactTimeout = true
    let result = Reader.callWindow(family: .zoom, appPID: fixture.pid, access: fixture.access)
    #expect(result == .call(family: .zoom, room: "pid-70000"),
      "Transport refused unconfigured window attributes: \(fixture.refused)")
  }

  @Test("A Zoom window uses the remaining whole-scan allowance")
  func shrinkingScanBudget() {
    let fixture = Fixture()
    fixture.response = { rig, _, attribute in
      if attribute == "AXWindows" { rig.instant = rig.instant.advanced(by: .milliseconds(900)) }
      return nil
    }
    #expect(Reader.callWindow(family: .zoom, appPID: fixture.pid, access: fixture.access)
      == .call(family: .zoom, room: "pid-70000"))
    #expect(fixture.issued == [0.25, 0.1])
  }

  @Test("Refused timeout setup never sends an AX message")
  func refusedSetupSendsNothing() {
    let fixture = Fixture()
    fixture.refuseSetup = true
    let result = Reader.boundedCopy(
      fixture.window, kAXTitleAttribute as CFString,
      until: fixture.instant.advanced(by: .seconds(1)), access: fixture.access)
    guard case .unavailable = result else { Issue.record("Refused setup must be unavailable"); return }
    #expect(fixture.issued.count == 1)
    #expect(fixture.messages.isEmpty)
  }

  @Test("An already expired budget performs no setup or read")
  func expiredBudgetSendsNothing() {
    let fixture = Fixture()
    let result = Reader.boundedCopy(
      fixture.window, kAXTitleAttribute as CFString, until: fixture.instant, access: fixture.access)
    guard case .unavailable = result else { Issue.record("Expired budget must be unavailable"); return }
    #expect(fixture.issued.isEmpty)
    #expect(fixture.messages.isEmpty)
  }

  @Test("A late successful window reply stays unknown and stops further IPC")
  func lateWindowReply() {
    let fixture = Fixture()
    fixture.response = { rig, _, attribute in
      if attribute == "AXIdentifier" { rig.instant = rig.instant.advanced(by: .seconds(1)) }
      return nil
    }
    #expect(Reader.callWindow(family: .zoom, appPID: fixture.pid, access: fixture.access) == .unknown)
    #expect(fixture.messages == ["AXWindows", "AXIdentifier"])
  }

  @Test("A later positive Zoom window survives earlier uncertainty")
  func positiveAfterUncertainWindow() {
    let fixture = Fixture()
    let uncertain = AXUIElementCreateApplication(70_003)
    fixture.windows = [uncertain, fixture.window]
    fixture.response = { _, node, attribute in
      guard CFEqual(node, uncertain) else { return nil }
      return attribute == "AXIdentifier" ? .failed : .missing
    }
    #expect(Reader.callWindow(family: .zoom, appPID: fixture.pid, access: fixture.access)
      == .call(family: .zoom, room: "pid-70000"))
  }

  @Test("A browser wake that spends the budget prevents focused-window IPC")
  func exhaustedBrowserWake() {
    let fixture = Fixture()
    fixture.response = { rig, _, attribute in
      if attribute == "AXRole" { rig.instant = rig.instant.advanced(by: .seconds(1)) }
      return nil
    }
    #expect(Reader.meetingPage(appPID: fixture.pid, access: fixture.access) == .unknown)
    #expect(fixture.messages == ["AXRole"])
  }

  @Test("A browser wake with refused setup sends no message")
  func refusedBrowserWake() {
    let fixture = Fixture()
    fixture.refuseSetup = true
    #expect(Reader.meetingPage(appPID: fixture.pid, access: fixture.access) == .unknown)
    #expect(fixture.messages.isEmpty)
  }

  @Test("A quick role-read error preserves later browser call evidence")
  func quickBrowserRoleError() {
    let fixture = Fixture()
    var roleErrorObserved = false
    fixture.response = { rig, node, attribute in
      if attribute == "AXRole", CFEqual(node, rig.window) == false,
        CFEqual(node, rig.page) == false {
        roleErrorObserved = true
        return .failed
      }
      return nil
    }
    #expect(Reader.meetingPage(appPID: fixture.pid, access: fixture.access)
      == .call(family: .googleMeet, room: "abc-defg-hij"))
    #expect(roleErrorObserved)
  }

  @Test("An incomplete walk still accepts an authoritative document address",
    arguments: ["https://meet.google.com/abc-defg-hij", "https://example.com/"])
  func documentAfterIncompleteWalk(address: String) {
    let fixture = Fixture()
    fixture.document = address
    fixture.response = { _, _, attribute in attribute == "AXChildren" ? .failed : nil }
    let result = Reader.meetingPage(appPID: fixture.pid, access: fixture.access)
    if address == "https://meet.google.com/abc-defg-hij" {
      #expect(result == .call(family: .googleMeet, room: "abc-defg-hij"))
    } else {
      #expect(result == .none)
    }
  }

  @Test("Completed negative scans remain none, not unknown")
  func healthyNegativeScans() {
    let zoom = Fixture()
    zoom.identifier = nil
    #expect(Reader.callWindow(family: .zoom, appPID: zoom.pid, access: zoom.access) == .none)
    let browser = Fixture()
    browser.pageURL = nil
    #expect(Reader.meetingPage(appPID: browser.pid, access: browser.access) == .none)
  }

  func slackFixture(
    control: Reader.CopyResult, role: String = "AXButton", title: String? = nil
  ) -> Fixture {
    let fixture = Fixture()
    fixture.title = title
    fixture.response = { rig, node, attribute in
      if attribute == "AXRole", CFEqual(node, rig.page) { return .value(role as CFString) }
      if attribute == "AXDOMClassList" { return control }
      return nil
    }
    return fixture
  }

  @Test("Shared Slack search accepts only the real button role", arguments: [true, false])
  func slackSearchRole(button: Bool) {
    let fixture = slackFixture(
      control: .value([SlackHuddleWindow.leaveClass] as CFArray),
      role: button ? "AXButton" : "AXPopUpButton", title: "workspace")
    let evidence = Reader.callWindow(family: .slack, appPID: fixture.pid, access: fixture.access)
    #expect(evidence == (button ? .call(family: .slack, room: "pid-70000") : .none))
  }

  @Test("Malformed Slack class data remains uncertainty")
  func slackMalformedControl() {
    let fixture = slackFixture(control: .value(SlackHuddleWindow.leaveClass as CFString))
    #expect(Reader.callWindow(family: .slack, appPID: fixture.pid, access: fixture.access) == .unknown)
  }

  @Test("A partial Slack traversal remains uncertainty")
  func slackPartialSearch() {
    let fixture = Fixture()
    fixture.response = { _, _, attribute in attribute == "AXChildren" ? .failed : nil }
    #expect(Reader.callWindow(family: .slack, appPID: fixture.pid, access: fixture.access) == .unknown)
  }

  @Test("Slack title fallback stays authoritative after missing or failed control reads",
    arguments: [true, false])
  func slackTitleFallback(malformed: Bool) {
    let control: Reader.CopyResult = malformed
      ? .value(SlackHuddleWindow.leaveClass as CFString) : .missing
    let fixture = slackFixture(control: control, title: "Huddle")
    #expect(Reader.callWindow(family: .slack, appPID: fixture.pid, access: fixture.access)
      == .call(family: .slack, room: "pid-70000"))
  }

  @Test("A later Slack control still wins earlier window uncertainty")
  func slackPositiveAfterFailure() {
    let fixture = Fixture()
    let bad = AXUIElementCreateApplication(70_003)
    fixture.windows = [bad, fixture.window]
    fixture.response = { rig, node, attribute in
      if CFEqual(node, bad) { return attribute == "AXRole" ? .failed : .missing }
      if attribute == "AXRole", CFEqual(node, rig.page) { return .value("AXButton" as CFString) }
      if attribute == "AXDOMClassList" { return .value([SlackHuddleWindow.leaveClass] as CFArray) }
      return nil
    }
    #expect(Reader.callWindow(family: .slack, appPID: fixture.pid, access: fixture.access)
      == .call(family: .slack, room: "pid-70000"))
  }

  @Test("Slack wake refusals do not become negative scans or send later messages")
  func slackWakeAcceptance() {
    let reports = [
      AccessibilityWake.Report(roleError: .cannotComplete, roleReadExhausted: false,
        manual: false, manualEnabled: false),
      AccessibilityWake.Report(roleError: .success, roleReadExhausted: true,
        manual: false, manualEnabled: false),
      AccessibilityWake.Report(roleError: .success, roleReadExhausted: false,
        manual: nil, manualEnabled: false),
      AccessibilityWake.Report(roleError: .success, roleReadExhausted: false,
        manual: true, manualEnabled: false),
    ]
    for report in reports {
      let fixture = Fixture()
      var access = fixture.access
      access.wake = { _, _ in report }
      #expect(Reader.callWindow(family: .slack, appPID: fixture.pid, access: access) == .unknown)
      #expect(fixture.messages.isEmpty)
    }
  }

  @Test("Other calling apps keep immediate microphone-based evidence")
  func legacyNativeEvidence() {
    let fixture = Fixture()
    var access = fixture.access
    access.wake = { _, _ in
      Issue.record("Legacy native rule must not perform wake work")
      return AccessibilityWake.Report(roleError: .cannotComplete, roleReadExhausted: false,
        manual: nil, manualEnabled: false)
    }
    access.regularTeamsPIDs = { Issue.record("Legacy native rule must not enumerate Teams"); return [] }
    #expect(Reader.nativeCallEvidence(family: .facetime, holderPID: fixture.pid, access: access)
      == .call(family: .facetime, room: "pid-70000"))
    #expect(fixture.messages.isEmpty)
  }

  func teamsFixture(
    identifier: Reader.CopyResult = .value("hangup-button" as CFString),
    role: String = "AXButton", depth: Int = 16
  ) -> Fixture {
    let fixture = Fixture()
    let nodes = [fixture.window] + (1...depth).map { AXUIElementCreateApplication(Int32(71_000 + $0)) }
    fixture.response = { _, node, attribute in
      guard let index = nodes.firstIndex(where: { CFEqual($0, node) }) else { return nil }
      switch attribute {
      case "AXRole": return .value((index == depth ? role : "AXGroup") as CFString)
      case "AXChildren":
        return index < depth ? .value([nodes[index + 1]] as CFArray) : .missing
      case "AXDOMIdentifier": return identifier
      default: return nil
      }
    }
    return fixture
  }

  @Test("Teams owner selection prefers its own regular holder, otherwise only one distinct owner")
  func teamsOwnerSelection() {
    #expect(Reader.teamsOwnerPID(holderPID: 7, regularTeamsPIDs: []) == nil)
    #expect(Reader.teamsOwnerPID(holderPID: 7, regularTeamsPIDs: [8, 9]) == nil)
    #expect(Reader.teamsOwnerPID(holderPID: 7, regularTeamsPIDs: [8, 8]) == 8)
    #expect(Reader.teamsOwnerPID(holderPID: 7, regularTeamsPIDs: [8, 7, 9]) == 7)
  }

  @Test("A depth16 Teams button proves a call using the owner but preserves microphone holder identity")
  func teamsCallProof() {
    let fixture = teamsFixture()
    var access = fixture.access
    let wake = access.wake
    var woke: [Int32] = []
    let owner = AXUIElementCreateApplication(72_000)
    var windowRequests: [AXUIElement] = []
    let response = fixture.response
    fixture.response = { rig, node, attribute in
      if attribute == "AXWindows" {
        windowRequests.append(node)
        return CFEqual(node, owner) ? .value(rig.windows as CFArray) : .failed
      }
      return response?(rig, node, attribute)
    }
    access.regularTeamsPIDs = { [72_000] }
    access.wake = { pid, seconds in woke.append(pid); return wake(pid, seconds) }
    #expect(Reader.nativeCallEvidence(family: .teams, holderPID: fixture.pid, access: access)
      == .call(family: .teams, room: "pid-70000"))
    #expect(woke == [72_000])
    #expect(windowRequests.count == 1)
    #expect(windowRequests.allSatisfy { CFEqual($0, owner) })
    #expect(fixture.refused.isEmpty, "Every exact descendant handle must receive its timeout")
  }

  @Test("Teams proof never comes from a near identifier, a label or a non-button")
  func teamsExactControl() {
    for (role, identifier) in [
      ("AXPopUpButton", "hangup-button"), ("AXButton", "hangup-button-more-options"),
      ("AXButton", "Leave"), ("AXButton", "Hangup-button"),
    ] {
      let fixture = teamsFixture(identifier: .value(identifier as CFString), role: role)
      fixture.title = "hangup-button"
      #expect(Reader.nativeCallEvidence(family: .teams, holderPID: fixture.pid, access: fixture.access)
        == .microphoneOnly(family: .teams, room: "pid-70000"))
    }
  }

  @Test("Ambiguous or missing Teams owners retain Ask evidence without touching Accessibility")
  func teamsUnresolvedOwner() {
    let candidates: [[Int32]] = [[], [72_000, 72_001]]
    for pids in candidates {
      let fixture = teamsFixture()
      var access = fixture.access
      access.regularTeamsPIDs = { pids }
      access.wake = { _, _ in
        Issue.record("Unresolved owner must not wake an app")
        return AccessibilityWake.Report(roleError: .cannotComplete, roleReadExhausted: false,
          manual: nil, manualEnabled: false)
      }
      #expect(Reader.nativeCallEvidence(family: .teams, holderPID: fixture.pid, access: access)
        == .microphoneOnly(family: .teams, room: "pid-70000"))
      #expect(fixture.messages.isEmpty)
    }
  }

  @Test("Unreadable, malformed, partial and late Teams scans never grant automatic proof")
  func teamsUnprovenScan() {
    for failure in ["wake", "windows", "partial", "malformed", "deadline", "timeoutSetup", "lateRead"] {
      let fixture = teamsFixture()
      let response = fixture.response
      fixture.response = { rig, node, attribute in
        if failure == "windows", attribute == "AXWindows" { return .failed }
        if failure == "partial", attribute == "AXChildren" { return .failed }
        if failure == "malformed", attribute == "AXDOMIdentifier" {
          return .value(["hangup-button"] as CFArray)
        }
        if failure == "lateRead", attribute == "AXDOMIdentifier" {
          rig.instant = rig.instant.advanced(by: .seconds(2))
        }
        return response?(rig, node, attribute)
      }
      fixture.refuseSetup = failure == "timeoutSetup"
      var access = fixture.access
      let wake = access.wake
      access.wake = { pid, seconds in
        if failure == "deadline" { fixture.instant = fixture.instant.advanced(by: .seconds(2)) }
        if failure == "wake" {
          return AccessibilityWake.Report(roleError: .cannotComplete, roleReadExhausted: false,
            manual: nil, manualEnabled: false)
        }
        return wake(pid, seconds)
      }
      #expect(Reader.nativeCallEvidence(family: .teams, holderPID: fixture.pid, access: access)
        == .microphoneOnly(family: .teams, room: "pid-70000"), "Failure: \(failure)")
      if ["wake", "deadline", "timeoutSetup"].contains(failure) {
        #expect(fixture.messages.isEmpty, "Must not message after refusal: \(failure)")
      }
    }
  }

  @Test("A valid later Teams control wins an earlier unreadable window")
  func teamsPositiveAfterUncertainty() {
    let fixture = teamsFixture()
    let bad = AXUIElementCreateApplication(72_000)
    fixture.windows = [bad, fixture.window]
    let response = fixture.response
    fixture.response = { rig, node, attribute in
      if CFEqual(node, bad) { return .failed }
      return response?(rig, node, attribute)
    }
    #expect(Reader.nativeCallEvidence(family: .teams, holderPID: fixture.pid, access: fixture.access)
      == .call(family: .teams, room: "pid-70000"))
  }

  @Test("Teams depth and node limits cannot turn unsearched descendants into call proof")
  func teamsTraversalLimits() {
    let deep = teamsFixture(depth: 33)
    #expect(Reader.nativeCallEvidence(family: .teams, holderPID: deep.pid, access: deep.access)
      == .microphoneOnly(family: .teams, room: "pid-70000"))
    let wide = Fixture()
    let children = (1...801).map { AXUIElementCreateApplication(Int32(73_000 + $0)) }
    wide.response = { rig, node, attribute in
      switch attribute {
      case "AXChildren": return CFEqual(node, rig.window) ? .value(children as CFArray) : .missing
      case "AXRole": return .value((CFEqual(node, children[800]) ? "AXButton" : "AXGroup") as CFString)
      case "AXDOMIdentifier": return .value("hangup-button" as CFString)
      default: return nil
      }
    }
    #expect(Reader.nativeCallEvidence(family: .teams, holderPID: wide.pid, access: wide.access)
      == .microphoneOnly(family: .teams, room: "pid-70000"))
  }

}
