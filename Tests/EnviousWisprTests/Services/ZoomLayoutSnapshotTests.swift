import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// #4013 reading resilience: when these fail, a Zoom layout that real calls use (chat panel open,
/// full screen, screen share) stops giving speaker names, or its mute button stops being read.
///
/// Fixtures are SURVEY copies of the live Zoom Workplace accessibility tree, one per layout,
/// taken during the 2026-11-02 live UAT with `zsnap.py` (run
/// `20261102-210839-4013-reading-resilience-live-uat-c8b6`): each node's role, labels and
/// identifier, and the attributes Zoom refused (`failed`). They replay through the real capture
/// walker with the Zoom policy, so a refused read the app must tolerate, or must not, is
/// reproduced exactly. Re-take a fixture after a Zoom update changes a layout; no live call is
/// needed to rerun these.
@Suite("Zoom layouts replayed from live snapshots", .tags(.productOutcome))
struct ZoomLayoutSnapshotTests {

  private struct Snapshot: Decodable {
    struct Node: Decodable {
      let role: String
      let title: String?
      let description: String?
      let value: String?
      let identifier: String?
      let failed: [String]?
      let children: [Node]?
    }
    struct Window: Decodable {
      let title: String?
      let root: Node
    }
    let windows: [Window]
  }

  /// One layout and what the call shows in it.
  struct Layout: Sendable, CustomTestStringConvertible {
    let file: String
    /// The participants the reading must establish, in order.
    let people: [String]
    let mute: CallSelfMute
    /// Failed reads the Zoom policy must tolerate in this layout (chat panel: its input and list).
    let tolerated: Int
    var testDescription: String { file }
  }

  /// Mute in the host-share layout is unknown: Zoom hides the meeting window while the user
  /// shares and moves the mute button to its share toolbar, which the reader never trusts (§3.2
  /// mute contract), so the microphone stays live.
  static let layouts: [Layout] = [
    Layout(file: "chat", people: ["Saurabh A Vaish", "Alex Rivera"], mute: .muted, tolerated: 2),
    Layout(
      file: "full-screen", people: ["Saurabh A Vaish", "Alex Rivera"], mute: .unmuted, tolerated: 0),
    Layout(
      file: "host-share", people: ["Saurabh A Vaish", "Alex Rivera"], mute: .unknown, tolerated: 0),
  ]

  /// The snapshot as a literal tree for the live walker: every node gets an id, its labels, and
  /// its refused attributes as failing reads.
  private func tree(_ file: String) throws -> (CallSpeakerCaptureTests.Tree, [Int]) {
    let url = RepoRoot.url.appending(
      path: "Tests/EnviousWisprTests/Resources/ZoomLayouts/\(file).json")
    let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: url))
    let tree = CallSpeakerCaptureTests.Tree()
    var next = 1
    func add(_ node: Snapshot.Node) -> Int {
      let id = next
      next += 1
      let kids = (node.children ?? []).map(add)
      tree.node(id, node.role, children: kids)
      var texts: [CallAXAttribute: String] = [:]
      texts[.title] = node.title
      texts[.description] = node.description
      texts[.value] = node.value
      texts[.identifier] = node.identifier
      tree.texts[id] = texts
      for attribute in node.failed ?? [] { tree.failing.insert("\(id).\(attribute)") }
      return id
    }
    let windows = snapshot.windows.map { window -> Int in
      let id = add(window.root)
      if let title = window.title { tree.texts[id]?[.title] = title }
      return id
    }
    return (tree, windows)
  }

  private func capture(_ layout: Layout) throws -> CallAXCapture {
    let (tree, windows) = try tree(layout.file)
    var host: UInt64 = 100
    return CallSpeakerCapture.capture(
      windows: windows, access: tree.access(), bounds: .standard, policy: .zoomApp,
      protectedRoles: CallMuteRules.testPackaged.protectedRoles, keepPage: { _ in true },
      hostTime: {
        host += 10
        return host
      })
  }

  @Test(
    "each live layout copies whole, resolves to one call and establishes its people",
    arguments: layouts)
  func layoutReads(layout: Layout) throws {
    let copy = try capture(layout)
    #expect(copy.completeness == .complete)
    #expect(copy.toleratedFailures == layout.tolerated)
    #expect(
      CallSpeakerSurfaceReader.scope(surface: .zoomApp, capture: copy, family: .zoom) == .resolved)
    let reading = try #require(
      CallSpeakerSurfaceReader.read(
        surface: .zoomApp, capture: copy, rules: TalkerRulesSnapshot.empty.rules))
    #expect(reading.participants.compactMap(\.name) == layout.people)
    #expect(reading.participantIdentityEstablished)
    let context = CallCaptureContext(completeness: copy.completeness, scope: .resolved)
    #expect(CallSpeakerAdmission.admission(of: reading, context: context) == .admitted)
  }

  @Test("each live layout reads the mute button from the meeting window", arguments: layouts)
  func layoutMute(layout: Layout) throws {
    let copy = try capture(layout)
    #expect(
      CallSelfMuteReader.read(surface: .zoomApp, capture: copy, rules: .testPackaged)
        == layout.mute)
  }
}
