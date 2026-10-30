import Foundation

/// #2778: the Ollama "Download more models" list can grow without an app release.
///
/// A weekly routine proposes additions to `website/public/ollama-library.json`, served
/// at `https://enviouswispr.com/ollama-library.json`. This type is the ONLY place the
/// app understands that file: where it is fetched from, what shape it has, and which
/// rows the app is willing to show.
///
/// The app never trusts the server. Every row passes the production eligibility rules
/// below before it can become a Download button, because the name of a row is handed
/// to the local Ollama daemon as a pull target. The publication checks (CI and the
/// routine's validator) are a second, independent line; this parser is the one that
/// runs on the user's Mac.
///
/// Fetch safety (host allowlist, redirect rule, byte ceiling, no cookies, no
/// identifiers) is owned by `OllamaCloudCatalogClient` and reused here: this client
/// differs from it only by URL, host and parser.
package struct OllamaLibraryFeedClient: Sendable {

  package static let allowedHost = "enviouswispr.com"

  /// The live feed is far below this; the ceiling exists so a hostile or broken body
  /// is bounded before it is parsed.
  package static let maximumBytes = 1_048_576

  /// Bounds the RAW `models` array, counted before any row is validated.
  package static let maximumRows = 200

  /// `schema` value this build understands. A later schema is a different document.
  package static let supportedSchema = 1

  /// Smallest and largest download a feed row may claim, in decimal bytes.
  package static let minimumSizeBytes: Int64 = 50_000_000
  package static let maximumSizeBytes: Int64 = 200_000_000_000

  private static let endpoint = "https://enviouswispr.com/ollama-library.json"

  /// Whole-string pull-target shape: lowercase repository, optional tag. Matched
  /// against the entire string, so a trailing newline or space cannot ride along.
  private static let namePattern = "^[a-z0-9][a-z0-9._-]{0,63}(:[A-Za-z0-9._-]{1,64})?$"

  private let transport: OllamaCloudCatalogClient.Transport

  // An overload pair, not a default argument: see `OllamaCloudCatalogClient.init()`.
  package init() {
    #if DEBUG
      // Live UAT seam, compiled out of release builds: a developer build can answer the feed from
      // a local file instead of the network, so a deterministic test feed is never published to
      // production. Set with `defaults write com.enviouswispr.app.dev EWDevOllamaLibraryFeedFile <path>`.
      if let path = UserDefaults.standard.string(forKey: Self.devFeedFileKey), !path.isEmpty {
        self.transport = Self.fileTransport(path: path)
        return
      }
    #endif
    self.transport = OllamaCloudCatalogClient.liveTransport(allowedHost: Self.allowedHost)
  }

  #if DEBUG
    private static let devFeedFileKey = "EWDevOllamaLibraryFeedFile"

    private static func fileTransport(path: String) -> OllamaCloudCatalogClient.Transport {
      { request, maximumBytes in
        guard maximumBytes >= 0, maximumBytes < Int.max else {
          throw CloudCatalogError.invalidResponse
        }
        // Bound the READ, not just the result: a huge file must not be loaded before it is refused.
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw CloudCatalogError.responseTooLarge }
        guard let url = request.url,
          let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else { throw CloudCatalogError.invalidResponse }
        return (data, response)
      }
    }
  #endif

  package init(transport: @escaping OllamaCloudCatalogClient.Transport) {
    self.transport = transport
  }

  /// Why a row was left out. Runtime drops a bad row quietly; publication (CI and the
  /// routine) treats ANY dropped row as an error, so a bad row cannot merge silently.
  package enum DropReason: String, Error, Sendable, CaseIterable {
    case notAnObject
    case badName
    case caseVariantOfLatest
    case badDisplayName
    case badParameterCount
    case badSize
    case duplicate
    case shipped
    case hasVerdict
    case reservedName
  }

  package struct ParsedFeed: Sendable {
    package let entries: [OllamaModelCatalogEntry]
    package let dropped: [DropReason]
  }

  /// One bare GET. No body, no query, no header carrying any identifier.
  package func fetchEntries() async throws -> [OllamaModelCatalogEntry] {
    guard let url = URL(string: Self.endpoint) else { throw CloudCatalogError.invalidResponse }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 5

    // Transport errors (timeout, cancellation, offline) propagate untouched, so an
    // unreachable network is never mistaken for an empty feed.
    let (data, response) = try await transport(request, Self.maximumBytes)

    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw CloudCatalogError.invalidResponse
    }
    return try Self.parseFeed(data).entries
  }

  // MARK: - Pure policy (production code, driven directly by tests)

  /// Throws on an invalid DOCUMENT (cannot trust the answer); drops an individual
  /// bad ROW and reports why. An empty `models` array is a valid document: it is how
  /// the feed says "no additions", and a successful empty answer clears earlier rows.
  package nonisolated static func parseFeed(_ data: Data) throws -> ParsedFeed {
    let root = try? JSONSerialization.jsonObject(with: data)
    // A JSON boolean bridges to NSNumber and would read as schema 1, so it is refused first.
    guard let object = root as? [String: Any],
      let schemaNumber = object["schema"] as? NSNumber,
      CFGetTypeID(schemaNumber) != CFBooleanGetTypeID(),
      schemaNumber.intValue == supportedSchema, schemaNumber.doubleValue == Double(supportedSchema),
      let rows = object["models"] as? [Any],
      rows.count <= maximumRows
    else { throw CloudCatalogError.invalidResponse }

    let reservedCanonicalNames = Set(
      (OllamaSetupService.modelCatalog + OllamaSetupService.curatedPrivateCatalog).map {
        OllamaSetupService.canonicalModelName($0.name)
      })

    var seen = Set<String>()
    var entries: [OllamaModelCatalogEntry] = []
    var dropped: [DropReason] = []

    for value in rows {
      switch validate(value, reservedCanonicalNames: reservedCanonicalNames, seen: &seen) {
      case .success(let entry): entries.append(entry)
      case .failure(let reason): dropped.append(reason)
      }
    }
    return ParsedFeed(entries: entries, dropped: dropped)
  }

  /// The name rules alone: whether `name` may become a local pull target at all, before any
  /// feed-publication rule (shipped, measured, duplicate) is asked. The feed parser and the
  /// typed-name Download row in the Models sheet (#3836) both ask this, so there is one answer.
  /// Returns nil for an acceptable name. The input is taken exactly as given: no trimming, no
  /// lowercasing, because the tag is case-sensitive (`foo:Q4_K_M`).
  package nonisolated static func nameDropReason(_ name: String) -> DropReason? {
    guard
      name.range(of: namePattern, options: .regularExpression) == name.startIndex..<name.endIndex
    else { return .badName }

    // Only the lowercase `latest` alias is understood. `canonicalModelName` strips
    // exactly `:latest`, so `:LATEST` would otherwise survive as a different model.
    if let tag = name.split(separator: ":", maxSplits: 1).dropFirst().first,
      tag.lowercased() == "latest", tag != "latest"
    {
      return .caseVariantOfLatest
    }

    let lowered = name.lowercased()
    if OllamaSetupService.isS1MiniModel(name) || lowered.hasPrefix("hf.co/")
      || lowered.contains("cloud")
    {
      return .reservedName
    }
    return nil
  }

  private nonisolated static func validate(
    _ value: Any, reservedCanonicalNames: Set<String>, seen: inout Set<String>
  ) -> Result<OllamaModelCatalogEntry, DropReason> {
    guard let row = value as? [String: Any] else { return .failure(.notAnObject) }

    guard let name = row["name"] as? String else { return .failure(.badName) }
    if let reason = nameDropReason(name) { return .failure(reason) }

    guard let displayName = row["displayName"] as? String, isDisplayable(displayName, maxLength: 60)
    else { return .failure(.badDisplayName) }
    guard let parameterCount = row["parameterCount"] as? String,
      isDisplayable(parameterCount, maxLength: 12)
    else { return .failure(.badParameterCount) }

    // A JSON boolean is an NSNumber too; and a fractional number must not be
    // truncated into a plausible integer.
    guard let sizeNumber = row["sizeBytes"] as? NSNumber,
      CFGetTypeID(sizeNumber) != CFBooleanGetTypeID(),
      sizeNumber.doubleValue == Double(sizeNumber.int64Value),
      sizeNumber.int64Value >= minimumSizeBytes, sizeNumber.int64Value <= maximumSizeBytes
    else { return .failure(.badSize) }
    let sizeBytes = sizeNumber.int64Value

    let canonical = OllamaSetupService.canonicalModelName(name)
    if reservedCanonicalNames.contains(canonical) { return .failure(.shipped) }

    // Anything we already have a verdict for (measured but unshipped, or first party)
    // is not "untested", and the feed has no field that could carry a verdict.
    if OllamaModelVerdicts.verdict(for: name) != .notTested { return .failure(.hasVerdict) }

    guard seen.insert(canonical).inserted else { return .failure(.duplicate) }

    return .success(
      OllamaModelCatalogEntry(
        name: name, displayName: displayName, parameterCount: parameterCount,
        downloadSize: downloadSizeText(bytes: sizeBytes)))
  }

  /// Non-blank, bounded, and free of control, format (including bidirectional) and
  /// line or paragraph separator characters.
  private nonisolated static func isDisplayable(_ text: String, maxLength: Int) -> Bool {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= maxLength
    else { return false }
    return text.unicodeScalars.allSatisfy { scalar in
      switch scalar.properties.generalCategory {
      case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse,
        .unassigned:
        return false
      default:
        return true
      }
    }
  }

  /// Decimal units, the same convention as the shipped literals ("~7.5 GB", "~523 MB").
  /// One decimal for gigabytes, dropped when whole; whole megabytes below 1 GB.
  package nonisolated static func downloadSizeText(bytes: Int64) -> String {
    // 999.5 MB and above rounds to "1000 MB" in the megabyte branch, so it belongs to gigabytes.
    if bytes >= 999_500_000 {
      let tenths = (Double(bytes) / 100_000_000).rounded()
      if tenths.truncatingRemainder(dividingBy: 10) == 0 {
        return "~\(Int(tenths / 10)) GB"
      }
      return "~\(Int(tenths) / 10).\(Int(tenths) % 10) GB"
    }
    return "~\(Int((Double(bytes) / 1_000_000).rounded())) MB"
  }
}
