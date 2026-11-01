import EnviousWisprCore
import Foundation

/// Whether the user is muted in the call app, as its own mute button shows (#4248). `unknown` is
/// every case the button could not be read for certain, and never silences the microphone.
package enum CallSelfMute: String, Sendable, Equatable {
  case muted
  case unmuted
  case unknown
}

/// How each supported call surface shows the user's own mute button, from the bundled
/// `call-mute-rules.json` (#4248 plan §3.1). The labels are exactly the English ones read live on
/// 2026-10-30 (`docs/audits/2026-10-30-4248/live-ax-probes.md`): Zoom 7.1.9, Teams 26276.505 and
/// Google Meet in Chrome 156. Any other label, language included, reads as unknown.
package struct CallMuteRules: Sendable, Equatable {
  package enum State: String, Sendable, Decodable {
    case muted
    case unmuted
  }

  /// One surface's button: its role, the id that singles it out (when the app gives one), and
  /// the label each state shows. With no id, a button showing one of the labels is the control.
  package struct Rule: Sendable, Equatable, Decodable {
    package let role: String
    package let identifier: String?
    package let domIdentifier: String?
    package let labels: [String: State]

    /// Whether `node` is this surface's mute button.
    func selects(_ node: CallAXNode) -> Bool {
      guard node.role == role else { return false }
      if let identifier { return node.identifier == identifier }
      if let domIdentifier { return node.domIdentifier == domIdentifier }
      return !states(of: node).isEmpty
    }

    /// The states the button's title and description show. A text outside the table shows none.
    func states(of node: CallAXNode) -> Set<State> {
      Set([node.title, node.description].compactMap { $0.flatMap { labels[$0] } })
    }
  }

  package enum Invalid: Error, Equatable {
    case revision
    case surface(String)
    case rule(String)
  }

  /// The surfaces this build follows a mute button on, with the call family each belongs to.
  package static let families: [CallSpeakerSurface: CallAppFamily] = [
    .zoomApp: .zoom, .teamsApp: .teams, .meet: .googleMeet,
  ]

  package let revision: Int
  package let rules: [CallSpeakerSurface: Rule]

  private struct File: Decodable {
    let revision: Int
    let surfaces: [String: Rule]
  }

  /// Decodes and checks a rules file: a positive revision, only supported surfaces, and per
  /// rule a role, at most one id, and a label for each state.
  package init(validating data: Data) throws {
    let file = try JSONDecoder().decode(File.self, from: data)
    guard file.revision > 0 else { throw Invalid.revision }
    var rules: [CallSpeakerSurface: Rule] = [:]
    for (key, rule) in file.surfaces {
      guard let surface = CallSpeakerSurface(rawValue: key), Self.families[surface] != nil else {
        throw Invalid.surface(key)
      }
      guard !rule.role.isEmpty, rule.identifier == nil || rule.domIdentifier == nil,
        rule.identifier?.isEmpty != true, rule.domIdentifier?.isEmpty != true,
        Set(rule.labels.values) == [.muted, .unmuted], !rule.labels.keys.contains("")
      else { throw Invalid.rule(key) }
      rules[surface] = rule
    }
    self.revision = file.revision
    self.rules = rules
  }

  /// The packaged `call-mute-rules.json`, or `nil` if the resource bundle did not ship.
  package static var bundledURL: URL? {
    Bundle.module.url(forResource: "call-mute-rules", withExtension: "json")
  }

  /// The packaged rules, or `nil` when the file is missing or invalid: every reading is then
  /// unknown, so the microphone stays live.
  package static let bundled: CallMuteRules? = bundledURL.flatMap { url in
    (try? Data(contentsOf: url)).flatMap { try? CallMuteRules(validating: $0) }
  }
}

/// Reads the user's own mute state from one speaker capture (#4248 plan §3.1). Pure over the
/// copy: it never messages the app. Only a whole copy of one call, holding exactly one mute
/// button with a known label, gives `muted` or `unmuted`; anything else is `unknown`.
package enum CallSelfMuteReader {
  package static func read(
    surface: CallSpeakerSurface, capture: CallAXCapture,
    rules: CallMuteRules? = CallMuteRules.bundled
  ) -> CallSelfMute {
    guard let family = CallMuteRules.families[surface], let rule = rules?.rules[surface],
      capture.completeness == .complete,
      CallSpeakerSurfaceReader.scope(surface: surface, capture: capture, family: family)
        == .resolved
    else { return .unknown }
    // Where the button may be: the one Zoom meeting window, the one Meet page, or the Teams
    // windows of the one meeting the app shows (its main window and compact view, matched by
    // title). Browser chrome, other pages and other windows are never searched.
    let roots: [CallAXNode]
    switch surface {
    case .zoomApp:
      let meetings = capture.windows.filter(CallSpeakerSurfaceReader.isZoomMeeting)
      guard meetings.count == 1 else { return .unknown }
      roots = [meetings[0].root]
    case .teamsApp:
      // The meeting is the window holding the microphone button, not one showing a tile or
      // roster: a solo meeting with the camera off and the roster closed shows neither (Teams
      // timing run, 2026-10-31). The pre-join screen's control is a checkbox, never selected.
      // Windows with the button must belong to one meeting (its compact view matched by title),
      // and no window may show another meeting's tiles or roster.
      let prefix = TeamsAppSpeakerReader.compactViewPrefix
      var buttonTitles: Set<String> = []
      for window in capture.windows where window.root.allNodes.contains(where: rule.selects) {
        guard let title = window.title, !title.isEmpty else { return .unknown }
        buttonTitles.insert(title.hasPrefix(prefix) ? String(title.dropFirst(prefix.count)) : title)
      }
      guard buttonTitles.count == 1, let meeting = buttonTitles.first,
        let shown = TeamsAppSpeakerReader.meetingTitles(windows: capture.windows),
        shown.isSubset(of: [meeting])
      else { return .unknown }
      roots = capture.windows.filter { $0.title == meeting || $0.title == prefix + meeting }
        .map(\.root)
    case .meet:
      let pages = capture.documents.filter {
        $0.url.map { CallSpeakerSurfaceChoice.isMeetingPage($0, family: family) } ?? false
      }
      guard pages.count == 1 else { return .unknown }
      roots = [pages[0].root]
    default:
      return .unknown
    }
    // Two buttons are two controls even when their labels agree: which one is the user's
    // cannot be told, so neither is trusted.
    let candidates = roots.flatMap(\.allNodes).filter(rule.selects)
    guard candidates.count == 1 else { return .unknown }
    let states = rule.states(of: candidates[0])
    guard states.count == 1, let state = states.first else { return .unknown }
    return state == .muted ? .muted : .unmuted
  }
}
