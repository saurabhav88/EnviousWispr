import Foundation

/// A chosen Settings search result, resolved once from the Settings Map when it is chosen
/// (#3482 plan §3.1, §3.4). Immutable: the leave guard keeps the whole request while a question is
/// open, and "latest request wins" replaces it whole. Every field is the map node's own, so the
/// request is never a second metadata authority and the selected entry is never rebuilt from its
/// anchor, which several entries can share.
// periphery:ignore - navigation plumbing for the search UI (PR B, #3482); tests construct it now
struct SettingsSearchRequest: Equatable {
  /// The selected entry's stable map id.
  let entryID: String
  /// The page, and the Dictation or App tab, the entry lives on.
  let destination: SettingsDestination
  /// The Dictionary tab, for Dictionary entries; the other pages carry none.
  let dictionaryTab: DictionaryTab?
  /// The registered control an arrival points at: the entry's own row or card.
  let target: SettingsMapID
  /// Where an arrival goes, in order, when `target` is not on screen.
  let fallbacks: [SettingsMapID]

  /// The request for the searchable entry `entryID`, or nil when the id is not a map node, is not
  /// a searchable entry, or the node declares no destination or target. Never guesses a page.
  init?(entryID: String) {
    guard let id = SettingsMapID(rawValue: entryID), let node = SettingsMap.byID[id],
      node.item != nil, let destination = node.destination, let target = node.target
    else { return nil }
    self.entryID = entryID
    self.destination = destination
    self.dictionaryTab = node.dictionaryTab
    self.target = target
    self.fallbacks = node.fallbacks
  }
}

/// A pending arrival at a chosen entry, published by `SettingsNavigationState` when a search
/// navigation commits and read through `\.settingsReveal` (#3482 plan §3.4). The token increments
/// on every commit, so choosing the same entry twice reveals twice and a stale reveal can be told
/// from the current one.
// periphery:ignore - read by the reveal handler in a later PR B chunk (#3482)
struct SettingsReveal: Equatable {
  let entryID: String
  /// The control to arrive at (the plan's "anchor").
  let anchor: SettingsMapID
  /// Tried in order when `anchor` is not on screen.
  let fallbacks: [SettingsMapID]
  let token: Int

  /// Where to arrive given the controls on screen now: `anchor`, else the first declared fallback
  /// that is mounted. Nil when none is, which is an implementation failure under plan §3.4 and
  /// never a successful arrival.
  func arrival(mounted: Set<SettingsMapID>) -> SettingsMapID? {
    ([anchor] + fallbacks).first { mounted.contains($0) }
  }
}
