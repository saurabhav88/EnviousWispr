import CryptoKit
import Foundation
import Testing

@testable import EnviousWisprASR

/// #3338 C.3: `ParakeetPhraseSpeller` must give the exact ids NVIDIA's tokenizer gives, or refuse.
/// When these fail, a learned name is boosted with the wrong pieces (the nudge listens for a word the
/// user never taught) or a word is spelled from a substituted unknown piece.
///
/// Expected ids are independent of the code under test: 421 recovered pairs from the #2610 harness
/// (Hugging Face `tokenizers` on NVIDIA's tokenizer) plus 22 supplement cases regenerated 2026-10-02
/// with Hugging Face `tokenizers` 0.23.2 on the official file at revision 541d1f99
/// (`scripts/parakeet-speller-data.py oracle`).
@Suite("Parakeet phrase speller (#3338)", .tags(.productOutcome))
struct ParakeetPhraseSpellerTests {

  private static let repoRoot = URL(filePath: #filePath)
    .deletingLastPathComponent()  // EnviousWisprASRTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // repo root
  private static let resource = repoRoot.appending(
    path: "Sources/EnviousWisprASR/Resources/ParakeetSpeller/parakeet-v3-speller.json")
  private static let fixtures = repoRoot.appending(
    path: "Tests/EnviousWisprASRTests/Fixtures/ParakeetSpeller")

  private struct Pair: Decodable {
    let text: String
    let ids: [Int]
  }

  private struct Oracle: Decodable {
    struct Provenance: Decodable {
      let inputs_sha256: String
      let recovered_421: Recovered
      struct Recovered: Decodable { let sha256: String }
    }
    struct Replay: Decodable {
      let rows: Int
      let disagreements: [Pair]
    }
    struct Case: Decodable {
      let text: String
      let ids: [Int]
      let expected: String
    }
    let label: String
    let provenance: Provenance
    let recovered_replay: Replay
    let supplement: [Case]
  }

  private static func sha256(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
  }

  private static func speller() throws -> ParakeetPhraseSpeller {
    try ParakeetPhraseSpeller.load(resource: resource)
  }

  @Test("all 421 recovered pairs spell to exactly their recovered ids")
  func recoveredPairs() throws {
    let url = Self.fixtures.appending(path: "recovered-421.json")
    #expect(
      try Self.sha256(url) == "59854b9089d4e6c542b6e56059cdf8ead18c8c5b08a4783f97685e30626283bf")
    let pairs = try JSONDecoder().decode([Pair].self, from: Data(contentsOf: url))
    let speller = try Self.speller()
    var executed = 0
    var mismatches: [String] = []
    for pair in pairs {
      executed += 1
      if case .success(let ids) = speller.spell(pair.text), ids == pair.ids { continue }
      mismatches.append("\(pair.text): \(speller.spell(pair.text)) expected \(pair.ids)")
    }
    #expect(executed == 421)
    #expect(mismatches.isEmpty, "\(mismatches)")
  }

  @Test(
    "the 22 supplement cases: 20 spelled exactly, 2 refused where the official tokenizer gives the unknown id"
  )
  func supplementCases() throws {
    let oracleURL = Self.fixtures.appending(path: "oracle.json")
    let oracle = try JSONDecoder().decode(Oracle.self, from: Data(contentsOf: oracleURL))
    #expect(oracle.label == "supplement, regenerated 2026-10-02")
    #expect(
      oracle.provenance.inputs_sha256
        == (try Self.sha256(Self.fixtures.appending(path: "supplement-inputs.json"))))
    #expect(
      oracle.provenance.recovered_421.sha256
        == "59854b9089d4e6c542b6e56059cdf8ead18c8c5b08a4783f97685e30626283bf")
    #expect(oracle.recovered_replay.rows == 421)
    #expect(oracle.recovered_replay.disagreements.isEmpty)

    let speller = try Self.speller()
    var spelled = 0
    var refused = 0
    for item in oracle.supplement {
      let result = speller.spell(item.text)
      switch item.expected {
      case "spelled":
        #expect(result == .success(item.ids), "\(item.text)")
        if result == .success(item.ids) { spelled += 1 }
      case "refusal":
        #expect(item.ids.contains(0))
        if case .failure(.unknownPiece) = result {
          refused += 1
        } else {
          Issue.record("\(item.text) should be refused, got \(result)")
        }
      default:
        Issue.record("unknown expectation \(item.expected)")
      }
    }
    #expect(oracle.supplement.count == 22)
    #expect(spelled == 20)
    #expect(refused == 2)
  }

  @Test("case is kept, NFC and NFD accents spell the same, phrases spell word by word")
  func shapes() throws {
    let speller = try Self.speller()
    #expect(speller.spell("NASA") != speller.spell("nasa"))
    let nfd = "Dvor\u{030C}a\u{0301}k"
    #expect(Array(nfd.unicodeScalars) != Array("Dvořák".unicodeScalars))
    #expect(speller.spell(nfd) == .success([360, 528, 8004, 1716]))
    #expect(
      speller.spell("Ursula von der Leyen") == .success([517, 6832, 2867, 1473, 623, 1333, 3135]))
    // Multi-piece single word.
    #expect(speller.spell("Łukasz") == .success([7863, 8159, 1174, 3627]))
  }

  @Test("refuses instead of approximating")
  func refusals() throws {
    let speller = try Self.speller()
    #expect(speller.spell("AT&T") == .failure(.unknownPiece("&")))
    #expect(speller.spell("Σωκράτης") == .failure(.unknownPiece("ς")))
    // Compatibility characters: ligature, full-width, superscript, circled.
    for text in ["\u{FB01}le", "\u{FF26}ull", "x\u{00B2}", "\u{24B6}BC"] {
      #expect(speller.spell(text) == .failure(.compatibilityCharacters), "\(text)")
    }
    // Whitespace and controls.
    #expect(speller.spell("New\tYork") == .failure(.unsupportedCharacter("\t")))
    #expect(speller.spell("New\u{00A0}York") == .failure(.unsupportedCharacter("\u{00A0}")))
    #expect(speller.spell("Zo\u{200B}e") == .failure(.unsupportedCharacter("\u{200B}")))
    // The boundary mark itself (official tokenizer: "▁" -> [], "▁New" -> [2634], "New▁York" ->
    // [2634, 4722]); encodeExact would double it, so the speller refuses it.
    for text in ["\u{2581}", "\u{2581}New", "New\u{2581}York"] {
      #expect(speller.spell(text) == .failure(.unsupportedCharacter("\u{2581}")), "\(text)")
    }
    for text in ["", " New", "New ", "New  York"] {
      #expect(speller.spell(text) == .failure(.emptyWord), "\(text)")
    }
    #expect(speller.spell("<unk>").isFailure)
  }

  @Test("a missing, altered or malformed resource is refused")
  func resourceRefusals() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let missing = dir.appending(path: "absent.json")
    #expect(throws: ParakeetPhraseSpeller.LoadError.resourceMissing(missing)) {
      try ParakeetPhraseSpeller.load(resource: missing)
    }

    var altered = try Data(contentsOf: Self.resource)
    altered.append(0x0A)
    let alteredURL = dir.appending(path: "altered.json")
    try altered.write(to: alteredURL)
    #expect {
      try ParakeetPhraseSpeller.load(resource: alteredURL)
    } throws: { error in
      if case ParakeetPhraseSpeller.LoadError.digestMismatch = error { return true }
      return false
    }

    let malformed = dir.appending(path: "malformed.json")
    try Data("{}".utf8).write(to: malformed)
    #expect {
      try ParakeetPhraseSpeller.load(resource: malformed)
    } throws: { error in
      if case ParakeetPhraseSpeller.LoadError.digestMismatch = error { return true }
      return false
    }
  }
}

extension Result {
  fileprivate var isFailure: Bool {
    if case .failure = self { return true }
    return false
  }
}
