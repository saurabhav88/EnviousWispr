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

  /// Packs that resolve in the bundle, in display order. Resolved ONCE.
  ///
  /// This was a computed property doing one `Bundle.url(forResource:)` per
  /// pack, and it is read inside a SwiftUI `body`, so every render of the pack
  /// list paid a bundle lookup per pack. What is inside the app bundle cannot
  /// change while the app runs, so the answer is fixed at launch. At the five
  /// packs that ship today this was invisible; the founder intends 25 to 30,
  /// and this is the kind of cost that only ever grows.
  let availablePackIDs: [VocabularyPackID]

  /// The pack list row's two numbers, computed ONCE per pack.
  ///
  /// The row used to ask `termCount` and `exampleCanonicals` separately, and
  /// each call walked the pack — `exampleCanonicals` sorted every canonical in
  /// the pack in order to take three of them. Two questions per card, and
  /// `ViewThatFits` builds each card twice, so a 30-pack list asked 120 of
  /// them per render pass (grounded review, 2026-08-29). One value, built
  /// lazily on first display and kept.
  struct PackSummary: Equatable {
    let termCount: Int
    let examples: [String]
  }

  /// How many example canonicals a pack row shows.
  ///
  /// A CONSTANT, not a parameter, and that is the fix for a real defect rather
  /// than a style choice. This began as `summary(_:exampleLimit:)` carried over
  /// from the old `exampleCanonicals(_:limit:)`, while the memo below is keyed
  /// on the pack id ALONE — so the first caller's limit would have been baked
  /// in for the life of the process, and every later caller asking for a
  /// different count would have silently received the first one's answer
  /// (cloud review, PR #2505). No caller ever varied it; a defaulted parameter
  /// nobody varies is a parameter no test checks. Removing it deletes the
  /// class instead of keying the cache on a tuple to preserve a knob nothing
  /// turns.
  private static let exampleLimit = 3

  @ObservationIgnored private var summaries: [VocabularyPackID: PackSummary] = [:]

  /// Display rows per pack, memoized. Invalidated by `mutateOverride` — the
  /// only thing that can change them — so the detail screen's search box no
  /// longer rebuilds and re-sorts the whole pack on every keystroke.
  @ObservationIgnored private var wordDisplayCache:
    [VocabularyPackID: [VocabularyPackWordDisplay]] =
      [:]

  init(
    store: VocabularyPackStore = VocabularyPackStore(),
    overridesStore: VocabularyPackOverridesStore = VocabularyPackOverridesStore(),
    defaults: UserDefaults = .standard
  ) {
    self.store = store
    self.overridesStore = overridesStore
    self.defaults = defaults
    self.overrides = overridesStore.load()
    let present = Set(store.availablePackIDs())
    self.availablePackIDs = VocabularyPackID.allCases.filter { present.contains($0) }
    if let raw = defaults.array(forKey: Self.defaultsKey) as? [String] {
      self.enabled = Set(raw.compactMap(VocabularyPackID.init(rawValue:)))
    } else {
      self.enabled = []  // default OFF
    }
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

  /// The pack list row's count and examples, in ONE lookup, memoized.
  ///
  /// Not override-adjusted: this is the shipped pack size and shipped
  /// examples, shown before anyone has opened the pack to edit anything, so
  /// nothing a user does can invalidate it and it never needs clearing.
  func summary(_ id: VocabularyPackID) -> PackSummary {
    if let hit = summaries[id] { return hit }
    guard let pack = store.load(id) else {
      let empty = PackSummary(termCount: 0, examples: [])
      summaries[id] = empty
      return empty
    }
    let examples = pack.terms.map(\.canonical).sorted().prefix(Self.exampleLimit).map { $0 }
    let value = PackSummary(termCount: pack.terms.count, examples: examples)
    summaries[id] = value
    return value
  }

  /// Number of correctable terms in a pack. Kept as the narrow question some
  /// callers actually ask; it reads the same memoized summary rather than
  /// walking the pack again.
  func termCount(_ id: VocabularyPackID) -> Int { summary(id).termCount }

  // MARK: - Pack word overrides (#2495)

  /// Every word in a pack, with each one's effective (override-applied)
  /// state for the pack-detail screen: whether it's on, its effective
  /// aliases, and whether it differs from shipped. Includes DISABLED words
  /// (unlike `enabledPackTerms()`) — the detail screen is where a disabled
  /// word gets found again and restored. Sorted alphabetically, case-insensitive.
  /// Memoized. The detail screen reads this from inside `body`, and its search
  /// box filters the result, so before this every keystroke rebuilt every
  /// display row for the pack and re-sorted them. `mutateOverride` is the only
  /// thing that can change the answer and it clears this.
  func packWords(_ id: VocabularyPackID) -> [VocabularyPackWordDisplay] {
    if let hit = wordDisplayCache[id] { return hit }
    let built = buildPackWords(id)
    wordDisplayCache[id] = built
    return built
  }

  private func buildPackWords(_ id: VocabularyPackID) -> [VocabularyPackWordDisplay] {
    guard let pack = store.load(id) else { return [] }
    let packOverrides = overrides.packs[id.rawValue] ?? [:]
    return pack.terms.map { term in
      let override = packOverrides[Self.overrideKey(for: term.canonical)]
      let effectiveAliases = override?.aliases ?? term.aliases
      let isEnabled = override?.isEnabled ?? true
      // Sorted HERE, once, rather than in the row's body. `PackWordRow` had a
      // `sortedAliases` computed property, so every visible row re-ran a
      // localized sort of its aliases on every body evaluation, and a
      // localized compare is not cheap (grounded review, 2026-08-29).
      //
      // Into its OWN field. `aliases` keeps its stored order because
      // `setWordAliases` compares it against the shipped array to decide
      // whether an edit has returned to the default.
      let displayAliases = effectiveAliases.sorted {
        $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
      }
      return VocabularyPackWordDisplay(
        id: term.id,
        canonical: term.canonical,
        shippedAliases: term.aliases,
        aliases: effectiveAliases,
        displayAliases: displayAliases,
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
    // The display rows are derived from `overrides`, so they are stale the
    // instant it changes. Cleared for EVERY pack rather than just `id`: the
    // store's `update` returns the whole file as saved, which can carry a
    // concurrent writer's change to another pack, so clearing only this one
    // would leave that pack's rows wrong on screen. Rebuilding a pack costs
    // well under a millisecond, so the wider clear is the cheap side of the
    // trade as well as the correct one.
    wordDisplayCache.removeAll(keepingCapacity: true)
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
  /// The effective alias list, IN ITS STORED ORDER. This is the value the
  /// editor reads to build the next list, and `setWordAliases` decides whether
  /// an edit has returned to the shipped default by comparing against the
  /// shipped array — an ORDER-SENSITIVE comparison. Sorting this field would
  /// mean an add-then-remove round trip wrote back a reordered list that no
  /// longer equalled the shipped one, so the word would stay marked EDITED
  /// forever. Display order is a separate concern; see `displayAliases`.
  let aliases: [String]
  /// The same aliases, sorted for the chip row, computed ONCE here rather than
  /// in every row's body on every render.
  let displayAliases: [String]
  let isEnabled: Bool
  let isEdited: Bool
}
