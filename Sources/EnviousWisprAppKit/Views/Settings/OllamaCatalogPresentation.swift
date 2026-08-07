import EnviousWisprLLM
import Foundation

/// #1914: how the **Manage Models** list is split for display, and what each row
/// may show.
///
/// This is the list where models are downloaded and deleted. It is NOT the model
/// selection dropdown, which renders `LLMModelInfo` from discovery and gains its
/// own grouping in a later change.
///
/// Lives in AppKit rather than in `EnviousWisprLLM` because it is presentation
/// policy — grouping, column visibility and heading copy. Putting it beside the
/// daemon client would widen that module's public API with UI concerns and let
/// a non-UI caller depend on a heading string.
///
/// It is nonetheless PRODUCTION code rather than an inline filter in the view.
/// An earlier version of these tests wrote their own `isRemote` predicate, so
/// they proved only that the copy worked; changing the real split could not fail
/// them. Now a mutation to this type does fail them.
///
/// The boundary that buys, stated exactly: these tests protect the GROUPING AND
/// VISIBILITY POLICY. They do NOT protect the SwiftUI wiring — if the view
/// stopped calling this type, or rendered the hosted group in the wrong place,
/// the tests would still pass. That half is a Live UAT item.
enum OllamaCatalogPresentation {

  /// The Manage Models list, split for display.
  struct Groups {
    /// Rows that run on this Mac. Keep their existing order and metadata.
    let local: [OllamaModelCatalogEntry]
    /// Rows Ollama proxies to its own servers, shown under their own heading.
    let hosted: [OllamaModelCatalogEntry]
  }

  /// Heading for the hosted group. A statement of where the model runs, not a
  /// warning: per the founder's 2026-08-01 doctrine correction there is no
  /// interstitial and no discouragement of the hosted path.
  static let hostedGroupTitle = "Runs on Ollama's servers"

  static func groups(from catalog: [OllamaModelCatalogEntry]) -> Groups {
    Groups(
      local: catalog.filter { !$0.isRemote },
      hosted: catalog.filter(\.isRemote)
    )
  }

  /// Size and quality are meaningless for a model that is not on this disk. A
  /// hosted row's reported `size` is manifest-only (316 bytes for a
  /// 158-billion-parameter model, measured 2026-08-01), so showing it is worse
  /// than showing nothing.
  static func showsSizeAndQuality(_ entry: OllamaModelCatalogEntry) -> Bool {
    !entry.isRemote
  }

  // MARK: - Row actions (#1956)

  /// #1956: whether a row may be deleted.
  ///
  /// A hosted row offers NO removal of any kind, renamed or otherwise. Deleting
  /// one used to be a one-way door: a hosted model could re-enter Manage Models
  /// only by already being registered on the Mac, so the founder lost all nine in
  /// one pass with no way back. Founder ruling, held after the coverage round
  /// argued for a renamed Remove.
  ///
  /// Reads `isRemote` and nothing else. `isDownloaded` deliberately plays no part:
  /// a registered hosted row and a merely advertised one are equally undeletable.
  static func showsDeleteAction(_ entry: OllamaModelCatalogEntry) -> Bool {
    !entry.isRemote
  }

  /// #1956: what the row's action button says.
  ///
  /// A hosted registration moves 0 bytes and completes in ~0.469 s (measured
  /// 2026-08-05). Calling that "Download" is the framing #1956 identifies as the
  /// cause of the loss: it invites the user to treat the row as a local file they
  /// can free up space by deleting.
  ///
  /// Reads `isRemote` and nothing else, for the same reason as
  /// `showsDeleteAction`.
  static func actionLabel(for entry: OllamaModelCatalogEntry) -> String {
    entry.isRemote ? "Add" : "Download"
  }

  /// #1956: whether THIS row is the one currently pulling.
  ///
  /// A local row IS its own pull name, so exact equality is correct and stays.
  /// A hosted suggestion is not: the row is keyed by the ADVERTISED id
  /// (`glm-5.2`) while `addHostedModel` resolves and pulls the REGISTRABLE name
  /// (`glm-5.2:cloud`). Exact equality could therefore never match a hosted
  /// pull, so the row rendered neither progress nor Cancel while `isPulling`
  /// disabled its button — a dead-looking control for the pull's whole duration.
  ///
  /// A hosted row matches on the advertised id the SERVICE recorded when it
  /// started the pull, never on a normalised name.
  ///
  /// The first fix here normalised both sides through `hostedCatalogKey`, and
  /// review round 3 caught that it moved the collision instead of removing it:
  /// that key strips the cloud suffix, so a LOCAL `gpt-oss:20b` pull and a
  /// hosted `gpt-oss:20b` row collapse to one key, and both rows can coexist
  /// (only a REMOTE registration suppresses a hosted suggestion). The hosted row
  /// would then show progress and a Cancel that aborts a download it never
  /// started. Name-shape tests such as "does it end in -cloud" would be the same
  /// guess one layer down, and #1914 forbids exactly that classifier.
  ///
  /// `currentPullingModel` still gates liveness for BOTH kinds, so a stale
  /// `hostedPullAdvertisedID` cannot match once a pull reaches any terminal.
  ///
  /// Lives here rather than in the view for the reason this whole type exists:
  /// a private predicate in `AIPolishSettingsView` cannot be tested, and this
  /// one is exactly the kind that fails silently.
  static func rowIsPulling(
    _ entry: OllamaModelCatalogEntry,
    currentPullingModel: String?,
    hostedPullAdvertisedID: String?
  ) -> Bool {
    guard let pulling = currentPullingModel else { return false }
    guard entry.isRemote else { return pulling == entry.name }
    return hostedPullAdvertisedID == entry.name
  }

  // MARK: - Hosted tier ordering: DELIBERATELY ABSENT (#1956)
  //
  // The coverage round proposed a dated free-verified-first ordering, it was
  // built, and the founder then ruled for ONE NEUTRAL LIST of every advertised
  // model (2026-08-06). Do not re-add a tier split, a `freeVerified` set, a
  // `HostedTierSnapshot`, or "Try these first" / "May need a paid Ollama plan"
  // headings without a new founder decision.
  //
  // The reasoning that survives the removal, so the next reader does not
  // reconstruct the rejected design: NOTHING in either data source reveals a
  // model's tier. `https://ollama.com/v1/models` carries exactly `id`, `object`,
  // `created` and `owned_by`; `POST /api/show` on a paid model returns
  // `capabilities: ["thinking", "completion", "tools"]` and no access field.
  // Both measured 2026-08-06. So any tier claim has to be a list WE maintain,
  // and 3 of 18 models changed tier within 4 days of the 2026-08-01 record in
  // `ollama-operations.md`. Ollama's own 403 at use time is the only signal that
  // cannot go stale, and its copy already ships (#1914).

}
