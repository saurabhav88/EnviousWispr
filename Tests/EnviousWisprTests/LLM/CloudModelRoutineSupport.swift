import EnviousWisprCore
import Foundation

@testable import EnviousWisprLLM

/// #4353 PR 5 (D7 detail, Stage 1 harness item 3): the weekly cloud model routine's pure
/// policy. It reads Chunk 1's complete catalogs (`LLMModelDiscovery.CloudCatalog`) and ONE
/// captured model list, and decides which new models to test this week (`selectCandidates`).
/// The routine never hides or un-hides a listed model (founder decision 14): each user's menu
/// comes from their own key, so a retired model leaves it by itself.
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

  // MARK: - Days

  /// The UTC calendar day of `date`, written `YYYY-MM-DD`.
  static func utcDay(of date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }
}
