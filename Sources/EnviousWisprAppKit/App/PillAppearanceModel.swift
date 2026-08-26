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

  /// Bumped whenever the coordinator reports that capability may have moved for
  /// a reason no settings key records. Observed rather than merely stored: it is
  /// READ by `wordsCapability` below, which is what puts a SwiftUI page reading
  /// that property into this object's dependency graph.
  private var capabilityGeneration = 0

  /// Why words are or are not available right now.
  ///
  /// **The discard is load-bearing, not tidying.** Reading `capabilityGeneration`
  /// is what registers the dependency; the closure behind `capability` reaches a
  /// class that is not `@Observable`, so a page that read only its result would
  /// never be invalidated when removal suppression begins or ends.
  var wordsCapability: PillWordsCapability {
    _ = capabilityGeneration
    return capability()
  }

  /// The coordinator reporting a change no settings key can announce.
  func capabilityDidChange() {
    capabilityGeneration &+= 1
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

  /// Choose a design AND put Live Preview into the state that design needs
  /// (founder, 2026-08-26).
  ///
  /// **This is the first thing in the app that writes `livePreviewEnabled` on the
  /// user's behalf** — until now only the user's own toggle did. The founder was
  /// offered a confirm step and declined it: picking a pill switches the setting
  /// silently, because the pill IS the choice and being asked to confirm the
  /// consequence of your own tap is friction.
  ///
  /// The cost, stated because nothing in the UI states it: someone who turned
  /// Live Preview on, then picks a compact pill because they prefer how it looks,
  /// loses Live Preview and is not told. That is the accepted trade, not an
  /// oversight.
  ///
  /// **Only reachable for a design the picker OFFERS.** Where words are
  /// impossible — no engine here, or a model mid-removal — the words-capable card
  /// is disabled and this is never called for it, so the setting is never written
  /// to a value the engine cannot honour.
  func chooseCoupled(_ design: RecordingPillDesign) {
    settings.livePreviewEnabled = design.canHoldWords
    choose(design, holdingWords: design.canHoldWords)
  }

  /// Whether this design can be picked RIGHT NOW, given that picking it will set
  /// Live Preview to whatever it needs.
  ///
  /// **Asked of the CATALOG, about the state the tap would produce.** A first
  /// version answered it here — wordless always true, words-capable true when the
  /// capability is `.available` or `.previewOff` — which put a SECOND derivation of
  /// offerability beside `PillCatalog.offers`, free to disagree with it the day
  /// either moved. `offers(_:holdingWords:)` above exists precisely so the picker
  /// decides nothing, and coupling is not a reason to stop using it.
  ///
  /// The only genuinely local judgment left is whether words are POSSIBLE on this
  /// machine, which is about the engine rather than about any design.
  func offersCoupled(_ design: RecordingPillDesign, capability: PillWordsCapability) -> Bool {
    offers(design, holdingWords: design.canHoldWords && Self.wordsArePossible(capability))
  }

  /// Whether words could be produced here AT ALL, switch aside.
  ///
  /// **`.engineUnsupported` and `.modelBeingRemoved` are not about the switch**, so
  /// no tap can reach them; `.previewOff` is, which is exactly what makes the
  /// coupling meaningful. An exhaustive switch rather than a two-case comparison,
  /// so a capability added later fails to compile here instead of silently
  /// defaulting to "words are impossible".
  static func wordsArePossible(_ capability: PillWordsCapability) -> Bool {
    switch capability {
    case .available, .previewOff: return true
    case .engineUnsupported, .modelBeingRemoved: return false
    }
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
