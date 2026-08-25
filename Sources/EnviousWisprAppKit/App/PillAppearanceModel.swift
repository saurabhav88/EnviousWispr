import EnviousWisprCore
import EnviousWisprServices
import Observation

/// The Appearance page's window onto the recording pill (#2376 Phase 4, C7).
///
/// **One narrow home rather than a second derivation.** The picker needs two
/// things the settings store cannot give it: whether this machine can show words
/// as you speak, and WHY not when it cannot. Both come from the live-preview
/// coordinator through `LivePreviewBridge`, so this holds that one closure and
/// the settings object, and computes nothing of its own.
///
/// **It deliberately does NOT re-derive capability from the engine resolver**,
/// which is what `LivePreviewSettingsView` does for its own page. That page asks
/// "is any engine available here" — a different question from the coordinator's
/// "will the engine I am configured to use actually run, and is the preview
/// switched on" — and shipping both would put two answers to one question in
/// front of the same user on two pages.
@MainActor
@Observable
final class PillAppearanceModel {

  private let settings: SettingsManager
  private let capability: () -> PillWordsCapability

  init(settings: SettingsManager, capability: @escaping () -> PillWordsCapability) {
    self.settings = settings
    self.capability = capability
  }

  /// Why words are or are not available right now.
  var wordsCapability: PillWordsCapability { capability() }

  /// The designs in one group, in the catalog's own order.
  func designs(holdingWords: Bool) -> [RecordingPillDesign] {
    PillCatalog.designs(holdingWords: holdingWords)
  }

  /// **Whether this design may be chosen, asked of the CATALOG.** The picker
  /// decides nothing: a design it greys out is exactly a design the pill would
  /// refuse, because `PillCatalog.offers` is defined in terms of the same
  /// `resolve` the director calls.
  func offers(_ design: RecordingPillDesign, holdingWords: Bool) -> Bool {
    PillCatalog.offers(design, capabilityHasWords: holdingWords)
  }

  /// The design currently chosen for a group.
  func selection(holdingWords: Bool) -> RecordingPillDesign {
    holdingWords
      ? settings.recordingPillDesignWithWords
      : settings.recordingPillDesignWithoutWords
  }

  /// Choose a design for ONE group. Writing only that group's key is what
  /// preserves the other side's memory across a capability flip.
  func choose(_ design: RecordingPillDesign, holdingWords: Bool) {
    if holdingWords {
      settings.recordingPillDesignWithWords = design
    } else {
      settings.recordingPillDesignWithoutWords = design
    }
  }
}
