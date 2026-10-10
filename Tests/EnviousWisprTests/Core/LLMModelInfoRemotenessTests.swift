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

  // MARK: - #3142: Apple Intelligence status

  /// A row cached before the status existed still decodes, and reads as a model name.
  @Test("a row without an Apple Intelligence status decodes, and its label is its name")
  func legacyRowWithoutStatusDecodes() throws {
    let legacy = encoded(
      #"{"id":"apple-intelligence","displayName":"Apple Intelligence (On-Device)","provider":"appleIntelligence","isAvailable":true,"isRemote":false}"#
    )
    let row = try JSONDecoder().decode(LLMModelInfo.self, from: legacy)
    #expect(row.appleIntelligenceStatus == nil)
    #expect(row.localizedDisplayName == "Apple Intelligence (On-Device)")
  }

  @Test("the status round-trips and every status has its English label")
  func statusRoundTripsAndLabels() throws {
    let english: [AppleIntelligenceModelStatus: String] = [
      .onDevice: "Apple Intelligence (On-Device)",
      .deviceNotSupported: "Apple Intelligence (Device Not Supported)",
      .notEnabled: "Apple Intelligence (Not Enabled in Settings)",
      .modelNotReady: "Apple Intelligence (Model Not Ready)",
      .unavailable: "Apple Intelligence (Unavailable)",
      .requiresMacOS26: "Apple Intelligence (Requires macOS 26+)",
    ]
    #expect(Set(english.keys) == Set(AppleIntelligenceModelStatus.allCases))
    for status in AppleIntelligenceModelStatus.allCases {
      #expect(status.displayName == english[status], "\(status)")
      let row = LLMModelInfo(
        id: "apple-intelligence", displayName: "stored", provider: .appleIntelligence,
        isAvailable: false, isRemote: false, appleIntelligenceStatus: status)
      let decoded = try JSONDecoder().decode(
        LLMModelInfo.self, from: try JSONEncoder().encode(row))
      #expect(decoded.appleIntelligenceStatus == status)
      #expect(decoded.localizedDisplayName == english[status])
      #expect(decoded.displayName == "stored", "the stored name is data and is not rewritten")
    }
  }
}
