import Foundation
import Testing

@testable import EnviousWisprCore

/// #1914: `LLMModelInfo.isRemote` and, more importantly, what happens to the
/// caches written before the field existed.
///
/// The migration is the part worth testing. `LLMModelDiscoveryCoordinator`
/// persists arrays of this type to `UserDefaults` and reloads them with `try?`,
/// so a decode failure is silent by construction: the user sees an empty model
/// dropdown and nothing anywhere reports why. The two providers need opposite
/// answers, and BOTH directions are asserted here because getting either one
/// backwards is invisible until a real user opens the pane.
@Suite("LLMModelInfo remoteness and cache migration (#1914)")
struct LLMModelInfoRemotenessTests {

  private func encoded(_ json: String) -> Data { Data(json.utf8) }

  // MARK: - The premise the migration rests on

  /// The whole design of the hand-written `init(from:)` rests on this being
  /// true. If a future Swift version DID honour property defaults during
  /// synthesized decoding, the custom initializer would be unnecessary
  /// ceremony and this test is where that would surface.
  ///
  /// Measured rather than assumed (2026-08-04): a property default does not
  /// rescue a missing key, so a plain `isRemote: Bool = false` would have
  /// thrown for every provider, not just Ollama.
  @Test("a missing key is NOT rescued by a property default in synthesized decoding")
  func propertyDefaultDoesNotRescueSynthesizedDecoding() throws {
    struct Synthesized: Codable {
      let id: String
      var flag: Bool = false
    }
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(Synthesized.self, from: self.encoded(#"{"id":"a"}"#))
    }
  }

  // MARK: - Legacy cache: cloud must survive

  /// The load-bearing half. Cloud panes load the cache and do NOT auto-run
  /// discovery, so rejecting a legacy cloud row would leave a real user
  /// staring at an empty model list until they thought to press refresh.
  @Test("a pre-#1914 cloud row decodes, defaulting remoteness to false")
  func legacyCloudRowDecodes() throws {
    for provider in ["openAI", "gemini", "claude"] {
      let legacy = encoded(
        """
        [{"id":"m","displayName":"M","provider":"\(provider)","isAvailable":true}]
        """)
      let rows = try JSONDecoder().decode([LLMModelInfo].self, from: legacy)
      #expect(rows.count == 1, "\(provider) legacy cache must survive the field addition")
      #expect(rows[0].isRemote == false)
    }
  }

  // MARK: - Legacy cache: Ollama must fail closed

  /// The honest half. A legacy Ollama row cannot say where its model runs, and
  /// defaulting it to local would print "runs on this Mac" over a model that
  /// does not. The throw discards the cache; live discovery repopulates it on
  /// the same settings-open path.
  @Test("a pre-#1914 Ollama row is REJECTED rather than assumed local")
  func legacyOllamaRowFailsClosed() {
    let legacy = encoded(
      """
      [{"id":"llama3","displayName":"Llama3","provider":"ollama","isAvailable":true}]
      """)
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode([LLMModelInfo].self, from: legacy)
    }
  }

  /// One legacy row poisons the whole array, and that is intended: the cache is
  /// stored per provider, so an Ollama cache is all-Ollama rows and there is no
  /// partial state worth salvaging.
  @Test("one legacy Ollama row rejects the entire cached array")
  func oneLegacyRowRejectsTheArray() {
    let mixed = encoded(
      """
      [{"id":"a","displayName":"A","provider":"ollama","isAvailable":true,"isRemote":false},
       {"id":"b","displayName":"B","provider":"ollama","isAvailable":true}]
      """)
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode([LLMModelInfo].self, from: mixed)
    }
  }

  // MARK: - Current-shape round trip

  @Test("a current-shape Ollama row round-trips both values of remoteness")
  func currentShapeRoundTrips() throws {
    for value in [true, false] {
      let original = LLMModelInfo(
        id: "gpt-oss:120b-cloud", displayName: "Gpt Oss", provider: .ollama,
        isAvailable: true, isRemote: value)
      let data = try JSONEncoder().encode(original)
      let decoded = try JSONDecoder().decode(LLMModelInfo.self, from: data)
      #expect(decoded.isRemote == value)
      #expect(decoded.id == original.id)
      #expect(decoded.provider == original.provider)
      #expect(decoded.isAvailable == original.isAvailable)
    }
  }

  /// Encoding must actually emit the key, or every write would produce another
  /// legacy row and the Ollama cache would reject itself forever.
  @Test("encoding emits the remoteness key")
  func encodingEmitsTheKey() throws {
    let data = try JSONEncoder().encode(
      LLMModelInfo(
        id: "a", displayName: "A", provider: .ollama, isAvailable: true, isRemote: true))
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(json.contains("isRemote"))
  }
}
