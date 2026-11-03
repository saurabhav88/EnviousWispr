import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// #4248: when these fail, EnviousMeet can silence the user's voice while they are talking, or
/// keep room talk while they are muted, because it trusted the wrong button, a broken copy,
/// another page or a label it does not know.
///
/// Trees are SYNTHETIC literal copies shaped like the live reads of 2026-10-30
/// (`docs/audits/2026-10-30-4248/live-ax-probes.md`): Zoom 7.1.9, Teams 26276.505 and Google
/// Meet in Chrome 156, English labels only.
extension CallMuteRules {
  /// The packaged rules, read through the app's own lookup; tests pass them explicitly, since
  /// the reader has no implicit default (#4013 reading resilience §3.5).
  static let testPackaged: CallMuteRules = {
    guard let url = CallMuteRules.bundledURL, let data = try? Data(contentsOf: url),
      let rules = try? CallMuteRules(validating: data)
    else { preconditionFailure("the packaged call-mute-rules.json did not load") }
    return rules
  }()
}

@Suite("Call self-mute reader", .tags(.productOutcome))
struct CallSelfMuteReaderTests {
  static let meetURL = "https://meet.google.com/pwe-iofm-gdv"
  static let otherMeetURL = "https://meet.google.com/abc-defg-hij"

  private func capture(
    windows: [CallAXWindow] = [], documents: [CallAXDocument] = [],
    completeness: CallCaptureContext.Completeness = .complete
  ) -> CallAXCapture {
    CallAXCapture(
      windows: windows, documents: documents, completeness: completeness, readStartHostTime: 1,
      readEndHostTime: 2)
  }

  // MARK: - Zoom app

  private func zoomButton(_ label: String?, identifier: String? = "audio") -> CallAXNode {
    CallAXNode(role: "AXButton", description: label, identifier: identifier)
  }

  private func zoomWindow(_ controls: [CallAXNode], identifier: String? = "zm.meeting.window.main")
    -> CallAXWindow
  {
    CallAXWindow(
      title: "Zoom Meeting",
      root: CallAXNode(role: "AXWindow", identifier: identifier, children: controls))
  }

  @Test("Zoom: the meeting window's audio button gives both states")
  func zoomStates() {
    #expect(
      CallSelfMuteReader.read(
        surface: .zoomApp, capture: capture(windows: [zoomWindow([zoomButton("Unmute my audio")])]), rules: .testPackaged)
        == .muted)
    #expect(
      CallSelfMuteReader.read(
        surface: .zoomApp, capture: capture(windows: [zoomWindow([zoomButton("Mute my audio")])]), rules: .testPackaged)
        == .unmuted)
  }

  @Test("Zoom: a preview label, an unknown language, a wrong role or no button is unknown")
  func zoomUnknowns() {
    let cases: [[CallAXNode]] = [
      [zoomButton("Audio, turn off, currently unmuted")],  // the join preview's own wording
      [zoomButton("Réactiver mon audio")],
      [zoomButton(nil)],
      [CallAXNode(role: "AXCheckBox", description: "Unmute my audio", identifier: "audio")],
      [zoomButton("Unmute my audio", identifier: "video")],
      [],
    ]
    for controls in cases {
      #expect(
        CallSelfMuteReader.read(
          surface: .zoomApp, capture: capture(windows: [zoomWindow(controls)]), rules: .testPackaged)
          == .unknown, "\(controls)")
    }
  }

  @Test("Zoom: two audio buttons, two meeting windows or none is unknown")
  func zoomAmbiguous() {
    let twoButtons = zoomWindow([zoomButton("Unmute my audio"), zoomButton("Unmute my audio")])
    #expect(
      CallSelfMuteReader.read(surface: .zoomApp, capture: capture(windows: [twoButtons]), rules: .testPackaged)
        == .unknown)
    let one = zoomWindow([zoomButton("Unmute my audio")])
    #expect(
      CallSelfMuteReader.read(surface: .zoomApp, capture: capture(windows: [one, one]), rules: .testPackaged) == .unknown)
    // The home window is not the meeting: its button is never read.
    let home = CallAXWindow(
      title: "Zoom Workplace",
      root: CallAXNode(role: "AXWindow", children: [zoomButton("Unmute my audio")]))
    #expect(
      CallSelfMuteReader.read(surface: .zoomApp, capture: capture(windows: [home]), rules: .testPackaged) == .unknown)
    // A button outside the meeting window does not count, and the meeting window's own decides.
    let mixed = capture(windows: [home, zoomWindow([zoomButton("Mute my audio")])])
    #expect(CallSelfMuteReader.read(surface: .zoomApp, capture: mixed, rules: .testPackaged) == .unmuted)
  }

  // MARK: - Teams app

  private func teamsButton(_ label: String?, dom: String? = "microphone-button") -> CallAXNode {
    CallAXNode(role: "AXButton", title: label, description: label, domIdentifier: dom)
  }

  private func teamsWindow(_ controls: [CallAXNode], title: String = "Meeting with Sam")
    -> CallAXWindow
  {
    let selfTile = CallAXNode(role: "AXMenuItem", title: "Myself video, Saurabh Vaish, Muted")
    return CallAXWindow(
      title: title, root: CallAXNode(role: "AXWindow", children: [selfTile] + controls))
  }

  @Test("Teams: the microphone-button gives both states")
  func teamsStates() {
    #expect(
      CallSelfMuteReader.read(
        surface: .teamsApp, capture: capture(windows: [teamsWindow([teamsButton("Unmute mic")])]), rules: .testPackaged)
        == .muted)
    #expect(
      CallSelfMuteReader.read(
        surface: .teamsApp, capture: capture(windows: [teamsWindow([teamsButton("Mute mic")])]), rules: .testPackaged)
        == .unmuted)
  }

  @Test("Teams: the pre-join checkbox, an unknown label, two buttons or two meetings is unknown")
  func teamsUnknowns() {
    // Pre-join: a checkbox with the shortcut in its label, not the meeting button.
    let preJoin = CallAXNode(
      role: "AXCheckBox", title: "Unmute mic (⇧ ⌘ M)", value: "0", domIdentifier: nil)
    let cases: [CallAXCapture] = [
      capture(windows: [teamsWindow([preJoin])]),
      capture(windows: [teamsWindow([teamsButton("Stummschaltung aufheben")])]),
      capture(windows: [teamsWindow([teamsButton("Unmute mic", dom: "camera-button")])]),
      capture(windows: [teamsWindow([teamsButton("Unmute mic"), teamsButton("Unmute mic")])]),
      capture(windows: [
        teamsWindow([teamsButton("Unmute mic")], title: "Meeting with Sam"),
        teamsWindow([], title: "Meeting with Alex"),
      ]),
    ]
    for item in cases {
      #expect(CallSelfMuteReader.read(surface: .teamsApp, capture: item, rules: .testPackaged) == .unknown, "\(item)")
    }
    // The compact view of the same meeting is one meeting; its one button decides.
    let compact = capture(windows: [
      teamsWindow([], title: "Meeting with Sam"),
      teamsWindow([teamsButton("Mute mic")], title: "Meeting compact view | Meeting with Sam"),
    ])
    #expect(CallSelfMuteReader.read(surface: .teamsApp, capture: compact, rules: .testPackaged) == .unmuted)
  }

  @Test("Teams: the window holding the button is the meeting; other meetings or buttons are unknown")
  func teamsScope() {
    // Live shape (Teams timing run, 2026-10-31): a solo meeting with the camera off and the
    // roster closed shows the button and no tile, talker or roster row.
    let tileFree = CallAXWindow(
      title: "Meeting with Sam", root: CallAXNode(role: "AXWindow", children: [teamsButton("Unmute mic")]))
    #expect(CallSelfMuteReader.read(surface: .teamsApp, capture: capture(windows: [tileFree]), rules: .testPackaged) == .muted)
    // The home window's meeting-link rows (live labels) are no second meeting.
    let home = CallAXWindow(
      title: "Meet",
      root: CallAXNode(
        role: "AXWindow",
        children: [
          CallAXNode(role: "AXRow", title: "Meeting links"),
          CallAXNode(role: "AXRow", title: "Meeting link, Meeting with Sam, Created 13 hours ago"),
        ]))
    #expect(CallSelfMuteReader.read(surface: .teamsApp, capture: capture(windows: [tileFree, home]), rules: .testPackaged) == .muted)
    // The compact view alone holds the button: still the one meeting.
    let compact = CallAXWindow(
      title: "Meeting compact view | Meeting with Sam",
      root: CallAXNode(role: "AXWindow", children: [teamsButton("Mute mic")]))
    #expect(
      CallSelfMuteReader.read(
        surface: .teamsApp,
        capture: capture(windows: [teamsWindow([], title: "Meeting with Sam"), compact]), rules: .testPackaged) == .unmuted)
    // A button in another window (chat, calendar) is not the meeting's: alone it names no
    // meeting shown, and beside the meeting's own button the two cannot be told apart.
    let chat = CallAXWindow(
      title: "Chat | Microsoft Teams", root: CallAXNode(role: "AXWindow", children: [teamsButton("Unmute mic")]))
    let unknowns: [CallAXCapture] = [
      capture(windows: [teamsWindow([]), chat]),
      capture(windows: [teamsWindow([teamsButton("Unmute mic")]), chat]),
      // A second meeting's tiles beside a tile-free meeting with the button.
      capture(windows: [tileFree, teamsWindow([], title: "Meeting with Alex")]),
      // The button in a window with no title cannot be matched to a meeting.
      capture(windows: [CallAXWindow(title: nil, root: tileFree.root)]),
    ]
    for item in unknowns {
      #expect(CallSelfMuteReader.read(surface: .teamsApp, capture: item, rules: .testPackaged) == .unknown, "\(item)")
    }
  }

  // MARK: - Google Meet

  private func meetButton(_ label: String, role: String = "AXButton") -> CallAXNode {
    CallAXNode(role: role, title: label, description: label)
  }

  private func meetPage(_ controls: [CallAXNode], url: String = meetURL) -> CallAXDocument {
    CallAXDocument(url: url, root: CallAXNode(role: "AXWebArea", children: controls))
  }

  /// A browser window holding its own chrome and the pages, as the capture copies it.
  private func browser(_ pages: [CallAXDocument], chrome: [CallAXNode] = []) -> CallAXCapture {
    let window = CallAXWindow(
      title: "Meet - pwe-iofm-gdv",
      root: CallAXNode(role: "AXWindow", children: chrome + pages.map(\.root)))
    return capture(windows: [window], documents: pages)
  }

  @Test("Meet: the meeting page's microphone button gives both states")
  func meetStates() {
    #expect(
      CallSelfMuteReader.read(
        surface: .meet, capture: browser([meetPage([meetButton("Turn on microphone")])]), rules: .testPackaged)
        == .muted)
    #expect(
      CallSelfMuteReader.read(
        surface: .meet, capture: browser([meetPage([meetButton("Turn off microphone")])]), rules: .testPackaged)
        == .unmuted)
  }

  @Test("Meet: browser chrome, another page, the passing live text and two meetings never decide")
  func meetIsolation() {
    // A matching button in browser chrome or on a non-meeting page is not the meeting's.
    let chromeOnly = browser(
      [meetPage([])], chrome: [meetButton("Turn on microphone")])
    #expect(CallSelfMuteReader.read(surface: .meet, capture: chromeOnly, rules: .testPackaged) == .unknown)
    let elsewhere = browser([
      meetPage([meetButton("Turn off microphone")]),
      meetPage([meetButton("Turn on microphone")], url: "https://example.com/notes"),
    ])
    #expect(CallSelfMuteReader.read(surface: .meet, capture: elsewhere, rules: .testPackaged) == .unmuted)
    // The live-region sentence is not the button.
    let liveText = browser([
      meetPage([CallAXNode(role: "AXStaticText", value: "Your microphone is off.")])
    ])
    #expect(CallSelfMuteReader.read(surface: .meet, capture: liveText, rules: .testPackaged) == .unknown)
    // Two meeting pages, two buttons on one page, or a wrong role.
    let twoMeetings = browser([
      meetPage([meetButton("Turn on microphone")]),
      meetPage([meetButton("Turn on microphone")], url: Self.otherMeetURL),
    ])
    #expect(CallSelfMuteReader.read(surface: .meet, capture: twoMeetings, rules: .testPackaged) == .unknown)
    let twoButtons = browser([
      meetPage([meetButton("Turn on microphone"), meetButton("Turn on microphone")])
    ])
    #expect(CallSelfMuteReader.read(surface: .meet, capture: twoButtons, rules: .testPackaged) == .unknown)
    let wrongRole = browser([meetPage([meetButton("Turn on microphone", role: "AXStaticText")])])
    #expect(CallSelfMuteReader.read(surface: .meet, capture: wrongRole, rules: .testPackaged) == .unknown)
    // A title and description that disagree cannot be told apart.
    let torn = browser([
      meetPage([
        CallAXNode(
          role: "AXButton", title: "Turn on microphone", description: "Turn off microphone")
      ])
    ])
    #expect(CallSelfMuteReader.read(surface: .meet, capture: torn, rules: .testPackaged) == .unknown)
  }

  // MARK: - Every surface

  @Test("an incomplete copy is unknown on every supported surface")
  func incompleteCopies() {
    let zoom = [zoomWindow([zoomButton("Unmute my audio")])]
    let teams = [teamsWindow([teamsButton("Unmute mic")])]
    let meet = browser([meetPage([meetButton("Turn on microphone")])])
    for completeness in [CallCaptureContext.Completeness.truncated, .unreadable] {
      #expect(
        CallSelfMuteReader.read(
          surface: .zoomApp, capture: capture(windows: zoom, completeness: completeness), rules: .testPackaged)
          == .unknown)
      #expect(
        CallSelfMuteReader.read(
          surface: .teamsApp, capture: capture(windows: teams, completeness: completeness), rules: .testPackaged)
          == .unknown)
      let partial = capture(
        windows: meet.windows, documents: meet.documents, completeness: completeness)
      #expect(CallSelfMuteReader.read(surface: .meet, capture: partial, rules: .testPackaged) == .unknown)
    }
  }

  @Test("a surface this build does not follow is unknown, even with a matching button")
  func unsupportedSurfaces() {
    let supported: Set<CallSpeakerSurface> = [.zoomApp, .teamsApp, .meet]
    let everything = capture(
      windows: [
        zoomWindow([zoomButton("Unmute my audio")]), teamsWindow([teamsButton("Unmute mic")]),
      ],
      documents: [meetPage([meetButton("Turn on microphone")])])
    let others = CallSpeakerSurface.allCases.filter { !supported.contains($0) }
    #expect(others.count == CallSpeakerSurface.allCases.count - 3)
    for surface in others {
      #expect(
        CallSelfMuteReader.read(surface: surface, capture: everything, rules: .testPackaged) == .unknown, "\(surface)")
    }
  }

  @Test("empty rules, or rules without the surface, is unknown")
  func missingRules() throws {
    let zoom = capture(windows: [zoomWindow([zoomButton("Unmute my audio")])])
    #expect(CallSelfMuteReader.read(surface: .zoomApp, capture: zoom, rules: .empty) == .unknown)
    #expect(CallMuteRules.empty.protectedRoles.isEmpty)
    let meetOnly = try CallMuteRules(
      validating: Data(
        #"{"schema":1,"revision":1,"surfaces":{"meet":{"role":"AXButton","labels":{"Turn on microphone":"muted","Turn off microphone":"unmuted"}}}}"#
          .utf8))
    #expect(CallSelfMuteReader.read(surface: .zoomApp, capture: zoom, rules: meetOnly) == .unknown)
  }

  // MARK: - Rules file

  @Test("the packaged rules resolve through the app's own lookup and hold every surface")
  func packagedRules() throws {
    let url = try #require(CallMuteRules.bundledURL)
    let rules = try CallMuteRules(validating: Data(contentsOf: url))
    #expect(rules == .testPackaged)
    #expect(rules.revision >= 1)
    #expect(rules.protectedRoles == ["AXButton"])
    #expect(Set(rules.rules.keys) == [.zoomApp, .teamsApp, .meet])
    #expect(rules.rules[.zoomApp]?.identifier == "audio")
    #expect(rules.rules[.teamsApp]?.domIdentifier == "microphone-button")
    #expect(rules.rules[.meet]?.identifier == nil && rules.rules[.meet]?.domIdentifier == nil)
  }

  @Test("the hosted rules file is the bundled file, byte for byte, and validates")
  func hostedMatchesBundled() throws {
    let hosted = try Data(
      contentsOf: RepoRoot.url.appending(path: "website/public/meet/call-mute-rules.json"))
    let packaged = try Data(contentsOf: #require(CallMuteRules.bundledURL))
    #expect(hosted == packaged)
    #expect(try CallMuteRules(validating: hosted, origin: .downloaded).revision >= 1)
  }

  /// The same literal documents `website/scripts/check-call-mute-rules.mjs` checks, so the app's
  /// validator and the website's check agree on every one (#4013 reading resilience §3.5).
  @Test("every shared fixture is accepted or refused as the website check expects")
  func sharedFixtures() throws {
    let data = try Data(
      contentsOf: RepoRoot.url.appending(path: "website/scripts/call-mute-rules-fixtures.json"))
    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let fixtures = try #require(root["fixtures"] as? [[String: Any]])
    var accepted = 0
    var refused = 0
    for fixture in fixtures {
      let name = try #require(fixture["name"] as? String)
      let accept = try #require(fixture["accept"] as? Bool)
      // A `raw` fixture is exact JSON text: re-serializing would erase its number spelling.
      let document =
        if let raw = fixture["raw"] as? String {
          Data(raw.utf8)
        } else {
          try JSONSerialization.data(
            withJSONObject: try #require(fixture["document"]), options: [.fragmentsAllowed])
        }
      switch (accept, Result { try CallMuteRules(validating: document) }) {
      case (true, .success): accepted += 1
      case (false, .failure): refused += 1
      case (true, .failure(let error)):
        Issue.record("\(name): refused (\(error)) but the fixture says it is valid")
      case (false, .success):
        Issue.record("\(name): accepted but the fixture says it is invalid")
      }
    }
    #expect(accepted >= 5)
    #expect(refused >= 25)
  }

  @Test("a rules file that is broken or incomplete is refused")
  func invalidRules() {
    let labels = #""labels":{"Unmute mic":"muted","Mute mic":"unmuted"}"#
    let refused = [
      "not json",
      #"{"schema":1,"revision":0,"surfaces":{}}"#,
      #"{"schema":1,"revision":1,"surfaces":{"slack_app":{"role":"AXButton",\#(labels)}}}"#,
      #"{"schema":1,"revision":1,"surfaces":{"nonsense":{"role":"AXButton",\#(labels)}}}"#,
      #"{"schema":1,"revision":1,"surfaces":{"teams_app":{"role":"",\#(labels)}}}"#,
      #"{"schema":1,"revision":1,"surfaces":{"teams_app":{"role":"AXButton","identifier":"a","domIdentifier":"b",\#(labels)}}}"#,
      #"{"schema":1,"revision":1,"surfaces":{"teams_app":{"role":"AXButton","identifier":"",\#(labels)}}}"#,
      #"{"schema":1,"revision":1,"surfaces":{"teams_app":{"role":"AXButton","labels":{"Unmute mic":"muted"}}}}"#,
      #"{"schema":1,"revision":1,"surfaces":{"teams_app":{"role":"AXButton","labels":{"Unmute mic":"muted","Mute mic":"loud"}}}}"#,
      #"{"schema":1,"revision":1,"surfaces":{"teams_app":{"role":"AXButton","labels":{"":"muted","Mute mic":"unmuted"}}}}"#,
      // #4013 reading resilience §3.5: the schema gate, strict fields and roles.
      #"{"revision":1,"surfaces":{}}"#,
      #"{"schema":2,"revision":1,"surfaces":{}}"#,
      #"{"schema":"1","revision":1,"surfaces":{}}"#,
      #"{"schema":1,"revision":1.5,"surfaces":{}}"#,
      #"{"schema":1,"revision":1000000001,"surfaces":{}}"#,
      #"{"schema":1,"revision":1,"surfaces":{},"extra":true}"#,
      #"{"schema":1,"revision":1,"surfaces":{"teams_app":{"role":"AXButton","note":"x",\#(labels)}}}"#,
      #"{"schema":1,"revision":1,"surfaces":{"teams_app":{"role":"Button",\#(labels)}}}"#,
    ]
    for text in refused {
      #expect(throws: (any Error).self, "\(text)") {
        try CallMuteRules(validating: Data(text.utf8))
      }
    }
  }

  // MARK: - Through the real capture walker

  /// The Zoom audio button is its own descendant in the live tree; the walker copies it once,
  /// so the reader sees one button, not a loop or a duplicate.
  @Test("Zoom's self-containing audio button, copied by the walker, reads as one button")
  func zoomCycleThroughWalker() {
    let tree = CallSpeakerCaptureTests.Tree()
    tree.node(1, "AXWindow", children: [2])
    tree.texts[1] = [.identifier: "zm.meeting.window.main", .title: "Zoom Meeting"]
    tree.node(2, "AXButton", children: [2])
    tree.texts[2] = [.identifier: "audio", .description: "Unmute my audio"]
    let copy = walk(tree, policy: .zoomApp)
    #expect(copy.completeness == .complete)
    #expect(CallSelfMuteReader.read(surface: .zoomApp, capture: copy, rules: .testPackaged) == .muted)
  }

  /// Two different buttons whose elements hash alike are both copied, so the reader sees two
  /// controls and refuses to choose.
  @Test("two distinct buttons with equal hashes stay two and read as unknown")
  func equalHashButtons() {
    let tree = CallSpeakerCaptureTests.Tree()
    tree.node(1, "AXWindow", children: [4, 2, 3])
    tree.texts[1] = [.title: "Meeting with Sam"]
    // The self tile shows the window is the meeting.
    tree.node(4, "AXMenuItem")
    tree.texts[4] = [.title: "Myself video, Saurabh Vaish, Muted"]
    tree.node(2, "AXButton")
    tree.node(3, "AXButton")
    tree.texts[2] = [.domIdentifier: "microphone-button", .title: "Mute mic"]
    tree.texts[3] = [.domIdentifier: "microphone-button", .title: "Mute mic"]
    tree.hashes = [2: 7, 3: 7]
    let copy = walk(tree)
    #expect(copy.windows.first?.root.children.count == 3)
    #expect(CallSelfMuteReader.read(surface: .teamsApp, capture: copy, rules: .testPackaged) == .unknown)
    // One of them alone is read.
    tree.children[1] = [4, 2]
    #expect(CallSelfMuteReader.read(surface: .teamsApp, capture: walk(tree), rules: .testPackaged) == .unmuted)
  }

  private func walk(_ tree: CallSpeakerCaptureTests.Tree, policy: CallAXCapturePolicy = .standard)
    -> CallAXCapture
  {
    var host: UInt64 = 100
    return CallSpeakerCapture.capture(
      windows: [1], access: tree.access(), bounds: .standard, policy: policy,
      keepPage: { _ in true },
      hostTime: {
        host += 10
        return host
      })
  }
}
