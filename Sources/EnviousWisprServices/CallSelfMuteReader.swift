import EnviousWisprCore
import Foundation

/// Whether the user is muted in the call app, as its own mute button shows (#4248). `unknown` is
/// every case the button could not be read for certain, and never silences the microphone.
package enum CallSelfMute: String, Sendable, Equatable {
  case muted
  case unmuted
  case unknown
}

/// How each supported call surface shows the user's own mute button (#4248 plan §3.1), from the
/// bundled `call-mute-rules.json` or its newer download (`RemoteRules.mute`, #4013 reading
/// resilience §3.5). A recording freezes the rules in force at its start. The labels are exactly
/// the English ones read live on 2026-10-30 (`docs/audits/2026-10-30-4248/live-ax-probes.md`):
/// Zoom 7.1.9, Teams 26276.505 and Google Meet in Chrome 156. Any other label, language included,
/// reads as unknown.
///
/// The file is validated strictly, the same way `website/scripts/check-call-mute-rules.mjs`
/// checks the hosted copy against the shared fixtures: `schema` must be `supportedSchema`; a
/// positive `revision` at most `maximumRevision` orders downloads (a bad hosted file is corrected
/// by publishing a fixed one with a still higher revision); unknown fields are refused.
package struct CallMuteRules: RemoteRulesDocument {
  package enum State: String, Sendable {
    case muted
    case unmuted
  }

  /// One surface's button: its role, the id that singles it out (when the app gives one), and
  /// the label each state shows. With no id, a button showing one of the labels is the control.
  package struct Rule: Sendable, Equatable {
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
    case document
    case schema
    case revision
    case field(String)
    case surface(String)
    case rule(String)
  }

  /// The surfaces this build follows a mute button on, with the call family each belongs to.
  package static let families: [CallSpeakerSurface: CallAppFamily] = [
    .zoomApp: .zoom, .teamsApp: .teams, .meet: .googleMeet,
  ]

  package static let supportedSchema = 1
  package static let maximumRevision = 1_000_000_000
  /// An Accessibility role as Apple names them; the capture protects it (`protectedRoles`).
  static let rolePattern = #"^AX[A-Za-z]{1,40}$"#

  package static let endpoint = URL(
    string: "https://enviouswispr.com/meet/call-mute-rules.json")!
  package static let cacheFileName = "call-mute-rules.json"
  package static let attemptFileName = "call-mute-rules-attempt.json"
  /// The bundled file is under 1 KB; the cap leaves room for many more labels.
  package static let maximumBytes = 16 * 1024

  /// The packaged `call-mute-rules.json`, or `nil` if the resource bundle did not ship.
  package static var bundledURL: URL? {
    Bundle.module.url(forResource: "call-mute-rules", withExtension: "json")
  }

  /// No surface followed: every reading is unknown, so the microphone stays live.
  package static let empty = CallMuteRules(revision: 0, rules: [:], origin: .empty)

  package let revision: Int
  package let rules: [CallSpeakerSurface: Rule]
  package let origin: RemoteRulesOrigin

  /// The roles the rules select. A speaker capture keeps every read on them strict, so a
  /// downloaded role can never be read through a tolerated failure (#4013 reading resilience
  /// §3.1).
  package var protectedRoles: Set<String> { Set(rules.values.map(\.role)) }

  private init(revision: Int, rules: [CallSpeakerSurface: Rule], origin: RemoteRulesOrigin) {
    self.revision = revision
    self.rules = rules
    self.origin = origin
  }

  /// Decodes and checks a rules file: the supported schema, a positive revision, only supported
  /// surfaces, and per rule an Accessibility role, at most one non-empty id, and non-empty labels
  /// covering both states. Any other field is refused.
  package init(validating data: Data, origin: RemoteRulesOrigin = .bundled) throws {
    guard data.count <= Self.maximumBytes,
      let file = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw Invalid.document }
    if let extra = Set(file.keys).subtracting(["schema", "revision", "surfaces"]).first {
      throw Invalid.field(extra)
    }
    guard Self.integer(file["schema"]) == Self.supportedSchema else { throw Invalid.schema }
    guard let revision = Self.integer(file["revision"]), revision > 0,
      revision <= Self.maximumRevision
    else { throw Invalid.revision }
    guard let surfaces = file["surfaces"] as? [String: Any] else {
      throw Invalid.field("surfaces")
    }
    var rules: [CallSpeakerSurface: Rule] = [:]
    for (key, value) in surfaces {
      guard let surface = CallSpeakerSurface(rawValue: key), Self.families[surface] != nil else {
        throw Invalid.surface(key)
      }
      rules[surface] = try Self.rule(value, at: key)
    }
    self.init(revision: revision, rules: rules, origin: origin)
  }

  private static func rule(_ value: Any, at key: String) throws -> Rule {
    guard let entry = value as? [String: Any],
      Set(entry.keys).isSubset(of: ["role", "identifier", "domIdentifier", "labels"]),
      let role = entry["role"] as? String,
      role.range(of: rolePattern, options: .regularExpression) != nil,
      let labelTable = entry["labels"] as? [String: Any]
    else { throw Invalid.rule(key) }
    let identifier = try optionalText(entry["identifier"], at: key)
    let domIdentifier = try optionalText(entry["domIdentifier"], at: key)
    guard identifier == nil || domIdentifier == nil else { throw Invalid.rule(key) }
    var labels: [String: State] = [:]
    for (label, state) in labelTable {
      guard !label.isEmpty, let raw = state as? String, let state = State(rawValue: raw) else {
        throw Invalid.rule(key)
      }
      labels[label] = state
    }
    guard Set(labels.values) == [.muted, .unmuted] else { throw Invalid.rule(key) }
    return Rule(role: role, identifier: identifier, domIdentifier: domIdentifier, labels: labels)
  }

  /// Absent is `nil`; present must be a non-empty string.
  private static func optionalText(_ value: Any?, at key: String) throws -> String? {
    guard let value else { return nil }
    guard let text = value as? String, !text.isEmpty else { throw Invalid.rule(key) }
    return text
  }

  /// A JSON whole number, or `nil`. Like the website check (JavaScript reads every JSON number
  /// as a double), any spelling of a whole number counts (`1`, `1.0`, `1e0`); a fraction, a
  /// boolean or a value past 2^53 does not.
  private static func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
      return nil
    }
    let double = number.doubleValue
    guard double.isFinite, double.rounded() == double, abs(double) <= 9_007_199_254_740_992
    else { return nil }
    return Int(double)
  }
}

/// Reads the user's own mute state from one speaker capture (#4248 plan §3.1). Pure over the
/// copy: it never messages the app. Only a whole copy of one call, holding exactly one mute
/// button with a known label, gives `muted` or `unmuted`; anything else is `unknown`.
package enum CallSelfMuteReader {
  /// `rules` are the recording's frozen rules (`RemoteRules.mute`); `.empty` reads unknown.
  package static func read(
    surface: CallSpeakerSurface, capture: CallAXCapture, rules: CallMuteRules
  ) -> CallSelfMute {
    guard let family = CallMuteRules.families[surface], let rule = rules.rules[surface],
      capture.completeness == .complete,
      // #4350 chunk 2: built-in words until chunk 3 passes the recording's frozen labels.
      CallSpeakerSurfaceReader.scope(
        surface: surface, capture: capture, family: family, zoomLabels: .builtIn) == .resolved
    else { return .unknown }
    // Where the button may be: the one Zoom meeting window (never a window whose tiles the
    // reading borrows; with no meeting window the state is unknown, #4013 reading resilience
    // §3.2), the one Meet page, or the Teams windows of the one meeting the app shows (its main
    // window and compact view, matched by title). Browser chrome, other pages and other windows
    // are never searched.
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
