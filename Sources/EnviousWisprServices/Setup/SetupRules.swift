import EnviousWisprCore
import Foundation

/// The ordered decision tables first-run Setup recommends from (#4528 plan §3.2), schema 1.
///
/// Data, not code: a new Mac memory tier, a threshold or a re-ranking of models the app already
/// ships is an edit to `setup-rules.json`. A new model identity also needs the app's compiled
/// inventories (`RegisteredModelInventoryTests` names any it lacks), so a rules file can never
/// introduce a download.
///
/// Each table is read top to bottom; the first row whose every condition holds wins; the last row
/// must have no conditions, so every table always answers.
public struct SetupRules: Sendable, Equatable {
  public let schema: Int
  /// Strictly increasing per published copy; a refresh only replaces rules with a higher revision.
  public let revision: Int
  /// A human date label ("2026.11.12"), reported in telemetry; not used for ordering.
  public let rulesVersion: String
  public let speechChoice: [Row]
  public let polishPrimary: [Row]
  public let polishNeighbour: [Row]
  /// Below this memory, the polish download waits for the speech download (mockup logic.js).
  public let parallelDownloadsMinMemoryGiB: Int

  public struct Row: Sendable, Equatable {
    public let when: Conditions
    public let pick: String
  }

  /// Every condition present must hold. An empty set of conditions always holds.
  public struct Conditions: Sendable, Equatable {
    public var memoryAtLeastGiB: Int?
    public var memoryBelowGiB: Int?
    /// True: dictation is locked to a language other than English (Auto counts as English).
    public var lockedNonEnglish: Bool?
    /// The speech language is in this engine's language set ("parakeet" or "whisper").
    public var languageIn: String?
    /// The polish primary pick (neighbour table only).
    public var primary: String?

    public var isCatchAll: Bool {
      memoryAtLeastGiB == nil && memoryBelowGiB == nil && lockedNonEnglish == nil
        && languageIn == nil && primary == nil
    }
  }

  /// The speech engines the app ships, by rule identifier.
  public static let registeredSpeech: [String: ASRBackendType] = [
    "parakeet": .parakeet, "whisper": .whisper,
  ]

  /// The local polish models the app ships, by rule identifier.
  public static let registeredPolish: [String: LocalPolishModelID] = [
    "eg1.full": .egOne(.full), "eg1.mini": .egOne(.mini), "eg1.micro": .egOne(.micro),
    "s1mini": .singleModel(for: .s1Mini),
    "appleIntelligence": .singleModel(for: .appleIntelligence),
  ]

  /// The models the two polish tables may pick: EG-1 sizes only. Apple Intelligence is placed on
  /// the cards by its availability, never by a table, and S1-mini is offered under See all (plan
  /// §3.2), so a table naming either could recommend an unavailable model or two Apple cards.
  public static let polishTablePicks: Set<String> = Set(
    registeredPolish.filter { $0.value.size != nil }.keys)

  /// Which conditions each table may use (#4528 B3). The polish answers are asked without speech
  /// language data (`SetupAdvice` polish helpers), so a polish row that read `languageIn` would make
  /// Setup and Settings disagree; `primary` only means something once the primary is chosen.
  ///   speech.choice:    languageIn, memoryAtLeastGiB, memoryBelowGiB, lockedNonEnglish
  ///   polish.primary:   memoryAtLeastGiB, memoryBelowGiB, lockedNonEnglish
  ///   polish.neighbour: memoryAtLeastGiB, memoryBelowGiB, lockedNonEnglish, primary
  static func disallowedConditions(_ c: Conditions, table: String) -> [String] {
    var used: [String] = []
    if c.languageIn != nil { used.append("languageIn") }
    if c.primary != nil { used.append("primary") }
    switch table {
    case "speech.choice": return used.filter { $0 == "primary" }
    case "polish.primary": return used
    default: return used.filter { $0 == "languageIn" }
    }
  }

  /// The language sets a `languageIn` condition may name.
  public static let languageSets: Set<String> = ["parakeet", "whisper"]

  public enum ValidationError: Error, Equatable, CustomStringConvertible {
    case notJSON
    case unsupportedSchema(Int)
    case unknownKey(String)
    case missingKey(String)
    case wrongType(String)
    case emptyTable(String)
    case noFinalCatchAll(String)
    case unregisteredPick(table: String, pick: String)
    case unknownLanguageSet(String)
    case nonPositiveRevision
    case notAnEGOneSize(table: String, pick: String)
    case conditionNotAllowed(table: String, condition: String)

    public var description: String {
      switch self {
      case .notJSON: "not a JSON object"
      case .unsupportedSchema(let s): "schema \(s) is not supported"
      case .unknownKey(let k): "unknown key \(k)"
      case .missingKey(let k): "missing key \(k)"
      case .wrongType(let k): "wrong type at \(k)"
      case .emptyTable(let t): "table \(t) has no rows"
      case .noFinalCatchAll(let t): "table \(t) does not end with a row that always applies"
      case .unregisteredPick(let t, let p): "table \(t) picks \(p), which this app does not ship"
      case .unknownLanguageSet(let s): "unknown language set \(s)"
      case .nonPositiveRevision: "revision must be a positive integer"
      case .notAnEGOneSize(let t, let p): "table \(t) picks \(p); the polish tables pick EG-1 sizes only"
      case .conditionNotAllowed(let t, let c): "table \(t) may not use the condition \(c)"
      }
    }
  }

  /// Decodes and validates one rules document. Unknown keys anywhere are refused, so a typo can
  /// never silently become "no condition".
  public static func validated(from data: Data) throws -> SetupRules {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      throw ValidationError.notJSON
    }
    try checkKeys(
      root,
      allowed: [
        "schema", "revision", "rulesVersion", "speech", "polish", "parallelDownloadsMinMemoryGiB",
      ], at: "")
    let schema = try int(root, "schema", at: "")
    guard schema == 1 else { throw ValidationError.unsupportedSchema(schema) }
    let revision = try int(root, "revision", at: "")
    guard revision > 0 else { throw ValidationError.nonPositiveRevision }
    guard let rulesVersion = root["rulesVersion"] as? String else {
      throw ValidationError.missingKey("rulesVersion")
    }
    let speech = try object(root, "speech", at: "")
    try checkKeys(speech, allowed: ["choice"], at: "speech.")
    let polish = try object(root, "polish", at: "")
    try checkKeys(polish, allowed: ["primary", "neighbour"], at: "polish.")
    let rules = SetupRules(
      schema: schema, revision: revision, rulesVersion: rulesVersion,
      speechChoice: try rows(speech, "choice", at: "speech."),
      polishPrimary: try rows(polish, "primary", at: "polish."),
      polishNeighbour: try rows(polish, "neighbour", at: "polish."),
      parallelDownloadsMinMemoryGiB: try int(root, "parallelDownloadsMinMemoryGiB", at: ""))
    try rules.checkTables()
    return rules
  }

  private func checkTables() throws {
    let tables: [(name: String, rows: [Row], registered: Set<String>, isPolish: Bool)] = [
      ("speech.choice", speechChoice, Set(Self.registeredSpeech.keys), false),
      ("polish.primary", polishPrimary, Set(Self.registeredPolish.keys), true),
      ("polish.neighbour", polishNeighbour, Set(Self.registeredPolish.keys), true),
    ]
    for table in tables {
      guard let last = table.rows.last else { throw ValidationError.emptyTable(table.name) }
      guard last.when.isCatchAll else { throw ValidationError.noFinalCatchAll(table.name) }
      for row in table.rows {
        if let condition = Self.disallowedConditions(row.when, table: table.name).first {
          throw ValidationError.conditionNotAllowed(table: table.name, condition: condition)
        }
        guard table.registered.contains(row.pick) else {
          throw ValidationError.unregisteredPick(table: table.name, pick: row.pick)
        }
        if table.isPolish, !Self.polishTablePicks.contains(row.pick) {
          throw ValidationError.notAnEGOneSize(table: table.name, pick: row.pick)
        }
        if let set = row.when.languageIn, !Self.languageSets.contains(set) {
          throw ValidationError.unknownLanguageSet(set)
        }
        if let primary = row.when.primary {
          guard Self.registeredPolish[primary] != nil else {
            throw ValidationError.unregisteredPick(table: table.name, pick: primary)
          }
          guard Self.polishTablePicks.contains(primary) else {
            throw ValidationError.notAnEGOneSize(table: table.name, pick: primary)
          }
        }
      }
    }
  }

  // MARK: Strict reading helpers

  private static func checkKeys(_ object: [String: Any], allowed: Set<String>, at path: String)
    throws
  {
    for key in object.keys where !allowed.contains(key) {
      throw ValidationError.unknownKey(path + key)
    }
  }

  private static func int(_ object: [String: Any], _ key: String, at path: String) throws -> Int {
    guard let value = object[key] else { throw ValidationError.missingKey(path + key) }
    // JSONSerialization hands booleans over as NSNumber too; refuse them as integers.
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      let int = Int(exactly: number.doubleValue)
    else { throw ValidationError.wrongType(path + key) }
    return int
  }

  private static func object(_ object: [String: Any], _ key: String, at path: String) throws
    -> [String: Any]
  {
    guard let value = object[key] else { throw ValidationError.missingKey(path + key) }
    guard let dict = value as? [String: Any] else { throw ValidationError.wrongType(path + key) }
    return dict
  }

  private static func rows(_ object: [String: Any], _ key: String, at path: String) throws -> [Row]
  {
    guard let value = object[key] else { throw ValidationError.missingKey(path + key) }
    guard let array = value as? [[String: Any]] else { throw ValidationError.wrongType(path + key) }
    return try array.enumerated().map { index, raw in
      let here = "\(path)\(key)[\(index)]."
      try checkKeys(raw, allowed: ["when", "pick"], at: here)
      guard let pick = raw["pick"] as? String else {
        throw ValidationError.missingKey(here + "pick")
      }
      guard let when = raw["when"] as? [String: Any] else {
        throw ValidationError.missingKey(here + "when")
      }
      try checkKeys(
        when,
        allowed: [
          "memoryAtLeastGiB", "memoryBelowGiB", "lockedNonEnglish", "languageIn", "primary",
        ], at: here + "when.")
      var conditions = Conditions()
      if when["memoryAtLeastGiB"] != nil {
        conditions.memoryAtLeastGiB = try int(when, "memoryAtLeastGiB", at: here + "when.")
      }
      if when["memoryBelowGiB"] != nil {
        conditions.memoryBelowGiB = try int(when, "memoryBelowGiB", at: here + "when.")
      }
      if let value = when["lockedNonEnglish"] {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
          throw ValidationError.wrongType(here + "when.lockedNonEnglish")
        }
        conditions.lockedNonEnglish = number.boolValue
      }
      if let value = when["languageIn"] {
        guard let set = value as? String else {
          throw ValidationError.wrongType(here + "when.languageIn")
        }
        conditions.languageIn = set
      }
      if let value = when["primary"] {
        guard let primary = value as? String else {
          throw ValidationError.wrongType(here + "when.primary")
        }
        conditions.primary = primary
      }
      return Row(when: conditions, pick: pick)
    }
  }

  // MARK: The rules the app ships

  /// The rules bundled with this build. Fails only if the bundled file is broken, which
  /// `SetupRulesTests` proves it is not on every test run.
  public static func bundled() throws -> SetupRules {
    guard let url = Bundle.module.url(forResource: "setup-rules", withExtension: "json") else {
      throw ValidationError.missingKey("setup-rules.json resource")
    }
    return try validated(from: Data(contentsOf: url))
  }
}

extension SetupRules {
  /// The last-resort rules when neither a cached nor the bundled copy validates (plan §9). A
  /// compiled copy of `setup-rules.json`, not a second policy: `SetupRulesTests` fails whenever the
  /// two differ, so editing one without the other cannot ship.
  public static let builtInJSON = #"""
{
  "schema": 1,
  "revision": 1,
  "rulesVersion": "2026.11.12",
  "speech": {
    "choice": [
      {"when": {"languageIn": "parakeet"}, "pick": "parakeet"},
      {"when": {}, "pick": "whisper"}
    ]
  },
  "polish": {
    "primary": [
      {"when": {"memoryAtLeastGiB": 32}, "pick": "eg1.full"},
      {"when": {"memoryAtLeastGiB": 16}, "pick": "eg1.mini"},
      {"when": {"lockedNonEnglish": true}, "pick": "eg1.mini"},
      {"when": {}, "pick": "eg1.micro"}
    ],
    "neighbour": [
      {"when": {"primary": "eg1.full"}, "pick": "eg1.mini"},
      {"when": {"primary": "eg1.micro"}, "pick": "eg1.mini"},
      {"when": {"primary": "eg1.mini", "memoryBelowGiB": 16}, "pick": "eg1.micro"},
      {"when": {}, "pick": "eg1.full"}
    ]
  },
  "parallelDownloadsMinMemoryGiB": 16
}
"""#

  /// The built-in rules, validated like any other copy.
  public static var builtIn: SetupRules {
    // swiftlint:disable:next force_try
    try! validated(from: Data(builtInJSON.utf8))
  }
}
