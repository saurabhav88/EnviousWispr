import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprLLM

/// #4353 D6: the cloud model list contract. The Swift parser and the publication validator
/// (`scripts/cloud-models/validate-list.py`) must give the same answer on every shared fixture,
/// and the seed must reproduce today's compiled per-model behavior row for row, so the later
/// cutover changes nothing for anyone.
@Suite("Cloud model list (#4353)", .tags(.productOutcome))
struct CloudModelListTests {
  private static let fixtures = RepoRoot.sourceURL("scripts/cloud-models/fixtures")
  private static let websiteSeed = RepoRoot.sourceURL("website/public/cloud-models.json")
  private static let bundledSeed = RepoRoot.sourceURL(
    "Sources/EnviousWispr/Resources/cloud-models.json")

  private static func files(_ kind: String) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: fixtures.appending(path: kind), includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private static func seed() throws -> CloudModelList {
    try CloudModelList.validated(from: Data(contentsOf: websiteSeed)).get()
  }

  // MARK: - The shared contract

  @Test("every shared valid fixture is accepted, every invalid one refused")
  func sharedFixtures() throws {
    let valid = try Self.files("valid")
    let invalid = try Self.files("invalid")
    #expect(valid.count >= 5 && invalid.count >= 50, "fixtures missing")
    for url in valid {
      let result = CloudModelList.validated(from: try Data(contentsOf: url))
      if case .failure(let error) = result {
        Issue.record("\(url.lastPathComponent) should pass, refused: \(error)")
      }
    }
    for url in invalid {
      if case .success = CloudModelList.validated(from: try Data(contentsOf: url)) {
        Issue.record("\(url.lastPathComponent) should be refused, passed")
      }
    }
  }

  @Test("document size and row count limits")
  func bounds() {
    var oversized = Data(#"{"schema":1,"updated":"2026-11-04","models":[]}"#.utf8)
    oversized.append(Data(repeating: 0x20, count: CloudModelList.maxDocumentBytes))
    #expect((try? CloudModelList.validated(from: oversized).get()) == nil)
    func rows(_ count: Int) -> Data {
      let row = { (n: Int) in
        #"{"provider":"claude","id":"claude-row-\#(n)","recommended":false,"hidden":false,"request":{"claudeShape":"thinkingDisabled"},"supportsChatCompletions":false,"allowsFileBatch":true}"#
      }
      let body = (0..<count).map(row).joined(separator: ",")
      return Data(#"{"schema":1,"updated":"2026-11-04","models":[\#(body)]}"#.utf8)
    }
    #expect(
      (try? CloudModelList.validated(from: rows(CloudModelList.maxRows)).get())?.models.count
        == CloudModelList.maxRows)
    #expect((try? CloudModelList.validated(from: rows(CloudModelList.maxRows + 1)).get()) == nil)
  }

  @Test("omit and none are different requests; a listed row never falls back")
  func explicitSemantics() throws {
    let data = Data(
      #"{"schema":1,"updated":"2026-11-04","models":[{"provider":"openAI","id":"gpt-a","recommended":false,"hidden":false,"request":{"openAIEffort":"none","temperature":"omit"},"supportsChatCompletions":true,"allowsFileBatch":false},{"provider":"openAI","id":"gpt-b","recommended":true,"hidden":true,"request":{"openAIEffort":"omit","temperature":"include"},"supportsChatCompletions":false,"allowsFileBatch":true},{"provider":"gemini","id":"gemini-a","recommended":false,"hidden":false,"request":{"geminiThinking":"none"},"supportsChatCompletions":false,"allowsFileBatch":true}]}"#
        .utf8)
    let list = try CloudModelList.validated(from: data).get()
    #expect(list.models[0].request == .openAI(effort: .none, temperature: .omit))
    #expect(list.models[1].request == .openAI(effort: .omit, temperature: .include))
    #expect(list.models[2].request == .gemini(thinking: .none))
    #expect(list.models[0].allowsFileBatch == false, "a listed false stays false")
    #expect(list.models[1].hidden && list.models[1].recommended, "hidden rows stay recognized")
  }

  @Test("revision is the updated date plus the SHA-256 of the exact bytes")
  func revision() throws {
    let compact = Data(#"{"schema":1,"updated":"2026-11-04","models":[]}"#.utf8)
    let spaced = Data(#"{"schema": 1, "updated": "2026-11-04", "models": []}"#.utf8)
    let a = try CloudModelList.validated(from: compact).get()
    let b = try CloudModelList.validated(from: spaced).get()
    #expect(a.revision.hasPrefix("2026-11-04-"))
    #expect(a.revision.count == "2026-11-04-".count + 64)
    #expect(a.revision != b.revision, "formatting changes the revision, as accepted")
    #expect(a.documentBytes == compact)
  }

  // MARK: - The seed

  @Test("both seed copies are byte-identical and valid")
  func seedCopies() throws {
    let website = try Data(contentsOf: Self.websiteSeed)
    let bundled = try Data(contentsOf: Self.bundledSeed)
    #expect(website == bundled)
    let list = try Self.seed()
    #expect(list.models.count == 66)
    #expect(
      Dictionary(grouping: list.models, by: \.provider).mapValues(\.count)
        == [.openAI: 34, .gemini: 18, .claude: 14])
    #expect(
      list.models.allSatisfy { $0.released == nil && $0.medianPolishMs == nil },
      "the seed invents no dates and no measurements")
    #expect(list.models.allSatisfy { !$0.hidden }, "hiding stays with the compiled kind filters")
  }

  /// Today's compiled rules are the oracle: the seed must say exactly what they say for every
  /// listed id, so moving the reader to the list changes no request.
  @Test("every seed row's request policy equals today's compiled capabilities")
  func seedMatchesCompiledCapabilities() throws {
    for row in try Self.seed().models {
      let compiled = row.provider.modelCapabilities(model: row.id)
      switch row.request {
      case .openAI(let effort, let temperature):
        switch effort {
        case .omit: #expect(compiled.thinkingControl == .unsupported, "\(row.id)")
        case .none, .low, .minimal:
          #expect(compiled.thinkingControl == .effort(effort.rawValue), "\(row.id)")
        }
        #expect(compiled.temperaturePolicy == temperature, "\(row.id)")
        #expect(compiled.supportsChatCompletions == row.supportsChatCompletions, "\(row.id)")
      case .gemini(let thinking):
        switch thinking {
        case .none: #expect(compiled.thinkingControl == .unsupported, "\(row.id)")
        case .budget(let n): #expect(compiled.thinkingControl == .budget(n), "\(row.id)")
        case .level(let l): #expect(compiled.thinkingControl == .level(l), "\(row.id)")
        }
        #expect(compiled.temperaturePolicy == .include, "\(row.id)")
      case .claude(let shape):
        #expect(compiled.claudeRequestShape == shape, "\(row.id)")
      }
    }
  }

  @Test("the seed's batching, recommendation and telemetry match today's compiled rules")
  @MainActor
  func seedMatchesCompiledPresentation() throws {
    let rows = try Self.seed().models
    // #2905: GPT-4o mini and Haiku 4.5 keep ordinary requests (`LLMPolishStep.fileBatchMember`).
    let ordinaryOnly = Set(rows.filter { !$0.allowsFileBatch }.map(\.id))
    #expect(ordinaryOnly == ["gpt-4o-mini", "claude-haiku-4-5"])
    for row in rows {
      #expect(
        row.recommended == AIPolishModelClassifier.isRecommendedForCleanup(row.id),
        "\(row.id) recommended")
      #expect(
        SettingsProjection.model(provider: row.provider, id: row.id) == row.id,
        "\(row.id) is recognized by telemetry today")
    }
    let geminiIDs = Set(rows.filter { $0.provider == .gemini }.map(\.id))
    #expect(geminiIDs == SettingsProjection.geminiModelIDs)
  }
}
