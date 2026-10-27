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
        read: { element, attribute in self.read(element, attribute) })
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
      case "AXTitle": return title.map { .value($0 as CFString) } ?? .missing
      case "AXRole": return .value((CFEqual(element, page) ? "AXWebArea" : "AXWindow") as CFString)
      case "AXChildren":
        return CFEqual(element, window) ? .value([page] as CFArray) : .missing
      case "AXURL": return pageURL.map { .value($0 as CFString) } ?? .missing
      case "AXDocument": return document.map { .value($0 as CFString) } ?? .missing
      default: return .missing
      }
    }
  }

  @Test("Healthy Zoom identifier still proves the call")
  func healthyZoomIdentifier() {
    let fixture = Fixture()
    #expect(Reader.callWindow(family: .zoom, appPID: fixture.pid, access: fixture.access)
      == .call(family: .zoom, room: "pid-70000"))
  }

  @Test("Healthy browser descendant URL still proves the call")
  func healthyBrowserURL() {
    let fixture = Fixture()
    #expect(Reader.meetingPage(appPID: fixture.pid, access: fixture.access)
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

  @Test("A quick role-read error can still wake a readable browser call")
  func quickBrowserRoleError() {
    let fixture = Fixture()
    fixture.response = { rig, node, attribute in
      if attribute == "AXRole", CFEqual(node, rig.window) == false,
        CFEqual(node, rig.page) == false { return .failed }
      return nil
    }
    #expect(Reader.meetingPage(appPID: fixture.pid, access: fixture.access)
      == .call(family: .googleMeet, room: "abc-defg-hij"))
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

}
