import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprServices
@testable import EnviousWisprStorage
import EnviousWisprAppKitTestSupport

/// #3735: the Whisper engine slot was stored as `"whisperKit"` before the
/// transcribe.cpp swap and is stored as `"whisper"` after it. A user who
/// updates keeps the engine they chose and every History row they made.
/// Unknown values keep their old handling: settings fall back to the shipped
/// default, a History row fails decoding and is skipped.
@MainActor
@Suite("Whisper engine: old saved values still load (#3735)", .tags(.productOutcome))
struct WhisperBackendLegacyDecodeTests {

  @Test("raw values: both spellings are Whisper, anything else is unknown")
  func rawValueTable() {
    #expect(ASRBackendType(rawValue: "whisper") == .whisper)
    #expect(ASRBackendType(rawValue: "whisperKit") == .whisper)
    #expect(ASRBackendType(rawValue: "parakeet") == .parakeet)
    #expect(ASRBackendType(rawValue: "WhisperKit") == nil)
    #expect(ASRBackendType(rawValue: "turbo") == nil)
    #expect(ASRBackendType(rawValue: "") == nil)
    #expect(ASRBackendType.whisper.rawValue == "whisper")
    #expect(ASRBackendType.whisper.displayName == "Whisper")
  }

  @Test("a saved WhisperKit engine choice loads as Whisper and saves back as whisper")
  func settingsLegacyValue() {
    let suite = TestDefaults.suite("ew-3735-legacy-backend-\(UUID().uuidString)")!
    suite.set("whisperKit", forKey: "selectedBackend")
    let settings = SettingsManager(defaults: suite)
    #expect(settings.selectedBackend == .whisper)

    settings.selectedBackend = .parakeet
    settings.selectedBackend = .whisper
    #expect(suite.string(forKey: "selectedBackend") == "whisper")
    #expect(SettingsManager(defaults: suite).selectedBackend == .whisper)
  }

  @Test("an unknown saved engine falls back to the shipped default")
  func settingsUnknownValue() {
    let suite = TestDefaults.suite("ew-3735-unknown-backend-\(UUID().uuidString)")!
    suite.set("turbo", forKey: "selectedBackend")
    #expect(
      SettingsManager(defaults: suite).selectedBackend == SettingsDefaultValues.selectedBackend)
  }

  /// A complete row as the store writes it, with the engine field in each
  /// spelling, read back through the store's own loader.
  @Test("History: old and new rows load, an unknown engine row is skipped")
  func historyRowsThroughTheStore() async throws {
    let dir = TestTemporaryDirectory.url
      .appendingPathComponent("ew-3735-history-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = TranscriptStore(directory: dir)

    let template = Transcript(
      text: "hola mundo", polishedText: "Hola, mundo.", language: "es", duration: 2.5,
      processingTime: 0.4, backendType: .whisper, llmProvider: "appleIntelligence",
      llmModel: "foundation", metrics: ExecutionMetrics(asrLatencySeconds: 0.9, streamingMode: false))
    try store.save(template)
    let file = dir.appendingPathComponent("\(template.id.uuidString).json")
    let written = try String(contentsOf: file, encoding: .utf8)
    // Literal oracle: the store writes the new spelling.
    #expect(written.contains(#""backendType":"whisper""#))

    func writeVariant(backend: String) throws -> UUID {
      let id = UUID()
      let json =
        written
        .replacingOccurrences(of: template.id.uuidString, with: id.uuidString)
        .replacingOccurrences(
          of: #""backendType":"whisper""#, with: #""backendType":"\#(backend)""#)
      #expect(json.contains(#""backendType":"\#(backend)""#))
      try Data(json.utf8).write(to: dir.appendingPathComponent("\(id.uuidString).json"))
      return id
    }
    let legacyID = try writeVariant(backend: "whisperKit")
    let unknownID = try writeVariant(backend: "turbo")

    let loaded = try await store.loadAll()
    let byID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
    #expect(loaded.count == 2)
    #expect(byID[template.id]?.backendType == .whisper)
    let legacy = try #require(byID[legacyID])
    #expect(legacy.backendType == .whisper)
    #expect(legacy.text == "hola mundo")
    #expect(legacy.polishedText == "Hola, mundo.")
    #expect(legacy.language == "es")
    #expect(byID[unknownID] == nil)
  }
}
