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
      CallSpeakerSurfaceReader.scope(
        surface: .zoomApp, capture: copy, family: .zoom, zoomLabels: .builtIn) == .resolved)
    let reading = try #require(
      CallSpeakerSurfaceReader.read(
        surface: .zoomApp, capture: copy, rules: TalkerRulesSnapshot.empty.rules,
        zoomLabels: .builtIn))
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
      CallSpeakerSurfaceReader.scope(
        surface: .zoomApp, capture: copy, family: .zoom, zoomLabels: .builtIn) == .resolved)
    let reading = try #require(
      CallSpeakerSurfaceReader.read(
        surface: .zoomApp, capture: copy, rules: TalkerRulesSnapshot.empty.rules,
        zoomLabels: .builtIn))
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
        surface: .zoomApp, capture: copy, rules: TalkerRulesSnapshot.empty.rules,
        zoomLabels: .builtIn))
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
          surface: .zoomApp, capture: copy, rules: TalkerRulesSnapshot.empty.rules,
          zoomLabels: .builtIn))
      #expect(reading.countHiddenByShare == false)
      #expect(reading.talkerSource != .label)
      #expect(reading.talkerSource != .loneTile)
    }
  }

  // MARK: - Other Zoom languages (#4350)

  /// One German or Japanese layout from the #4350 discovery (solo meeting, Zoom 7.1.9 (88375),
  /// run `20261103-131437-4350-zoom-languages-discovery-83ca`; Home window removed).
  struct LanguageLayout: Sendable, CustomTestStringConvertible {
    enum Shape: Sendable {
      /// The meeting window: one large tile; `listed` when the participants list is open.
      case meeting(listed: Bool)
      /// The user shares: the floating window's one tile (video state `Video off`, English).
      case hostShareTile
      /// The user shares, floating window collapsed: one quiet Talking text, no tile.
      case collapsed
    }
    let file: String
    let shape: Shape
    var testDescription: String { file }
  }

  static let languageLayouts: [LanguageLayout] = [
    LanguageLayout(file: "de-2-meeting", shape: .meeting(listed: false)),
    LanguageLayout(file: "de-3-panel", shape: .meeting(listed: true)),
    LanguageLayout(file: "ja-3-panel", shape: .meeting(listed: true)),
    LanguageLayout(file: "de-5-share", shape: .hostShareTile),
    LanguageLayout(file: "de-7-speaker", shape: .hostShareTile),
    LanguageLayout(file: "ja-5-share", shape: .hostShareTile),
    LanguageLayout(file: "de-6-collapsed", shape: .collapsed),
    LanguageLayout(file: "ja-6-collapsed", shape: .collapsed),
    LanguageLayout(file: "ja-6b-toolbar", shape: .collapsed),
  ]

  @Test("German and Japanese layouts read with Zoom's own words", arguments: languageLayouts)
  func languageLayoutReads(layout: LanguageLayout) throws {
    let labels = try ZoomLabelsTests.fixtures()
    let copy = try shareCapture(layout.file, account: nil)
    #expect(copy.completeness == .complete)
    #expect(
      CallSpeakerSurfaceReader.scope(
        surface: .zoomApp, capture: copy, family: .zoom, zoomLabels: labels) == .resolved)
    let reading = try #require(
      CallSpeakerSurfaceReader.read(
        surface: .zoomApp, capture: copy, rules: TalkerRulesSnapshot.empty.rules,
        zoomLabels: labels))
    let share = ZoomAppSpeakerReader.shareContext(windows: copy.windows, labels: labels)
    // Mute (§3.6): the meeting window's translated button; with no meeting window (the user
    // shares) it is unknown by design, so the microphone stays live.
    let mute = CallSelfMuteReader.read(
      surface: .zoomApp, capture: copy, rules: CallMuteRules.testPackaged.withZoomLabels(labels))
    switch layout.shape {
    case .meeting: #expect(mute == .muted)
    case .hostShareTile, .collapsed: #expect(mute == .unknown)
    }
    switch layout.shape {
    case .meeting(let listed):
      #expect(share.isSharing == false)
      #expect(reading.participants.compactMap(\.name) == [Self.user])
      #expect(reading.participantCount == 1)
      #expect(reading.rosterFromParticipantList == listed)
      #expect(reading.participantListComplete == listed)
      #expect(reading.roster.selfNames == (listed ? [Self.user] : []))
      #expect(reading.boundSelfMarks == (listed ? [Self.user] : []))
      #expect(reading.participants.first?.isSelf == listed)
      #expect(share.countShown)
    case .hostShareTile:
      #expect(share.hostShare)
      #expect(share.tileCount == 1)
      // The lone tile is the user's own: with no account and no list it names no one.
      #expect(reading.talkerSource == .loneTile)
      #expect(reading.participants.isEmpty)
    case .collapsed:
      #expect(share.hostShare)
      #expect(share.tileCount == 0)
      #expect(reading.talkerSource == .label)
      #expect(reading.speaking.isEmpty)
    }
  }

  @Test("Before #4350 these layouts read nothing: English words alone find no tile")
  func languageLayoutsNeedLabels() throws {
    for file in ["de-3-panel", "ja-3-panel", "de-5-share"] {
      let copy = try shareCapture(file, account: nil)
      let reading = CallSpeakerSurfaceReader.read(
        surface: .zoomApp, capture: copy, rules: TalkerRulesSnapshot.empty.rules,
        zoomLabels: .builtIn)
      #expect(reading?.participants.isEmpty ?? true, "\(file)")
      #expect(reading?.roster.selfNames.isEmpty ?? true, "\(file)")
    }
  }
}
