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
    ShareLayout(  // minimized with its video hidden, nobody sharing (#4935)
      file: "725-collapsed", people: ["Dana Fox"], talking: ["Dana Fox"], countHidden: false,
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

  // MARK: - Zoom 7.2.5 (#4935)

  @Test(
    "an open participants list whose rows refuse their label is still read, row by row",
    arguments: [("725-panel-open", 2), ("725-hidden-list", 3)])
  func openListReads(file: String, rows: Int) throws {
    let copy = try shareCapture(file, account: nil)
    #expect(copy.completeness == .complete)
    #expect(copy.toleratedFailures == rows)
    let reading = ZoomAppSpeakerReader.read(windows: copy.windows)
    #expect(reading.participantListComplete)
    #expect(reading.participantCount == rows)
    #expect(reading.boundSelfMarks == ["Host Person"])
    func drawnHalf(_ node: CallAXNode) -> CallAXNode {
      CallAXNode(
        role: node.role, title: node.title, description: node.description, value: node.value,
        identifier: node.identifier,
        children: node.children.filter { $0.role != "AXStaticText" || $0.label != "Alex Rivera" }
          .map(drawnHalf))
    }
    let half = copy.windows.map { CallAXWindow(title: $0.title, root: drawnHalf($0.root)) }
    #expect(ZoomAppSpeakerReader.read(windows: half).participantListComplete == false)
  }

  @Test("a third person shown anywhere is kept, in a copy nothing else uses too")
  func thirdPersonIsKept() throws {
    func window(_ labels: [String], _ role: String = "AXTabGroup") -> CallAXWindow {
      let nodes = labels.map { CallAXNode(role: role, description: $0) }
      return CallAXWindow(title: "", root: CallAXNode(role: "AXWindow", children: nodes))
    }
    func sightings(_ copies: [CallAXWindow]...) -> Int? {
      var all = CallSpeakerAccumulator(surface: .zoomApp, rules: nil, lag: nil)
      for (index, windows) in copies.enumerated() {
        let people = ZoomAppSpeakerReader.shownPeople(windows: windows)
        all.add(
          nil,
          context: CallCaptureContext(
            completeness: .unreadable, scope: .unresolved, shownPeople: people),
          observationMs: index * 500)
      }
      return all.health.thirdPersonSightings
    }
    let (host, alex) = (
      "Host, Computer audio muted, Video off", "Alex, Computer audio muted, Video off"
    )
    let pair = [window([host, alex])]
    #expect(sightings(pair, pair) == 0)
    let joining = [window([host, "Alex, No audio connected, Video off"])]
    #expect(sightings(joining + [window(["Talking: Alex"], "AXStaticText")]) == 0, "named too")
    #expect(sightings(pair, [window(["Dana, Computer audio muted"])]) == 1)
    #expect(sightings(pair, [window(["Talking: Dana"], "AXStaticText")]) == 1)
    #expect(sightings(pair + [window([host, alex, alex])]) == 1, "one name on two thumbnails")
    #expect(sightings([window([host, alex, "Dana, No audio connected, Video off"])]) == 1)
    let row = CallAXNode(role: "AXCell", identifier: ZoomAppSpeakerReader.joinedRowIdentifier)
    let list = CallAXNode(
      role: "AXOutline", description: "Participants list", children: [row, row, row])
    #expect(sightings([CallAXWindow(title: "", root: list)]) == 1, "a third row still joining")
    let waiting = "Open participants panel, closed, 3 participants, 1 person is waiting"
    #expect(sightings(pair + [window([waiting], "AXButton")]) == 1)
    let twice = ZoomAppSpeakerReader.ShareContext(
      hostShare: false, guestShare: false, countShown: true, listedTwice: ["Dana Fox"])
    let label = try shareCapture("725-collapsed", account: nil).windows
    #expect(ZoomAppSpeakerReader.read(windows: label, share: twice).sharedNames == ["Dana Fox"])
  }

  @Test(
    "with no mark, the tile that moves with the talker is the last thumbnail, or the only one",
    arguments: [("725-gallery", 3, false), ("725-speaker", 3, true), ("725-minimized", 0, false)])
  func followTile(file: String, people: Int, large: Bool) throws {
    let copy = try shareCapture(file, account: ["Host Person(host@example.com)"])
    let reading = try #require(CallSpeakerSurfaceReader.zoomReading(copy, labels: .builtIn))
    #expect(reading.speaking.isEmpty)
    #expect(reading.follow?.name == "Dana Fox")
    #expect(reading.follow?.mayVote == true)
    #expect(reading.follow?.place.people.count == people)
    #expect(reading.follow?.place.largeTile == large)
    let unknown = try shareCapture(file, account: nil)
    #expect(
      CallSpeakerSurfaceReader.zoomReading(unknown, labels: .builtIn)?.follow?.mayVote == false)
    for other in ["hs-thumb-bea", "725-collapsed", "gs-sbs-gallery-bea"] {
      let marked = try shareCapture(other, account: ["Host Person(host@example.com)"])
      #expect(CallSpeakerSurfaceReader.zoomReading(marked, labels: .builtIn)?.follow == nil)
    }
  }

  /// Readings of a Gallery at `times`: who is last from each time on, `-` before a muted name and
  /// `+` for a real mark. The times of the observations that became talking ones.
  private func votes(
    _ script: [(Int, String)], until end: Int, times: [Int]? = nil, bring: [Int: String] = [:],
    breakAt: Int? = nil, runs: Int = 1_000, lag: Int = 500, count: Int? = nil
  ) -> [Int] {
    var limits = CallEvidenceLimits.current
    limits.runs = runs
    var all = CallSpeakerAccumulator(
      surface: .zoomApp, rules: nil, lag: CallSpeakerLag(milliseconds: lag), limits: limits)
    for ms in times ?? Array(stride(from: 0, through: end, by: 500)) {
      if ms == breakAt { all.noteInterruption() }
      let last = script.last { $0.0 <= ms }!.1
      let name = last.filter { $0 != "-" && $0 != "+" }
      let people = ["Host", "Alex", "Dana"] + (bring.filter { $0.key <= ms }.map(\.value))
      let labels =
        people.filter { $0 != name }.map { "\($0), Computer audio unmuted, Video off" } + [
          "\(name), Computer audio \(last.hasPrefix("-") ? "muted" : "unmuted"), Video on"
            + (last.hasPrefix("+") ? ", active speaker" : "")
        ]
      let root = CallAXNode(
        role: "AXWindow", identifier: "zm.meeting.window.main",
        children: labels.map { CallAXNode(role: "AXTabGroup", description: $0) }
          + (count.map {
            [
              CallAXNode(
                role: "AXButton", description: "Open participants panel, closed, \($0) participants")
            ]
          } ?? []))
      let windows = [CallAXWindow(title: "Zoom Meeting", root: root)]
      var reading = ZoomAppSpeakerReader.read(windows: windows, accountTitles: ["Host(h@e.com)"])
      reading.follow = ZoomAppSpeakerReader.follow(
        windows: windows, share: .none, reading: reading)
      all.add(
        reading, context: CallCaptureContext(completeness: .complete, scope: .resolved),
        observationMs: ms)
    }
    let talking = all.segment(endMs: nil, endReason: nil).observations.filter { $0.speaking != [] }
    #expect(all.health.admittedSpeakingObservations == talking.count)
    #expect(all.health.admittedQuietObservations == all.observations.count - talking.count)
    return talking.map(\.observationMs)
  }

  @Test("one move of the tile is one vote, four seconds after it, once the tile has held")
  func moveVotes() {
    #expect(votes([(0, "Alex"), (2_000, "Dana")], until: 12_000) == [6_000])
    #expect(votes([(0, "Alex"), (2_000, "Dana")], until: 6_500) == [6_000], "0.5 s after the stamp")
    #expect(votes([(0, "Alex"), (2_000, "Dana")], until: 6_000) == [])
    #expect(votes([(0, "Alex"), (2_000, "Dana")], until: 12_000, runs: 2) == [], "at the cap")
    let two = [(0, "Alex"), (2_000, "Dana"), (10_000, "Alex")]
    #expect(votes(two, until: 18_000, runs: 4) == [6_000], "one vote fills the cap")
    #expect(votes([(0, "Dana")], until: 12_000) == [], "standing still")
    #expect(votes([(0, "Alex"), (2_000, "Dana")], until: 12_000, count: 3) == [6_000])
    #expect(votes([(0, "Alex"), (2_000, "Dana")], until: 12_000, count: 4) == [], "one hidden")
    #expect(votes([(0, "Alex"), (2_000, "Dana")], until: 12_000, lag: -500) == [5_000])
    #expect(votes([(0, "Alex"), (2_000, "Dana")], until: 6_000, lag: -500) == [])
    // Turns with the talker muting in between: one vote each, none for the user's own turn.
    let turns = [(0, "Alex"), (2_000, "Dana"), (8_000, "-Dana"), (9_000, "Alex"), (16_000, "Host")]
    #expect(votes(turns + [(22_000, "Dana")], until: 30_000) == [6_000, 13_000, 26_000])
    // Another person's turn inside Zoom's hold, then the first again: the tile never moved, and no
    // vote lies inside the hold. A tile that leaves and returns is a new move of its own.
    #expect(votes([(0, "Alex"), (2_000, "Dana"), (4_750, "Alex")], until: 8_500) == [])
    let back = [(0, "Alex"), (2_000, "Dana"), (4_000, "Alex"), (4_500, "Dana")]
    #expect(votes(back, until: 8_500) == [], "left and returned inside 4 s")
    #expect(votes(back, until: 9_500) == [8_500])
    // A short reply before a long turn, with the tile moving as Zoom did in the call with a wrong
    // vote: the long speaker's reading is far inside the long turn.
    let reply = [(0, "Dana"), (19_600, "Alex"), (22_300, "Eve"), (32_600, "Alex")]
    #expect(votes(reply, until: 31_000, bring: [0: "Eve"]) == [26_500])
  }

  @Test("a muted, new, marked or interrupted move is no vote")
  func movesThatDoNotVote() {
    #expect(votes([(0, "Alex"), (2_000, "-Dana"), (2_500, "Dana")], until: 12_000) == [])
    let muted = [(0, "Alex"), (2_000, "Dana"), (5_500, "-Dana"), (6_000, "Dana")]
    #expect(votes(muted, until: 12_000) == [])
    #expect(votes([(0, "Alex"), (2_000, "Dana")], until: 12_000, bring: [2_000: "Eve"]) == [])
    #expect(votes([(0, "Alex"), (2_000, "Dana")], until: 12_000, bring: [6_000: "Eve"]) == [])
    #expect(votes([(0, "+Alex"), (500, "Alex"), (2_000, "Dana")], until: 12_000) == [0])
    #expect(votes([(0, "Alex"), (2_000, "Dana")], until: 12_000, breakAt: 5_500) == [])
    // The first reading 4 s after the move comes 4.6 s after it, through gaps that are allowed.
    let slow = [1_500, 2_000, 3_000, 4_000, 5_000, 5_900, 6_600, 7_100, 7_600, 8_100]
    #expect(votes([(0, "Alex"), (2_000, "Dana")], until: 0, times: slow) == [], "stamp too late")
    let ontime = slow.map { $0 == 6_600 ? 6_500 : $0 }
    #expect(votes([(0, "Alex"), (2_000, "Dana")], until: 0, times: ontime) == [6_500])
    // A capture gap of more than a second, at the move, before the stamp or between it and the check.
    for gap in [1_500, 4_000, 6_000] {
      let times = stride(from: 0, through: 12_000, by: 500).filter { !(gap..<gap + 1_000 ~= $0) }
      #expect(votes([(0, "Alex"), (2_000, "Dana")], until: 0, times: times) == [], "\(gap)")
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
