import EnviousWisprCore
import Foundation

@testable import EnviousWisprLLM

/// #4353 PR 5 (D7 detail, Stage 1 harness items 3 and 6): the weekly cloud model routine's
/// pure policy. It reads Chunk 1's complete catalogs (`LLMModelDiscovery.CloudCatalog`) and ONE
/// captured model list, and decides:
/// - which new models to test this week (`selectCandidates`), and
/// - what each listed model's absence history says (`observeAbsence`).
///
/// It sends nothing and spends nothing. "Selected" means "worth testing", never "affordable"
/// or "passed". Model-list lookups go through `LLMProvider.listedRow(model:list:)` and dated ids
/// through `ProviderModelID.withoutDateSnapshot`, unchanged, so this file is not a second
/// list or date authority.
enum CloudModelRoutinePolicy {

  static let candidateLimitPerProvider = 5

  // MARK: - Candidate selection (harness item 3)

  enum CandidateDisposition: String, Sendable, Equatable {
    /// The captured list already decides this id (exact row, dated copy of a row, or hidden row).
    case listed
    /// A dated copy whose exact base is also an eligible catalog id; the base is tested instead.
    case suppressedDatedCopy
    /// Chosen for this week's test, within the per-provider limit.
    case selected
    /// A new candidate past the per-provider limit; tried in a later week.
    case overLimit
  }

  struct Selection: Sendable, Equatable {
    let provider: LLMProvider
    /// At most `candidateLimitPerProvider`, in test order.
    let selected: [LLMModelDiscovery.DiscoveryCandidate]
    /// Every eligible id with what selection did with it, in catalog order.
    let dispositions: [String: CandidateDisposition]
  }

  /// The new models to test for one provider. `catalog.eligible` is Chunk 1's picker-equivalent
  /// population; ineligible ids never become candidates and never suppress one.
  static func selectCandidates(
    catalog: LLMModelDiscovery.CloudCatalog, list: CloudModelList?
  ) -> Selection {
    let provider = catalog.provider
    let eligibleIDs = Set(catalog.eligible.map(\.id))
    var dispositions: [String: CandidateDisposition] = [:]
    var pool: [LLMModelDiscovery.DiscoveryCandidate] = []
    for candidate in catalog.eligible {
      if provider.listedRow(model: candidate.id, list: list) != nil {
        dispositions[candidate.id] = .listed
      } else if let base = ProviderModelID.withoutDateSnapshot(candidate.id),
        eligibleIDs.contains(base)
      {
        dispositions[candidate.id] = .suppressedDatedCopy
      } else {
        pool.append(candidate)
      }
    }
    let ordered = pool.sorted(by: testOrder)
    let selected = Array(ordered.prefix(candidateLimitPerProvider))
    for candidate in selected { dispositions[candidate.id] = .selected }
    for candidate in ordered.dropFirst(candidateLimitPerProvider) {
      dispositions[candidate.id] = .overLimit
    }
    return Selection(provider: provider, selected: selected, dispositions: dispositions)
  }

  /// Provider-dated candidates newest first, then undated ones; id descending breaks ties.
  /// The date is the provider's own (`releaseDate`), never one inferred from the id.
  static func testOrder(
    _ a: LLMModelDiscovery.DiscoveryCandidate, _ b: LLMModelDiscovery.DiscoveryCandidate
  ) -> Bool {
    switch (a.releaseDate, b.releaseDate) {
    case let (x?, y?) where x != y: return x > y
    case (.some, .none): return true
    case (.none, .some): return false
    default: return a.id > b.id
    }
  }

  // MARK: - Absence history (harness item 6)

  /// A week is the ISO 8601 week of the observation date in UTC (weeks start on Monday;
  /// week 1 holds the year's first Thursday), written `YYYY-Www`. Two observations in the same
  /// week are one weekly observation, however many runs or retries produced them.
  static func isoWeek(of date: Date) -> String {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
    return String(format: "%04d-W%02d", parts.yearForWeekOfYear ?? 0, parts.weekOfYear ?? 0)
  }

  static func utcDay(of date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  /// One run's view of a provider. A failed or incomplete catalog is `.failed`, never an empty
  /// `.complete`: it must not advance or clear any history.
  enum CatalogOutcome: Sendable {
    case complete(LLMModelDiscovery.CloudCatalog)
    case failed
  }

  struct HideProposal: Sendable, Equatable {
    let provider: LLMProvider
    let id: String
    let hidden: Bool
    let hiddenReason: String
  }

  enum RowAbsence: Sendable, Equatable {
    case present
    /// Missing from the routine key's catalog for `weeks` distinct weeks (1): not yet hidden.
    case missingForRoutineKey(firstMissingDay: String, weeks: Int)
    /// Missing for two distinct weekly observations with no successful sighting between.
    case hide(HideProposal)
    /// Was pending and is back; the pending history is cleared. A hidden row is never
    /// unhidden automatically.
    case reappeared
    /// The list already hides this row; absence is reported, nothing is proposed.
    case alreadyHidden(present: Bool)
  }

  enum ObservationResult: Sendable, Equatable {
    /// The catalog failed; history is unchanged for this provider.
    case discoveryFailed
    /// The observation's week is earlier than one already recorded for this provider; it is
    /// ignored so history never moves backward.
    case stale(observedWeek: String, latestWeek: String)
    case observed([String: RowAbsence])
  }

  /// Versioned, serializable absence history, keyed by provider and exact listed id.
  struct AbsenceHistory: Codable, Sendable, Equatable {
    static let currentVersion = 1

    struct Entry: Codable, Sendable, Equatable {
      let provider: String
      let id: String
      /// UTC day of the first absence in this pending run of absences.
      let firstMissingDay: String
      /// Distinct ISO weeks in which a successful catalog lacked this row, ascending.
      var weeks: [String]
    }

    var version: Int = currentVersion
    /// Latest successful observation per provider (raw value), to the second. An observation
    /// older than this is stale, even inside the same week, so a replay can never undo a newer
    /// sighting or absence. The weekly identity is always derived from it (`isoWeek(of:)`).
    var latestObservedAt: [String: Date] = [:]
    var entries: [Entry] = []

    enum DecodeError: Error, Equatable {
      case unsupportedVersion(Int)
      case malformed(String)
    }

    static func decode(_ data: Data) throws -> AbsenceHistory {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let history = try decoder.decode(AbsenceHistory.self, from: data)
      guard history.version == currentVersion else {
        throw DecodeError.unsupportedVersion(history.version)
      }
      try history.check()
      return history
    }

    func encoded() throws -> Data {
      try check()
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
      encoder.dateEncodingStrategy = .iso8601
      return try encoder.encode(self)
    }

    /// Refuses state that would otherwise be trusted wrongly: unknown providers, impossible
    /// days or weeks, unsorted or repeated weeks, duplicate entries, and evidence that does
    /// not fit its provider's latest observation (an entry with no observation, a first week
    /// that is not the first missing day's week, or anything later than the latest one).
    func check() throws {
      let cloud = Set([LLMProvider.openAI, .gemini, .claude].map(\.rawValue))
      for provider in latestObservedAt.keys where !cloud.contains(provider) {
        throw DecodeError.malformed("provider \(provider)")
      }
      var keys: Set<String> = []
      for entry in entries {
        guard cloud.contains(entry.provider) else {
          throw DecodeError.malformed("provider \(entry.provider)")
        }
        guard !entry.id.isEmpty, keys.insert("\(entry.provider)/\(entry.id)").inserted else {
          throw DecodeError.malformed("entry \(entry.provider)/\(entry.id)")
        }
        guard let latest = latestObservedAt[entry.provider] else {
          throw DecodeError.malformed("entry \(entry.provider)/\(entry.id) has no observation")
        }
        guard let firstDay = Self.day(entry.firstMissingDay),
          entry.firstMissingDay <= CloudModelRoutinePolicy.utcDay(of: latest)
        else { throw DecodeError.malformed("day \(entry.firstMissingDay)") }
        let latestWeek = CloudModelRoutinePolicy.isoWeek(of: latest)
        guard !entry.weeks.isEmpty, entry.weeks.allSatisfy(Self.isWeek),
          entry.weeks == Array(Set(entry.weeks)).sorted(),
          entry.weeks.first == CloudModelRoutinePolicy.isoWeek(of: firstDay),
          entry.weeks.allSatisfy({ $0 <= latestWeek })
        else { throw DecodeError.malformed("weeks \(entry.weeks)") }
      }
    }

    /// A real ISO week: `YYYY-Www` that round-trips through the UTC ISO calendar, so week 53
    /// of a 52-week year and trailing text are refused.
    static func isWeek(_ text: String) -> Bool {
      guard text.range(of: #"^[0-9]{4}-W[0-9]{2}$"#, options: .regularExpression) != nil,
        let year = Int(text.prefix(4)), let week = Int(text.suffix(2))
      else { return false }
      var calendar = Calendar(identifier: .iso8601)
      calendar.timeZone = TimeZone(identifier: "UTC")!
      var parts = DateComponents()
      parts.yearForWeekOfYear = year
      parts.weekOfYear = week
      parts.weekday = 2
      guard let monday = calendar.date(from: parts) else { return false }
      return CloudModelRoutinePolicy.isoWeek(of: monday) == text
    }

    /// A real UTC Gregorian day, `YYYY-MM-DD`, in its canonical spelling; nil otherwise.
    static func day(_ text: String) -> Date? {
      guard text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil
      else { return nil }
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.calendar = Calendar(identifier: .gregorian)
      formatter.timeZone = TimeZone(identifier: "UTC")
      formatter.dateFormat = "yyyy-MM-dd"
      formatter.isLenient = false
      guard let date = formatter.date(from: text),
        CloudModelRoutinePolicy.utcDay(of: date) == text
      else { return nil }
      return date
    }
  }

  /// Apply one provider's observation to the history.
  ///
  /// - Presence reads the WHOLE fetched population (`identities`), before eligibility: an
  ///   excluded id is still present. A listed row is present only when its exact id is fetched.
  /// - Absence is `missingForRoutineKey`: what this key's catalog showed, not proof the
  ///   provider retired the model.
  /// - Two distinct ISO weeks of absence, with no successful sighting between them, propose
  ///   hiding. A failed run does not count and does not reset. A same-week rerun or replay adds
  ///   nothing (weeks are a set). An observation older than this provider's latest one, even in
  ///   the same week, is `stale` and changes nothing; replay evidence with its original time.
  /// - Rows already hidden by the list are reported, never proposed again, and drop out of the
  ///   pending history. Entries for rows the list no longer has are dropped.
  static func observeAbsence(
    history: AbsenceHistory, provider: LLMProvider, outcome: CatalogOutcome, observedAt: Date,
    list: CloudModelList
  ) -> (history: AbsenceHistory, result: ObservationResult) {
    guard case .complete(let catalog) = outcome, catalog.provider == provider else {
      return (history, .discoveryFailed)
    }
    // Whole seconds, so the stored value survives its ISO 8601 encoding unchanged.
    let observedAt = Date(timeIntervalSince1970: observedAt.timeIntervalSince1970.rounded(.down))
    let week = isoWeek(of: observedAt)
    let day = utcDay(of: observedAt)
    let key = provider.rawValue
    if let latest = history.latestObservedAt[key], observedAt < latest {
      return (history, .stale(observedWeek: week, latestWeek: isoWeek(of: latest)))
    }

    // Exact listed ids only: a dated copy in the catalog is a different model id and does not
    // show that the listed (undated) id is still offered. Dated resolution belongs to candidate
    // selection, not to absence.
    let present = Set(catalog.identities)

    var next = history
    next.latestObservedAt[key] = observedAt
    let rows = list.models.filter { $0.provider == provider }
    let listedIDs = Set(rows.map(\.id))
    var pending = Dictionary(
      uniqueKeysWithValues: history.entries.filter { $0.provider == key }.map { ($0.id, $0) })
    var results: [String: RowAbsence] = [:]

    for row in rows {
      let isPresent = present.contains(row.id)
      if row.hidden {
        pending[row.id] = nil
        results[row.id] = .alreadyHidden(present: isPresent)
        continue
      }
      if isPresent {
        results[row.id] = pending.removeValue(forKey: row.id) == nil ? .present : .reappeared
        continue
      }
      var entry =
        pending[row.id]
        ?? AbsenceHistory.Entry(provider: key, id: row.id, firstMissingDay: day, weeks: [])
      if !entry.weeks.contains(week) { entry.weeks = (entry.weeks + [week]).sorted() }
      pending[row.id] = entry
      if entry.weeks.count >= 2 {
        results[row.id] = .hide(
          HideProposal(
            provider: provider, id: row.id, hidden: true,
            hiddenReason: "Not in the provider's model list since \(entry.firstMissingDay)"))
      } else {
        results[row.id] = .missingForRoutineKey(
          firstMissingDay: entry.firstMissingDay, weeks: entry.weeks.count)
      }
    }

    let kept = pending.values.filter { listedIDs.contains($0.id) }
    next.entries =
      (history.entries.filter { $0.provider != key } + kept)
      .sorted { ($0.provider, $0.id) < ($1.provider, $1.id) }
    return (next, .observed(results))
  }
}
