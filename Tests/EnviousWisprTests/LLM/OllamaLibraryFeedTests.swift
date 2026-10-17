import Foundation
import Testing

@testable import EnviousWisprLLM

/// #2778: the COMMITTED feed file against the production parser.
///
/// When this fails the user sees a Download button for a model the app would otherwise
/// have refused, or (worse, silently) a row that the runtime parser drops so the weekly
/// addition never appears. Runtime parsing drops a bad row quietly by design; publication
/// must not. So the rule here is stricter than the app's: EVERY row in the committed file
/// must survive the production parser with the identity the file states.
///
/// `scripts/ci/classify-changes.sh` forces the Swift lane for a change to the feed file,
/// because a green build with this suite skipped is not parser evidence. The offline
/// append-only comparison (add-only, at most 3 additions, no retained row changed) needs
/// the PR base and lives in `scripts/ollama-library/validate-feed.py`, run by pr-check.yml.
@Suite("Ollama library feed, committed file (#2778)", .tags(.productOutcome))
struct OllamaLibraryFeedTests {

  private static let feedPath = "website/public/ollama-library.json"
  private static let fixturesPath = "scripts/ollama-library/name-fixtures.json"

  private func read(_ relativePath: String, sourceLocation: SourceLocation = #_sourceLocation)
    throws -> Data
  {
    try Data(contentsOf: RepoRoot.url.appending(path: relativePath))
  }

  @Test("every row in the committed feed survives the production parser with its stated identity")
  func committedFeedParses() throws {
    let data = try read(Self.feedPath)
    let raw = try #require(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
    let rawRows = try #require(raw["models"] as? [[String: Any]])
    let rawNames = rawRows.compactMap { $0["name"] as? String }

    let parsed = try OllamaLibraryFeedClient.parseFeed(data)

    #expect(parsed.dropped.isEmpty, "rows dropped by the production parser: \(parsed.dropped)")
    #expect(parsed.entries.count == rawRows.count)
    #expect(rawNames.count == rawRows.count)
    for (entry, row) in zip(parsed.entries, rawRows) {
      let name = try #require(row["name"] as? String)
      let displayName = try #require(row["displayName"] as? String)
      let parameterCount = try #require(row["parameterCount"] as? String)
      let size = try #require(row["sizeBytes"] as? NSNumber)

      #expect(entry.name == name)
      #expect(
        OllamaSetupService.canonicalModelName(entry.name)
          == OllamaSetupService.canonicalModelName(name))
      #expect(Array(entry.displayName.unicodeScalars) == Array(displayName.unicodeScalars))
      #expect(Array(entry.parameterCount.unicodeScalars) == Array(parameterCount.unicodeScalars))
      #expect(
        entry.downloadSize == OllamaLibraryFeedClient.downloadSizeText(bytes: size.int64Value))
      #expect(entry.isDownloaded == false)
      #expect(entry.isRemote == false)
    }
    // The file is add-only and capped; the cap is the publication limit, not the runtime one.
    #expect(rawRows.count <= 40)
  }

  @Test("the seed document (no models) is valid and contributes nothing")
  func seedDocumentIsValid() throws {
    let seed = Data(#"{"schema":1,"updated":"2026-10-16","models":[]}"#.utf8)
    let parsed = try OllamaLibraryFeedClient.parseFeed(seed)
    #expect(parsed.entries.isEmpty)
    #expect(parsed.dropped.isEmpty)
  }

  private struct NameFixtures: Decodable {
    let valid: [String]
    let invalid: [String]
  }

  private func row(name: String) throws -> Data {
    let row: [String: Any] = [
      "name": name, "displayName": "Fixture", "parameterCount": "7B", "sizeBytes": 4_500_000_000,
    ]
    return try #require(
      try? JSONSerialization.data(withJSONObject: [
        "schema": 1, "updated": "2026-10-16", "models": [row],
      ]))
  }

  /// The shared fixtures are the agreement test between this parser and the Python
  /// validator on NAMED cases. Agreement on examples is not proof the two are identical;
  /// the committed-file test above is the authority for what the app will actually show.
  @Test(
    "every name the Python validator accepts is accepted here, and every one it rejects is dropped")
  func sharedNameFixturesAgree() throws {
    let fixtures = try JSONDecoder().decode(NameFixtures.self, from: try read(Self.fixturesPath))
    #expect(fixtures.valid.isEmpty == false)
    #expect(fixtures.invalid.isEmpty == false)

    for name in fixtures.valid {
      let parsed = try OllamaLibraryFeedClient.parseFeed(try row(name: name))
      #expect(parsed.entries.map(\.name) == [name], "valid fixture \(name) was not accepted")
      #expect(parsed.dropped.isEmpty, "valid fixture \(name) dropped: \(parsed.dropped)")
    }
    for name in fixtures.invalid {
      let parsed = try OllamaLibraryFeedClient.parseFeed(try row(name: name))
      #expect(parsed.entries.isEmpty, "invalid fixture \(name) was accepted")
      #expect(parsed.dropped.count == 1)
    }
  }
}
