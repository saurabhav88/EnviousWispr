import CryptoKit
import EnviousWisprCore
import Foundation

/// #4353 D6: the cloud model list, `website/public/cloud-models.json` schema 1, validated.
///
/// The only way to get a value is `CloudModelList.validated(from:)`, which checks the WHOLE
/// document and returns a typed failure for anything it does not accept: a policy document is
/// never admitted in part, because a partial list would later be kept as the last good one.
/// The server is never trusted: every key is from a closed vocabulary, every value is typed and
/// bounded, and nothing in the document can name a request key, endpoint, header or behavior.
///
/// `scripts/cloud-models/validate-list.py` applies the same contract before publication; the
/// shared fixtures in `scripts/cloud-models/fixtures/` hold both to the same answers.
///
/// Semantics that the reader relies on:
/// - A listed row is COMPLETE: its request fields never fall back to the compiled rules in
///   `LLMModelCapabilities`. OpenAI `"omit"` sends no `reasoning_effort`; `"none"` sends the
///   value `none`. Gemini `"none"` sends no thinking field. Claude rows always name a shape.
/// - `temperature` is OpenAI-only; Gemini always sends it and Claude never does.
/// - `released` is optional. A row without it takes the provider's own date, then none; the
///   list never invents a date. `medianPolishMs` is optional and is only ever a measurement.
/// - `hidden` hides a row from the menu but keeps it recognized (capabilities, telemetry). The
///   list can never make a model kind that discovery excludes visible.
/// - Ids the list does not name keep the compiled family rules.
public struct CloudModelList: Sendable, Equatable {
  public let schema: Int
  /// `YYYY-MM-DD`, a real calendar date in 2000 to 2099.
  public let updated: String
  public let models: [Row]
  /// `updated` plus the SHA-256 of the exact validated document bytes. A formatting-only
  /// change makes a new revision, which is acceptable.
  public let revision: String
  /// The exact bytes this value was validated from, kept so a persisted copy is byte-for-byte
  /// the document that passed validation.
  public let documentBytes: Data

  public struct Row: Sendable, Equatable {
    public let provider: LLMProvider
    public let id: String
    public let released: String?
    public let recommended: Bool
    public let hidden: Bool
    public let hiddenReason: String?
    public let displayName: String?
    public let request: RequestPolicy
    public let supportsChatCompletions: Bool
    public let allowsFileBatch: Bool
    public let medianPolishMs: Int?
  }

  /// The closed request vocabulary, one case per provider so a field can never belong to the
  /// wrong provider.
  public enum RequestPolicy: Sendable, Equatable {
    case openAI(effort: OpenAIEffort, temperature: LLMModelCapabilities.TemperaturePolicy)
    case gemini(thinking: GeminiThinking)
    case claude(shape: LLMModelCapabilities.ClaudeRequestShape)
  }

  public enum OpenAIEffort: String, Sendable, Equatable, CaseIterable {
    /// Send `reasoning_effort: "none"`.
    case none
    case low
    case minimal
    /// Send no `reasoning_effort` key at all (a model that is not a reasoning model).
    case omit
  }

  public enum GeminiThinking: Sendable, Equatable {
    /// Send no thinking field.
    case none
    case budget(Int)
    case level(String)
  }

  /// Why a document was refused. The message is for logs and the validator, never shown.
  public struct ValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
  }

  // MARK: - Bounds (the Python validator states the same numbers)

  public static let supportedSchema = 1
  public static let maxDocumentBytes = 262_144
  public static let maxRows = 500
  public static let maxIDScalars = 100
  public static let maxDisplayNameScalars = 80
  public static let maxHiddenReasonScalars = 200
  public static let geminiBudgetRange = 0...32_768
  public static let medianPolishMsRange = 1...60_000
  public static let geminiLevels: Set<String> = ["minimal", "low", "medium", "high"]

  static let topLevelKeys: Set<String> = ["schema", "updated", "models"]
  static let rowKeys: Set<String> = [
    "provider", "id", "released", "recommended", "hidden", "hiddenReason", "displayName",
    "request", "supportsChatCompletions", "allowsFileBatch", "medianPolishMs",
  ]
  static let requiredRowKeys: Set<String> = [
    "provider", "id", "recommended", "hidden", "request", "supportsChatCompletions",
    "allowsFileBatch",
  ]
  static let providers: [String: LLMProvider] = [
    "openAI": .openAI, "gemini": .gemini, "claude": .claude,
  ]
  static let claudeShapes: [String: LLMModelCapabilities.ClaudeRequestShape] = [
    "thinkingDisabled": .thinkingDisabled, "thinkingBetweenTools": .thinkingBetweenTools,
    "effortLow": .effortLow,
  ]

  private init(
    schema: Int, updated: String, models: [Row], revision: String, documentBytes: Data
  ) {
    self.schema = schema
    self.updated = updated
    self.models = models
    self.revision = revision
    self.documentBytes = documentBytes
  }

  // MARK: - Validation

  /// The whole document, or the first reason it is refused.
  public static func validated(from data: Data) -> Result<CloudModelList, ValidationError> {
    do {
      return .success(try validate(data))
    } catch let error as ValidationError {
      return .failure(error)
    } catch {
      return .failure(ValidationError(message: "unreadable: \(error)"))
    }
  }

  private static func fail(_ message: String) -> ValidationError {
    ValidationError(message: message)
  }

  private static func validate(_ data: Data) throws -> CloudModelList {
    guard data.count <= maxDocumentBytes else {
      throw fail("document is \(data.count) bytes, over \(maxDocumentBytes)")
    }
    // One encoding: UTF-8 with no byte-order mark. `JSONSerialization` would otherwise guess
    // UTF-16 or UTF-32 from zero bytes; a raw NUL is never valid JSON text, so it is refused.
    guard data.starts(with: [0xEF, 0xBB, 0xBF]) == false, data.contains(0) == false,
      String(data: data, encoding: .utf8) != nil
    else { throw fail("document is not UTF-8 without a byte-order mark") }
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data, options: [])
    } catch {
      throw fail("not JSON")
    }
    guard let top = object as? [String: Any] else { throw fail("top level is not an object") }
    try closedKeys(top, allowed: topLevelKeys, required: topLevelKeys, at: "document")
    let schema = try integer(top["schema"], at: "schema")
    guard schema == supportedSchema else { throw fail("unsupported schema \(schema)") }
    let updated = try calendarDate(top["updated"], at: "updated")
    guard let rawModels = top["models"] as? [Any] else { throw fail("models is not an array") }
    guard rawModels.count <= maxRows else {
      throw fail("\(rawModels.count) rows, over \(maxRows)")
    }
    var seen = Set<String>()
    var rows: [Row] = []
    for (index, raw) in rawModels.enumerated() {
      let row = try validateRow(raw, at: "models[\(index)]")
      let identity = "\(row.provider.rawValue)/\(row.id)"
      guard seen.insert(identity).inserted else { throw fail("duplicate row \(identity)") }
      rows.append(row)
    }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return CloudModelList(
      schema: schema, updated: updated, models: rows, revision: "\(updated)-\(digest)",
      documentBytes: data)
  }

  private static func validateRow(_ raw: Any, at path: String) throws -> Row {
    guard let row = raw as? [String: Any] else { throw fail("\(path) is not an object") }
    try closedKeys(row, allowed: rowKeys, required: requiredRowKeys, at: path)
    guard let providerName = row["provider"] as? String, let provider = providers[providerName]
    else { throw fail("\(path).provider is not openAI, gemini or claude") }
    let id = try text(row["id"], at: "\(path).id", maxScalars: maxIDScalars)
    guard isValidID(id) else { throw fail("\(path).id \(id) is not a lowercase model id") }
    let released = try row["released"].map { try calendarDate($0, at: "\(path).released") }
    let recommended = try boolean(row["recommended"], at: "\(path).recommended")
    let hidden = try boolean(row["hidden"], at: "\(path).hidden")
    let hiddenReason = try row["hiddenReason"].map {
      try text($0, at: "\(path).hiddenReason", maxScalars: maxHiddenReasonScalars)
    }
    let displayName = try row["displayName"].map {
      try text($0, at: "\(path).displayName", maxScalars: maxDisplayNameScalars)
    }
    let supportsChat = try boolean(
      row["supportsChatCompletions"], at: "\(path).supportsChatCompletions")
    let allowsFileBatch = try boolean(row["allowsFileBatch"], at: "\(path).allowsFileBatch")
    let median = try row["medianPolishMs"].map { value -> Int in
      let number = try integer(value, at: "\(path).medianPolishMs")
      guard medianPolishMsRange.contains(number) else {
        throw fail("\(path).medianPolishMs \(number) is out of range")
      }
      return number
    }
    let request = try validateRequest(row["request"], provider: provider, at: "\(path).request")
    // Chat Completions eligibility is an OpenAI fact; the other providers never read it.
    if provider != .openAI, supportsChat {
      throw fail("\(path).supportsChatCompletions must be false for \(providerName)")
    }
    return Row(
      provider: provider, id: id, released: released, recommended: recommended, hidden: hidden,
      hiddenReason: hiddenReason, displayName: displayName, request: request,
      supportsChatCompletions: supportsChat, allowsFileBatch: allowsFileBatch,
      medianPolishMs: median)
  }

  private static func validateRequest(
    _ raw: Any?, provider: LLMProvider, at path: String
  ) throws -> RequestPolicy {
    guard let request = raw as? [String: Any] else { throw fail("\(path) is not an object") }
    switch provider {
    case .openAI:
      try closedKeys(
        request, allowed: ["openAIEffort", "temperature"],
        required: ["openAIEffort", "temperature"], at: path)
      guard let effortName = request["openAIEffort"] as? String,
        let effort = OpenAIEffort(rawValue: effortName)
      else { throw fail("\(path).openAIEffort is not none, low, minimal or omit") }
      guard let temperatureName = request["temperature"] as? String,
        let temperature = [
          "include": LLMModelCapabilities.TemperaturePolicy.include,
          "omit": .omit,
        ][temperatureName]
      else { throw fail("\(path).temperature is not include or omit") }
      // Effort and temperature are independent, as they are in `LLMModelCapabilities`.
      return .openAI(effort: effort, temperature: temperature)
    case .gemini:
      try closedKeys(request, allowed: ["geminiThinking"], required: ["geminiThinking"], at: path)
      return .gemini(
        thinking: try geminiThinking(request["geminiThinking"], at: "\(path).geminiThinking"))
    case .claude:
      try closedKeys(request, allowed: ["claudeShape"], required: ["claudeShape"], at: path)
      guard let shapeName = request["claudeShape"] as? String, let shape = claudeShapes[shapeName]
      else {
        throw fail("\(path).claudeShape is not thinkingDisabled, thinkingBetweenTools or effortLow")
      }
      return .claude(shape: shape)
    case .ollama, .appleIntelligence, .egOne, .s1Mini, .none:
      throw fail("\(path) belongs to a provider the list does not cover")
    }
  }

  private static func geminiThinking(_ raw: Any?, at path: String) throws -> GeminiThinking {
    if let name = raw as? String {
      guard name == "none" else { throw fail("\(path) string is not none") }
      return .none
    }
    guard let object = raw as? [String: Any], object.count == 1 else {
      throw fail("\(path) is not none, {\"budget\": n} or {\"level\": name}")
    }
    if object.keys.first == "budget" {
      let budget = try integer(object["budget"], at: "\(path).budget")
      guard geminiBudgetRange.contains(budget) else {
        throw fail("\(path).budget \(budget) is out of range")
      }
      return .budget(budget)
    }
    if object.keys.first == "level" {
      guard let level = object["level"] as? String, geminiLevels.contains(level) else {
        throw fail("\(path).level is not minimal, low, medium or high")
      }
      return .level(level)
    }
    throw fail("\(path) has an unknown key")
  }

  // MARK: - Typed readers

  private static func closedKeys(
    _ object: [String: Any], allowed: Set<String>, required: Set<String>, at path: String
  ) throws {
    if let unknown = Set(object.keys).subtracting(allowed).sorted().first {
      throw fail("\(path) has unknown key \(unknown)")
    }
    if let missing = required.subtracting(object.keys).sorted().first {
      throw fail("\(path) is missing \(missing)")
    }
  }

  /// A JSON boolean only: a number is never read as a boolean.
  private static func boolean(_ raw: Any?, at path: String) throws -> Bool {
    guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
      throw fail("\(path) is not a boolean")
    }
    return number.boolValue
  }

  /// A JSON integer only: a boolean, a fraction or a non-finite value is refused.
  private static func integer(_ raw: Any?, at path: String) throws -> Int {
    guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      !CFNumberIsFloatType(number), let value = Int(exactly: number.int64Value)
    else { throw fail("\(path) is not an integer") }
    return value
  }

  /// A string of printable text, counted in Unicode scalars, with no control or format
  /// characters or line breaks. The validator counts code points and refuses categories Cc,
  /// Cf, Zl and Zp, plus Cs for an escaped unpaired surrogate, which `JSONSerialization`
  /// refuses before this runs.
  private static func text(_ raw: Any?, at path: String, maxScalars: Int) throws -> String {
    guard let value = raw as? String, !value.isEmpty else { throw fail("\(path) is not text") }
    guard value.unicodeScalars.count <= maxScalars else {
      throw fail("\(path) is longer than \(maxScalars)")
    }
    for scalar in value.unicodeScalars {
      switch scalar.properties.generalCategory {
      case .control, .format, .lineSeparator, .paragraphSeparator:
        throw fail("\(path) has a control character or line break")
      default: continue
      }
    }
    return value
  }

  /// `YYYY-MM-DD`, a real Gregorian date in 2000 to 2099.
  private static func calendarDate(_ raw: Any?, at path: String) throws -> String {
    guard let value = raw as? String, value.utf8.count == 10,
      value.range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z"#, options: .regularExpression) != nil
    else { throw fail("\(path) is not YYYY-MM-DD") }
    let parts = value.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3, (2000...2099).contains(parts[0]) else {
      throw fail("\(path) is not a date from 2000 to 2099")
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let components = DateComponents(
      calendar: calendar, year: parts[0], month: parts[1], day: parts[2])
    guard components.isValidDate else { throw fail("\(path) is not a real date") }
    return value
  }

  /// Lowercase letters and digits first, then letters, digits, `.`, `_` or `-`.
  static func isValidID(_ id: String) -> Bool {
    // `\A` and `\z`: the whole string, never a match that stops before a final line end.
    id.range(of: #"\A[a-z0-9][a-z0-9._-]{0,99}\z"#, options: .regularExpression) != nil
  }
}
