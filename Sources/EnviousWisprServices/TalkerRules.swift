import EnviousWisprCore
import Foundation

/// The validated talker rules document (#4013 D3, chunk 5): the selector rule for each rules-driven
/// surface and the measured talking-indicator lag for each surface. The bundled
/// `talker-rules.json` and the copy served at `https://enviouswispr.com/meet/talker-rules.json` are
/// the same file and both decode only through `decode(_:)`.
///
/// Document shape (schema 1):
///
///     { "schema": 1, "revision": 1,
///       "lagMs": { "<surface>": <whole ms> },
///       "selectors": [ { "surface": "meet", "tileRole": "AXGroup", "tileClass": "token",
///                        "nameSource": "firstStaticText" | "ownLabel", "nameSuffix": " Unverified",
///                        "talkingClasses": ["token"], "participantListClass": "token",
///                        "verification": "verified" | "unverified" } ] }
///
/// `schema` is compatibility: a build reads only `supportedSchema`, and a hosted file must keep
/// that value while builds that read it are in use. `revision` orders documents of one schema:
/// the store never replaces rules with a lower revision. A surface with no selector entry is
/// unconfigured (reads nothing); a surface with no lag entry is unmeasured (never zero).
package struct TalkerRules: Sendable, Equatable {
  package static let supportedSchema = 1
  /// The approved size cap (#4013 R7). Checked before parsing, and by the download while it reads.
  package static let maximumBytes = 32 * 1024
  /// Measured lags are a few hundred milliseconds; anything beyond five seconds is a typo.
  package static let lagBoundMs = 5_000
  /// Revisions are small counters; the bound keeps both validators on exactly representable
  /// whole numbers (the website check reads JSON numbers as doubles).
  package static let maximumRevision = 1_000_000_000
  static let maximumTalkingClasses = 8

  package let schema: Int
  package let revision: Int
  package let selectors: [CallSpeakerSurface: SpeakerSelectorRule]
  package let lags: [CallSpeakerSurface: CallSpeakerLag]

  /// Native readers (Zoom app, Teams app, Zoom web) carry their own signal and take no selector;
  /// their lag still lives in this document.
  package static let selectorSurfaces: Set<CallSpeakerSurface> = Set(CallSpeakerSurface.allCases)
    .subtracting([.zoomApp, .teamsApp, .zoomWeb])

  /// The rule for `surface`; an unconfigured rule when the document has none.
  package func rule(for surface: CallSpeakerSurface) -> SpeakerSelectorRule {
    selectors[surface] ?? .unconfigured(surface)
  }

  /// The measured lag for `surface`, or `nil` when it was never measured.
  package func lag(for surface: CallSpeakerSurface) -> CallSpeakerLag? {
    lags[surface]
  }

  package enum DecodeError: Error, Equatable {
    case tooLarge
    case notUTF8
    case notJSON
    case unsupportedSchema
    /// A field is missing, has the wrong type, holds a value outside its vocabulary, or
    /// contradicts another field. The text names the place for logs and tests.
    case invalid(String)
  }

  /// Validates the whole document. Any defect rejects the document; nothing is coerced into a
  /// plausible rule and no single entry is dropped.
  package static func decode(_ data: Data) throws(DecodeError) -> TalkerRules {
    guard data.count <= maximumBytes else { throw .tooLarge }
    guard String(data: data, encoding: .utf8) != nil else { throw .notUTF8 }
    guard let root = try? JSONSerialization.jsonObject(with: data) else { throw .notJSON }
    guard let object = root as? [String: Any] else { throw .invalid("document is not an object") }
    try requireKeys(object, allowed: ["schema", "revision", "lagMs", "selectors"], at: "document")
    guard let schema = integer(object["schema"]) else { throw .invalid("schema") }
    guard schema == supportedSchema else { throw .unsupportedSchema }
    guard let revision = integer(object["revision"]), (0...maximumRevision).contains(revision) else {
      throw .invalid("revision")
    }

    guard let lagObject = object["lagMs"] as? [String: Any] else { throw .invalid("lagMs") }
    var lags: [CallSpeakerSurface: CallSpeakerLag] = [:]
    for (key, value) in lagObject {
      guard let surface = CallSpeakerSurface(rawValue: key) else {
        throw .invalid("lagMs.\(key): unknown surface")
      }
      // A range test, not `abs`: `abs(Int.min)` traps.
      guard let ms = integer(value), (-lagBoundMs...lagBoundMs).contains(ms) else {
        throw .invalid("lagMs.\(key)")
      }
      lags[surface] = CallSpeakerLag(milliseconds: ms)
    }

    guard let entries = object["selectors"] as? [Any] else { throw .invalid("selectors") }
    var selectors: [CallSpeakerSurface: SpeakerSelectorRule] = [:]
    for (index, entry) in entries.enumerated() {
      let rule = try selector(entry, at: "selectors[\(index)]")
      guard selectors[rule.surface] == nil else {
        throw .invalid("selectors[\(index)]: second entry for \(rule.surface.rawValue)")
      }
      selectors[rule.surface] = rule
    }
    return TalkerRules(schema: schema, revision: revision, selectors: selectors, lags: lags)
  }

  private static func selector(_ value: Any, at place: String) throws(DecodeError)
    -> SpeakerSelectorRule
  {
    guard let entry = value as? [String: Any] else { throw .invalid("\(place): not an object") }
    try requireKeys(
      entry,
      allowed: [
        "surface", "tileRole", "tileClass", "nameSource", "nameSuffix", "talkingClasses",
        "participantListClass", "verification",
      ], at: place)
    guard let surfaceText = entry["surface"] as? String,
      let surface = CallSpeakerSurface(rawValue: surfaceText)
    else { throw .invalid("\(place).surface") }
    guard selectorSurfaces.contains(surface) else {
      throw .invalid("\(place).surface: \(surfaceText) has a native reader")
    }
    let tileRole = try optionalString(entry["tileRole"], at: "\(place).tileRole")
    if let tileRole, tileRole.range(of: #"^AX[A-Za-z]{1,40}$"#, options: .regularExpression) == nil
    {
      throw .invalid("\(place).tileRole")
    }
    let tileClass = try optionalToken(entry["tileClass"], at: "\(place).tileClass")
    let listClass = try optionalToken(
      entry["participantListClass"], at: "\(place).participantListClass")

    let suffix = try optionalString(entry["nameSuffix"], at: "\(place).nameSuffix")
    let nameSource: TileNameSource
    switch entry["nameSource"] as? String {
    case "firstStaticText":
      guard suffix == nil else { throw .invalid("\(place).nameSuffix needs nameSource ownLabel") }
      nameSource = .firstStaticText
    case "ownLabel":
      if let suffix, suffix.isEmpty { throw .invalid("\(place).nameSuffix is empty") }
      nameSource = .ownLabel(removingSuffix: suffix)
    default:
      throw .invalid("\(place).nameSource")
    }

    guard let rawTalking = entry["talkingClasses"] as? [Any],
      rawTalking.count <= maximumTalkingClasses
    else { throw .invalid("\(place).talkingClasses") }
    var talking: [String] = []
    for value in rawTalking {
      guard let token = value as? String, isToken(token), !talking.contains(token) else {
        throw .invalid("\(place).talkingClasses")
      }
      talking.append(token)
    }

    let verification: TalkerRuleVerification
    switch entry["verification"] as? String {
    case "verified": verification = .verified
    case "unverified": verification = .unverified
    default: throw .invalid("\(place).verification")
    }

    // Combinations that cannot mean what they say.
    let hasTile = tileRole != nil || tileClass != nil
    if !talking.isEmpty && !hasTile {
      throw .invalid("\(place): talkingClasses without a tile selector")
    }
    if let tileClass, talking.contains(tileClass) {
      throw .invalid("\(place): a talking class equal to the tile class marks every tile talking")
    }
    if verification == .verified && talking.isEmpty {
      throw .invalid("\(place): verified without talkingClasses")
    }
    if SpeakerSelectorRule.rosterOnly.contains(surface)
      && (!talking.isEmpty || verification == .verified)
    {
      throw .invalid("\(place): \(surfaceText) is roster-only")
    }
    if case .ownLabel = nameSource, !hasTile {
      throw .invalid("\(place): ownLabel without a tile selector")
    }

    return SpeakerSelectorRule(
      surface: surface, tileRole: tileRole, tileClass: tileClass, nameSource: nameSource,
      talkingClasses: talking, participantListClass: listClass, verification: verification)
  }

  private static func requireKeys(_ object: [String: Any], allowed: Set<String>, at place: String)
    throws(DecodeError)
  {
    if let unknown = object.keys.sorted().first(where: { !allowed.contains($0) }) {
      throw .invalid("\(place): unknown field \(unknown)")
    }
  }

  /// A whole JSON number. A JSON boolean bridges to NSNumber and a fraction would truncate, so
  /// both are refused.
  private static func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      number.doubleValue == Double(number.intValue)
    else { return nil }
    return number.intValue
  }

  /// Absent is `nil`; present must be a string (JSON `null` is refused, so a field is either
  /// meaningful or left out).
  private static func optionalString(_ value: Any?, at place: String) throws(DecodeError) -> String?
  {
    guard let value else { return nil }
    guard let text = value as? String else { throw .invalid(place) }
    return text
  }

  private static func optionalToken(_ value: Any?, at place: String) throws(DecodeError) -> String?
  {
    guard let text = try optionalString(value, at: place) else { return nil }
    guard isToken(text) else { throw .invalid(place) }
    return text
  }

  /// One exact DOM class token: no spaces, no selector syntax.
  static func isToken(_ text: String) -> Bool {
    text.range(of: #"^[A-Za-z_-][A-Za-z0-9_-]{0,99}$"#, options: .regularExpression) != nil
  }
}

/// The rules in force at one moment, ready to freeze into a recording (#4013 r1 R7). A value: a
/// later refresh never changes a snapshot already handed out.
package struct TalkerRulesSnapshot: Sendable, Equatable {
  package enum Origin: String, Sendable, Equatable {
    /// The copy inside the app.
    case bundled
    /// The last good download, read from Application Support.
    case cached
    /// Downloaded in this run.
    case downloaded
    /// Neither the bundle nor the cache held valid rules: every surface is unconfigured.
    case empty
  }

  package let rules: TalkerRules
  /// The exact validated document text, so a later pass decodes the same rules.
  package let frozen: FrozenTalkerRules
  package let origin: Origin

  /// Validates `data` and keeps its exact text.
  package init(validating data: Data, origin: Origin) throws(TalkerRules.DecodeError) {
    let rules = try TalkerRules.decode(data)
    self.rules = rules
    self.frozen = FrozenTalkerRules(
      version: rules.schema, payload: String(decoding: data, as: UTF8.self))
    self.origin = origin
  }

  /// Every surface unconfigured and unmeasured.
  package static let empty = TalkerRulesSnapshot(
    rules: TalkerRules(schema: TalkerRules.supportedSchema, revision: 0, selectors: [:], lags: [:]),
    // The decoder test proves this text decodes to exactly these rules.
    frozen: FrozenTalkerRules(
      version: TalkerRules.supportedSchema,
      payload: #"{"schema":1,"revision":0,"lagMs":{},"selectors":[]}"#),
    origin: .empty)

  private init(rules: TalkerRules, frozen: FrozenTalkerRules, origin: Origin) {
    self.rules = rules
    self.frozen = frozen
    self.origin = origin
  }


  /// The rules a recording froze, for Transcribe again. `nil` when the envelope's version is not
  /// one this build reads, when the text no longer decodes, or when the two disagree; the caller
  /// then keeps fallback labels.
  package static func thaw(_ frozen: FrozenTalkerRules) -> TalkerRules? {
    guard frozen.version == TalkerRules.supportedSchema,
      let rules = try? TalkerRules.decode(Data(frozen.payload.utf8)),
      rules.schema == frozen.version
    else { return nil }
    return rules
  }
}
