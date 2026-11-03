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

  // MARK: - Screen share layouts (#4013 share plan §3.0-3.3)

  /// One share layout, taken 2026-11-03 while the named guest talked (run
  /// `20261103-083021-4013-share-talking-label-discovery-c469`), except `p2-guest-share`
  /// (2026-11-02, the guest's tile muted at that moment).
  struct ShareLayout: Sendable, CustomTestStringConvertible {
    let file: String
    let people: [String]
    let talking: [String]
    /// The user shares and Zoom showed no count anywhere.
    let countHidden: Bool
    /// The reading proves a two-person call although the share hid every count.
    let hiddenCountPair: Bool
    var testDescription: String { file }
  }

  static let user = "Saurabh A Vaish"
  /// The checked account title the live copies did not capture (the AX snapshots hold windows
  /// only), supplied as separate context the way `CallSpeakerCapture` adds it.
  static let accountTitles = ["Saurabh A Vaish(saurabhav@gmail.com)"]

  static let shareLayouts: [ShareLayout] = [
    ShareLayout(
      file: "gs-sbs-gallery-bea", people: [user, "Alex Rivera", "Bea Chen"], talking: ["Bea Chen"],
      countHidden: false, hiddenCountPair: false),
    ShareLayout(
      file: "gs-sbs-speaker-bea", people: ["Bea Chen"], talking: ["Bea Chen"],
      countHidden: false, hiddenCountPair: false),
    ShareLayout(
      file: "hs-hidden-bea", people: ["Bea Chen"], talking: ["Bea Chen"], countHidden: true,
      hiddenCountPair: false),
    ShareLayout(
      file: "hs-speaker-bea", people: ["Bea Chen"], talking: ["Bea Chen"], countHidden: true,
      hiddenCountPair: false),
    ShareLayout(
      file: "hs-thumb-bea", people: [user, "Alex Rivera", "Bea Chen"], talking: ["Bea Chen"],
      countHidden: true, hiddenCountPair: false),
    ShareLayout(
      file: "p2-hidden-alex", people: ["Alex Rivera"], talking: ["Alex Rivera"],
      countHidden: true, hiddenCountPair: false),
    ShareLayout(
      file: "p2-speaker-alex", people: ["Alex Rivera"], talking: ["Alex Rivera"],
      countHidden: true, hiddenCountPair: false),
    ShareLayout(
      file: "p2-thumb-alex", people: [user, "Alex Rivera"], talking: [], countHidden: true,
      hiddenCountPair: true),
    ShareLayout(
      file: "p2-guest-share", people: ["Alex Rivera"], talking: [], countHidden: false,
      hiddenCountPair: false),
  ]

  private func shareCapture(_ file: String, account: [String]?) throws -> CallAXCapture {
    let copy = try capture(Layout(file: file, people: [], mute: .unknown, tolerated: 0))
    return CallAXCapture(
      windows: copy.windows, documents: copy.documents, completeness: copy.completeness,
      readStartHostTime: copy.readStartHostTime, readEndHostTime: copy.readEndHostTime,
      toleratedFailures: copy.toleratedFailures, accountTitles: account)
  }

  @Test(
    "each live share layout shows who talks, and the user's share hides the count",
    arguments: shareLayouts)
  func shareLayoutReads(layout: ShareLayout) throws {
    let copy = try shareCapture(layout.file, account: Self.accountTitles)
    #expect(copy.completeness == .complete)
    #expect(
      CallSpeakerSurfaceReader.scope(surface: .zoomApp, capture: copy, family: .zoom) == .resolved)
    let reading = try #require(
      CallSpeakerSurfaceReader.read(
        surface: .zoomApp, capture: copy, rules: TalkerRulesSnapshot.empty.rules))
    #expect(reading.participants.compactMap(\.name) == layout.people)
    #expect(reading.speaking == layout.talking)
    #expect(reading.participantIdentityEstablished == true)
    #expect(reading.countHiddenByShare == layout.countHidden)
    #expect((CallSpeakerAccumulator.pairEvidence(reading) != nil) == layout.hiddenCountPair)
    let context = CallCaptureContext(completeness: copy.completeness, scope: .resolved)
    #expect(CallSpeakerAdmission.admission(of: reading, context: context) == .admitted)
  }

  @Test("without the account, the new share signals stay quiet", arguments: shareLayouts)
  func shareLayoutNeedsSelf(layout: ShareLayout) throws {
    let copy = try shareCapture(layout.file, account: nil)
    let reading = try #require(
      CallSpeakerSurfaceReader.read(
        surface: .zoomApp, capture: copy, rules: TalkerRulesSnapshot.empty.rules))
    // Flagged tiles (gallery and thumbnails) still read as before; label and lone-tile readings
    // need the user's name and are quiet without it.
    switch reading.talkerSource {
    case .label, .loneTile: #expect(reading.speaking.isEmpty)
    case .flag, nil: #expect(reading.speaking == layout.talking)
    }
  }

  @Test("the earlier layouts with no share keep their reading and prove no hidden count")
  func noShareControls() throws {
    for file in ["chat", "full-screen"] {
      let copy = try shareCapture(file, account: Self.accountTitles)
      #expect(ZoomAppSpeakerReader.shareContext(windows: copy.windows).isSharing == false)
      let reading = try #require(
        CallSpeakerSurfaceReader.read(
          surface: .zoomApp, capture: copy, rules: TalkerRulesSnapshot.empty.rules))
      #expect(reading.countHiddenByShare == false)
      #expect(reading.talkerSource != .label)
      #expect(reading.talkerSource != .loneTile)
    }
  }
}
