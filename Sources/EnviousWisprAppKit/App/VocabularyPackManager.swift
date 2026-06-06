import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation
import Observation

/// Owns which vocabulary packs (#633 Phase 9) are enabled and feeds their terms
/// into the corrector lane. Single responsibility: enabled-pack state +
/// merge-and-rebroadcast. Read-only bundled data; not user-editable persistence
/// (that is `CustomWordsManager`). Enabled set persists in UserDefaults;
/// default OFF for every pack.
///
/// Wiring (`wireCustomWords`) sets `currentUserWords` and `rebroadcast`: the
/// corrector lane is always `currentUserWords + enabledPackTerms()`. Toggling a
/// pack or a user-word edit funnels through the same `rebroadcast` so the
/// propagator pushes a fresh generation and the step's lookup cache invalidates.
@MainActor
@Observable
final class VocabularyPackManager {
  private let store: VocabularyPackStore
  private let defaults: UserDefaults
  private static let defaultsKey = "vocabularyPacks.enabled.v1"

  /// Latest user/builtin words, kept so a pack toggle can re-merge without a
  /// custom-words round-trip. Set by the wiring helper.
  var currentUserWords: [CustomWord] = []
  /// Pushes `currentUserWords + enabledPackTerms()` through the propagator with
  /// a bumped generation. Installed by the wiring helper.
  @ObservationIgnored var rebroadcast: () -> Void = {}

  private(set) var enabled: Set<VocabularyPackID>

  init(store: VocabularyPackStore = VocabularyPackStore(), defaults: UserDefaults = .standard) {
    self.store = store
    self.defaults = defaults
    if let raw = defaults.array(forKey: Self.defaultsKey) as? [String] {
      self.enabled = Set(raw.compactMap(VocabularyPackID.init(rawValue:)))
    } else {
      self.enabled = []  // default OFF
    }
  }

  /// Packs that resolve in the bundle, in display order.
  var availablePackIDs: [VocabularyPackID] {
    let present = Set(store.availablePackIDs())
    return VocabularyPackID.allCases.filter { present.contains($0) }
  }

  func isEnabled(_ id: VocabularyPackID) -> Bool { enabled.contains(id) }

  /// Terms for all enabled packs (source: .pack).
  func enabledPackTerms() -> [CustomWord] { store.terms(for: enabled) }

  /// Toggle a pack, persist, and rebroadcast the merged corrector lane.
  func setEnabled(_ id: VocabularyPackID, _ on: Bool) {
    if on { enabled.insert(id) } else { enabled.remove(id) }
    defaults.set(enabled.map(\.rawValue).sorted(), forKey: Self.defaultsKey)
    rebroadcast()
  }

  // MARK: - UI metadata

  /// Number of correctable terms in a pack (for the Settings row).
  func termCount(_ id: VocabularyPackID) -> Int { store.load(id)?.terms.count ?? 0 }

  /// A few example "fix" canonicals for the Settings row blurb.
  func exampleCanonicals(_ id: VocabularyPackID, limit: Int = 3) -> [String] {
    guard let pack = store.load(id) else { return [] }
    return pack.terms.map(\.canonical).sorted().prefix(limit).map { $0 }
  }

  /// Every term in a pack — the correct word plus the spoken variants (aliases)
  /// it catches — sorted alphabetically by word (case-insensitive), for the
  /// pack-detail list. Fail-open: missing pack yields an empty list.
  func packTerms(_ id: VocabularyPackID) -> [CustomWord] {
    guard let pack = store.load(id) else { return [] }
    return pack.terms.sorted {
      $0.canonical.localizedCaseInsensitiveCompare($1.canonical) == .orderedAscending
    }
  }
}
