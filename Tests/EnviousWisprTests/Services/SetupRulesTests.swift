import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// #4528 B1: the Setup rules file is read strictly.
///
/// **Product Outcome.** When this fails, a broken or mistyped rules file could silently turn a
/// condition into "always", recommend a model the app cannot download, or leave a table with no
/// answer, and a new user would be steered wrong during Setup.
@Suite(.tags(.productOutcome))
struct SetupRulesTests {
  private static func validate(_ json: String) throws -> SetupRules {
    try SetupRules.validated(from: Data(json.utf8))
  }

  private static func edited(_ from: String, _ to: String) -> String {
    let out = SetupRules.builtInJSON.replacingOccurrences(of: from, with: to)
    precondition(out != SetupRules.builtInJSON, "fixture edit did not apply: \(from)")
    return out
  }

  @Test("the bundled rules decode and pass validation")
  func bundledRulesAreValid() throws {
    let rules = try SetupRules.bundled()
    #expect(rules.schema == 1 && rules.revision >= 1)
    #expect(rules.polishPrimary.count == 4)
    #expect(rules.speechChoice.count == 2)
  }

  /// The built-in fallback is a compiled copy of the bundled file, never a second policy.
  @Test("the built-in rules are byte-identical to the bundled file")
  func builtInMatchesBundled() throws {
    let url = RepoRoot.url.appending(path: "Sources/EnviousWisprServices/Resources/setup-rules.json")
    let bundled = try String(contentsOf: url, encoding: .utf8)
    #expect(
      bundled.trimmingCharacters(in: .whitespacesAndNewlines)
        == SetupRules.builtInJSON.trimmingCharacters(in: .whitespacesAndNewlines),
      "setup-rules.json and SetupRules.builtInJSON differ; edit both together")
    #expect(try SetupRules.bundled() == SetupRules.builtIn)
  }

  @Test("an unknown key anywhere is refused")
  func unknownKeysRefused() {
    #expect(
      throws: SetupRules.ValidationError.unknownKey("polish.primary[0].when.memoryAtleastGiB")
    ) {
      try Self.validate(Self.edited(#""memoryAtLeastGiB": 32"#, #""memoryAtleastGiB": 32"#))
    }
    #expect(throws: SetupRules.ValidationError.unknownKey("extra")) {
      try Self.validate(Self.edited(#""schema": 1,"#, #""schema": 1, "extra": 2,"#))
    }
  }

  @Test("a table that does not end with a row that always applies is refused")
  func finalCatchAllRequired() {
    #expect(throws: SetupRules.ValidationError.noFinalCatchAll("polish.primary")) {
      try Self.validate(
        Self.edited(
          #"{"when": {}, "pick": "eg1.micro"}"#,
          #"{"when": {"memoryAtLeastGiB": 8}, "pick": "eg1.micro"}"#))
    }
  }

  @Test("a pick the app does not ship is refused")
  func unregisteredPickRefused() {
    #expect(
      throws: SetupRules.ValidationError.unregisteredPick(table: "polish.primary", pick: "eg1.huge")
    ) {
      try Self.validate(Self.edited(#""pick": "eg1.full"}"#, #""pick": "eg1.huge"}"#))
    }
    #expect(
      throws: SetupRules.ValidationError.unregisteredPick(table: "speech.choice", pick: "kaldi")
    ) {
      try Self.validate(Self.edited(#""pick": "whisper"}"#, #""pick": "kaldi"}"#))
    }
  }

  @Test("an unknown language set is refused")
  func unknownLanguageSetRefused() {
    #expect(throws: SetupRules.ValidationError.unknownLanguageSet("vosk")) {
      try Self.validate(Self.edited(#""languageIn": "parakeet""#, #""languageIn": "vosk""#))
    }
  }

  @Test(
    "an unsupported schema, a non-positive revision and a boolean where a number belongs are refused"
  )
  func typesAndVersionsRefused() {
    #expect(throws: SetupRules.ValidationError.unsupportedSchema(2)) {
      try Self.validate(Self.edited(#""schema": 1"#, #""schema": 2"#))
    }
    #expect(throws: SetupRules.ValidationError.nonPositiveRevision) {
      try Self.validate(Self.edited(#""revision": 1"#, #""revision": 0"#))
    }
    #expect(throws: SetupRules.ValidationError.wrongType("polish.primary[0].when.memoryAtLeastGiB"))
    {
      try Self.validate(Self.edited(#""memoryAtLeastGiB": 32"#, #""memoryAtLeastGiB": true"#))
    }
    #expect(throws: SetupRules.ValidationError.notJSON) { try Self.validate("[1, 2]") }
  }

  /// Apple Intelligence reaches the cards only by its availability, and S1-mini only under See
  /// all; a polish table naming either could recommend an unavailable model or two Apple cards.
  @Test("the polish tables pick EG-1 sizes only")
  func polishTablesPickEGOneOnly() {
    #expect(throws: SetupRules.ValidationError.notAnEGOneSize(table: "polish.primary", pick: "appleIntelligence")) {
      try Self.validate(
        Self.edited(
          #"{"when": {"memoryAtLeastGiB": 16}, "pick": "eg1.mini"}"#,
          #"{"when": {"memoryAtLeastGiB": 16}, "pick": "appleIntelligence"}"#))
    }
    #expect(throws: SetupRules.ValidationError.notAnEGOneSize(table: "polish.neighbour", pick: "s1mini")) {
      try Self.validate(Self.edited(#""primary": "eg1.full""#, #""primary": "s1mini""#))
    }
  }

  /// The polish answers are asked without speech language data, and `primary` only exists once a
  /// primary is chosen: a row using either in the wrong table would make Setup and Settings disagree.
  @Test("each table uses only the conditions that mean something there")
  func conditionsPerTable() {
    #expect(throws: SetupRules.ValidationError.conditionNotAllowed(table: "polish.primary", condition: "languageIn")) {
      try Self.validate(
        Self.edited(
          #"{"when": {"memoryAtLeastGiB": 32}, "pick": "eg1.full"}"#,
          #"{"when": {"languageIn": "parakeet"}, "pick": "eg1.full"}"#))
    }
    #expect(throws: SetupRules.ValidationError.conditionNotAllowed(table: "polish.primary", condition: "primary")) {
      try Self.validate(
        Self.edited(
          #"{"when": {"memoryAtLeastGiB": 32}, "pick": "eg1.full"}"#,
          #"{"when": {"primary": "eg1.mini"}, "pick": "eg1.full"}"#))
    }
    #expect(throws: SetupRules.ValidationError.conditionNotAllowed(table: "speech.choice", condition: "primary")) {
      try Self.validate(Self.edited(#"{"when": {"languageIn": "parakeet"}, "pick": "parakeet"}"#, #"{"when": {"primary": "eg1.mini"}, "pick": "parakeet"}"#))
    }
    #expect(throws: SetupRules.ValidationError.conditionNotAllowed(table: "polish.neighbour", condition: "languageIn")) {
      try Self.validate(Self.edited(#"{"when": {"primary": "eg1.full"}, "pick": "eg1.mini"}"#, #"{"when": {"languageIn": "whisper"}, "pick": "eg1.mini"}"#))
    }
  }
}
