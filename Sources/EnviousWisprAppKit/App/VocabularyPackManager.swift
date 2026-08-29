import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation
import Observation

/// Owns which vocabulary packs (#633 Phase 9) are enabled and feeds their terms
/// into the corrector lane. Single responsibility: enabled-pack state +
/// per-word overrides (#2495) + merge-and-rebroadcast. Bundled pack DATA stays
/// read-only (`VocabularyPackStore`); what a person changes about one word
/// lives in `overridesStore`, never folded into `CustomWordsManager`, which
/// persists a different thing (the user's own words) under different rules.
/// Enabled set persists in UserDefaults; default OFF for every pack.
///
/// Wiring (`wireCustomWords`) sets `currentUserWords` and `rebroadcast`: the
/// corrector lane is always `currentUserWords + enabledPackTerms()`. Toggling a
/// pack, editing a pack word, or a user-word edit all funnel through the same
/// `rebroadcast` so the propagator pushes a fresh generation and the step's
/// lookup cache invalidates.
@MainActor
@Observable
final class VocabularyPackManager {
  private let store: VocabularyPackStore
  private let overridesStore: VocabularyPackOverridesStore
  private let defaults: UserDefaults
  private static let defaultsKey = "vocabularyPacks.enabled.v1"

  /// Latest user/builtin words, kept so a pack toggle can re-merge without a
  /// custom-words round-trip. Set by the wiring helper.
  var currentUserWords: [CustomWord] = []
  /// Pushes `currentUserWords + enabledPackTerms()` through the propagator with
  /// a bumped generation. Installed by the wiring helper.
  @ObservationIgnored var rebroadcast: () -> Void = {}

  private(set) var enabled: Set<VocabularyPackID>
  /// In-memory mirror of the overrides file, refreshed on every mutation so
  /// SwiftUI observation sees a change without re-reading disk on every render.
  private var overrides: VocabularyPackOverridesFile
  /// Set when a pack-word mutation's locked save failed (lock contention or a
  /// disk error) — the UI shows this rather than silently discarding the
  /// edit. Cleared by the next successful mutation.
  private(set) var persistenceError: String?

  init(
    store: VocabularyPackStore = VocabularyPackStore(),
    overridesStore: VocabularyPackOverridesStore = VocabularyPackOverridesStore(),
    defaults: UserDefaults = .standard
  ) {
    self.store = store
    self.overridesStore = overridesStore
    self.defaults = defaults
    self.overrides = overridesStore.load()
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

  /// Terms for all enabled packs, with every per-word override (#2495)
  /// applied: a disabled word is dropped entirely, an aliases override
  /// replaces the shipped aliases, and an untouched word passes through
  /// unchanged. This is the ONE place pack overrides reach the correction
  /// lane — `WordCorrector` never reads the overrides file itself.
  func enabledPackTerms() -> [CustomWord] {
    enabled.sorted { $0.rawValue < $1.rawValue }.flatMap { id -> [CustomWord] in
      guard let pack = store.load(id) else { return [] }
      let packOverrides = overrides.packs[id.rawValue] ?? [:]
      return pack.terms.compactMap { term in
        guard let override = packOverrides[Self.overrideKey(for: term.canonical)] else {
          return term
        }
        if override.isEnabled == false { return nil }
        guard let aliases = override.aliases else { return term }
        return CustomWord(
          id: term.id, canonical: term.canonical, aliases: aliases, category: term.category,
          priority: term.priority, forceReplace: term.forceReplace,
          caseSensitive: term.caseSensitive, source: term.source,
          frequencyUsed: term.frequencyUsed, lastUsed: term.lastUsed,
          minSimilarityOverride: term.minSimilarityOverride)
      }
    }
  }

  /// Toggle a pack, persist, and rebroadcast the merged corrector lane.
  func setEnabled(_ id: VocabularyPackID, _ on: Bool) {
    if on { enabled.insert(id) } else { enabled.remove(id) }
    defaults.set(enabled.map(\.rawValue).sorted(), forKey: Self.defaultsKey)
    rebroadcast()
  }

  // MARK: - UI metadata

  /// Number of correctable terms in a pack (for the Settings row). Not
  /// override-adjusted — this is the shipped pack size, shown before anyone
  /// has opened the pack to edit anything.
  func termCount(_ id: VocabularyPackID) -> Int { store.load(id)?.terms.count ?? 0 }

  /// A few example "fix" canonicals for the Settings row blurb.
  func exampleCanonicals(_ id: VocabularyPackID, limit: Int = 3) -> [String] {
    guard let pack = store.load(id) else { return [] }
    return pack.terms.map(\.canonical).sorted().prefix(limit).map { $0 }
  }

  // MARK: - Pack word overrides (#2495)

  /// Every word in a pack, with each one's effective (override-applied)
  /// state for the pack-detail screen: whether it's on, its effective
  /// aliases, and whether it differs from shipped. Includes DISABLED words
  /// (unlike `enabledPackTerms()`) — the detail screen is where a disabled
  /// word gets found again and restored. Sorted alphabetically, case-insensitive.
  func packWords(_ id: VocabularyPackID) -> [VocabularyPackWordDisplay] {
    guard let pack = store.load(id) else { return [] }
    let packOverrides = overrides.packs[id.rawValue] ?? [:]
    return pack.terms.map { term in
      let override = packOverrides[Self.overrideKey(for: term.canonical)]
      let effectiveAliases = override?.aliases ?? term.aliases
      let isEnabled = override?.isEnabled ?? true
      return VocabularyPackWordDisplay(
        id: term.id,
        canonical: term.canonical,
        shippedAliases: term.aliases,
        aliases: effectiveAliases,
        isEnabled: isEnabled,
        // Computed from the EFFECTIVE state, not from "does an override
        // record exist" — an aliases override that has drifted back to
        // equal the shipped list (added then removed again) must read as
        // unedited, and `mutateOverride` already clears that case at write
        // time, but this reads the same way even if it somehow didn't.
        isEdited: !isEnabled || effectiveAliases != term.aliases
      )
    }.sorted {
      $0.canonical.localizedCaseInsensitiveCompare($1.canonical) == .orderedAscending
    }
  }

  /// Turn one pack word on or off, independent of the whole pack's toggle.
  func setWordEnabled(_ id: VocabularyPackID, canonical: String, enabled isOn: Bool) {
    mutateOverride(id, canonical: canonical) { $0.isEnabled = isOn ? nil : false }
  }

  /// Replace a pack word's effective aliases with `aliases` — the complete
  /// list, not a delta, matching how the alias editor already works for the
  /// user's own words. Clears the override back to `nil` when `aliases`
  /// turns out to equal the shipped list (e.g. add then remove the same
  /// alias again), so the EDITED badge doesn't stick around for a no-op edit.
  func setWordAliases(_ id: VocabularyPackID, canonical: String, aliases: [String]) {
    let key = Self.overrideKey(for: canonical)
    guard
      let shippedAliases = store.load(id)?.terms.first(where: {
        Self.overrideKey(for: $0.canonical) == key
      })?.aliases
    else { return }
    mutateOverride(id, canonical: canonical) {
      $0.aliases = aliases == shippedAliases ? nil : aliases
    }
  }

  /// Put one pack word back to its shipped default — clears BOTH the
  /// enabled/disabled override and any alias edit, in one action, rather
  /// than requiring two separate "restores." A no-op (nothing was ever
  /// edited) skips the disk write entirely.
  func restoreWord(_ id: VocabularyPackID, canonical: String) {
    let key = Self.overrideKey(for: canonical)
    guard overrides.packs[id.rawValue]?[key] != nil else { return }
    mutateOverride(id, canonical: canonical) { $0 = VocabularyPackWordOverride() }
  }

  /// The one path every pack-word mutation takes: a locked load-transform-
  /// save transaction (`VocabularyPackOverridesStore.update(_:)`), never a
  /// save built from this instance's own possibly-stale `overrides` snapshot
  /// — another running EnviousWispr process (a second worktree's dev build,
  /// or dev alongside production) could have changed the file since this
  /// process last read it.
  private func mutateOverride(
    _ id: VocabularyPackID, canonical: String,
    _ transform: (inout VocabularyPackWordOverride) -> Void
  ) {
    let key = Self.overrideKey(for: canonical)
    guard
      let saved = overridesStore.update({ file in
        var packDict = file.packs[id.rawValue] ?? [:]
        let before = packDict
        var entry = packDict[key] ?? VocabularyPackWordOverride()
        transform(&entry)
        if entry.isEmpty {
          packDict.removeValue(forKey: key)
        } else {
          packDict[key] = entry
        }
        if packDict.isEmpty {
          file.packs.removeValue(forKey: id.rawValue)
        } else {
          file.packs[id.rawValue] = packDict
        }
        return packDict != before
      })
    else {
      persistenceError = "Couldn't save this pack change. Nothing was changed. Try again."
      return
    }
    overrides = saved
    persistenceError = nil
    rebroadcast()
  }

  private static func overrideKey(for canonical: String) -> String { canonical.lowercased() }
}

/// One pack word as the pack-detail screen shows it: shipped identity plus
/// whatever a person has changed about it (#2495).
struct VocabularyPackWordDisplay: Identifiable, Equatable {
  let id: UUID
  let canonical: String
  /// The pack's own aliases, before any override — needed so "Add alias" /
  /// "Remove alias" in the detail screen can build the next full list
  /// without re-reading the pack file.
  let shippedAliases: [String]
  let aliases: [String]
  let isEnabled: Bool
  let isEdited: Bool
}
