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

  // MARK: - Hosted tier ordering (#1956)
  //
  // Decision history, because this was removed and restored and the next reader
  // deserves to know why rather than re-running the argument: the coverage round
  // proposed this ordering, it shipped, the founder removed it on 2026-08-06
  // reading the question as "should we ship a list", and restored it the same
  // day on seeing it rendered — "good UX and helped the user understand what was
  // free vs not free". The restoring decision is the current one.
  //
  // What makes it defensible where a membership list was rejected: NOTHING in
  // either data source reveals a model's tier. `https://ollama.com/v1/models`
  // carries exactly `id`, `object`, `created` and `owned_by`; `POST /api/show`
  // on a paid model returns `capabilities: ["thinking", "completion", "tools"]`
  // and no access field. Both measured 2026-08-06. So a tier claim can only be a
  // list we maintain — which is why this one orders rows it can never create or
  // remove, states a date instead of a promise, and expires into no claim at all
  // rather than into a wrong one.

  /// A DATED, ADVISORY ordering snapshot.
  ///
  /// This is emphatically NOT a membership list. #1956's founder comment rejected
  /// a shipped model list because it rots the way `phi-2` did (#1951), and that
  /// objection stands. This snapshot can only REORDER rows that Ollama's live
  /// catalog already produced: it can never create a row, remove one, or change
  /// one. An id present only here renders nothing.
  ///
  /// `freeVerified` holds ADVERTISED ids, not pullable `:cloud` / `-cloud`
  /// registrations, and membership is compared through
  /// `OllamaSetupService.hostedCatalogKey` on BOTH sides so the two forms of the
  /// same model land in the same tier.
  struct HostedTierSnapshot: Sendable, Equatable {
    /// The instant the tiers below were checked. Never "now", never a promise.
    let verifiedAt: Date
    let freeVerified: Set<String>
  }

  /// The hosted group, ordered.
  ///
  /// Two cases rather than a Boolean plus arrays, so an expired snapshot cannot
  /// be represented as a split with empty tiers or a sentinel date. `neutral`
  /// carries no date because an expired snapshot must make NO claim, not a weak
  /// one.
  enum HostedTierGroups {
    case split(
      freeVerified: [OllamaModelCatalogEntry],
      mayNeedPaid: [OllamaModelCatalogEntry],
      checkedAt: Date
    )
    case neutral(entries: [OllamaModelCatalogEntry])
  }

  /// Headings for the active split. Neither says a model IS free or promises
  /// current access. Neither mentions a date either: the split result separately
  /// carries `checkedAt` for the view to render, and the expired neutral result
  /// carries no date and no tier claim.
  ///
  /// A model that turned paid on day 3 may remain in the first group until the
  /// snapshot expires, and the honest 403 at use time is already shipped (#1914).
  static let freeVerifiedGroupTitle = "Try these first"
  static let mayNeedPaidGroupTitle = "May need a paid Ollama plan"

  /// 2026-08-05T00:00:00Z. Stored as an absolute instant so neither the machine's
  /// time zone nor its locale can move it; `snapshotDateIsExactlyTheFifthOfAugust`
  /// proves this equals that date by constructing it independently through a UTC
  /// calendar rather than by restating this number.
  private static let snapshotVerifiedAt = Date(timeIntervalSince1970: 1_785_888_000)

  /// Measured live against `https://ollama.com/v1/models` and per-model probes on
  /// 2026-08-05: 18 hosted models, 7 free, 11 requiring a subscription (HTTP 403,
  /// `this model requires a subscription, upgrade for access`).
  ///
  /// Only the free seven are listed. There is deliberately no paid list and no
  /// 18-model roster here, because anything this file cannot see is simply
  /// untiered rather than wrong.
  static let tierSnapshot = HostedTierSnapshot(
    verifiedAt: snapshotVerifiedAt,
    freeVerified: [
      "gemma4:31b",
      "gpt-oss:120b",
      "gpt-oss:20b",
      "minimax-m3",
      "nemotron-3-nano:30b",
      "nemotron-3-super",
      "nemotron-3-ultra",
    ]
  )

  /// How long the snapshot's ordering is worth applying.
  ///
  /// Sized against measurement, not taste: 3 of 18 models changed tier within 4
  /// days of `ollama-operations.md`'s 2026-08-01 record. Past this the split
  /// disappears completely, so a stale snapshot degrades to NO claim rather than
  /// to a wrong one. That is the whole reason an ordering hint is permitted where
  /// a membership list was rejected.
  static let tierSnapshotLifetime: TimeInterval = 30 * 24 * 60 * 60

  /// The snapshot's verification date, as text, in UTC.
  ///
  /// UTC is not a detail here. `snapshotVerifiedAt` is midnight UTC on the day
  /// the tiers were checked, so rendering it in the viewer's own zone moves it
  /// backwards for everyone west of Greenwich: the founder's screenshot of the
  /// shipped build read "Checked on Aug 4, 2026" for a snapshot dated the 5th,
  /// which is the release note's date and the one in every audit. A dated
  /// advisory whose date is wrong is worse than an undated one, because the
  /// wrongness is invisible and points the reader at the wrong evidence.
  ///
  /// Still locale-aware for ORDER and month name — an American date format
  /// shown to everyone was the reason this renders from the `Date` rather than
  /// from a preformatted string. Only the zone is pinned.
  /// Just the date, for callers that compose their own sentence around it.
  static func checkedOnDateText(_ checkedAt: Date, locale: Locale = .autoupdatingCurrent) -> String
  {
    // The zone belongs in the STYLE's initializer. `.timeZone(_:)` on a built
    // style takes a format SYMBOL — it controls how a zone is spelled out, not
    // which zone the date is read in — so chaining it there compiles into a
    // no-op for this purpose on any type where it does compile.
    let style = Date.FormatStyle(
      date: .abbreviated,
      locale: locale,
      timeZone: TimeZone(identifier: "UTC") ?? .gmt)
    return checkedAt.formatted(style)
  }

  static func checkedOnText(_ checkedAt: Date, locale: Locale = .autoupdatingCurrent) -> String {
    "Checked on \(checkedOnDateText(checkedAt, locale: locale))"
  }

  /// The tier decision itself, over anything that can name a model.
  ///
  /// Generic because TWO surfaces ask this question — the Manage Models list
  /// (`OllamaModelCatalogEntry`) and the selection dropdown (`LLMModelInfo`) —
  /// and they must never disagree about which bucket a model is in. A second
  /// implementation on the picker side would be a copy that drifts, which is
  /// exactly the defect this type's own header warns about.
  ///
  /// Returns `nil` when the snapshot cannot be applied, which the callers render
  /// as one neutral group. `nil` means "make no tier claim", never "no free
  /// models".
  static func hostedTierPartition<Row>(
    _ rows: [Row],
    modelName: (Row) -> String,
    snapshot: HostedTierSnapshot = tierSnapshot,
    now: Date = Date()
  ) -> (free: [Row], mayNeedPaid: [Row], checkedAt: Date)? {
    // A negative age means the clock predates the snapshot, so the clock cannot
    // establish the snapshot's age at all. That is not freshness, and treating it
    // as unlimited freshness would surface a verification date in the future. No
    // claim is the safe direction, exactly as for an expired snapshot.
    let age = now.timeIntervalSince(snapshot.verifiedAt)
    guard age >= 0, age <= tierSnapshotLifetime else { return nil }

    // Both sides go through the same key, so a registered `gpt-oss:20b-cloud`
    // row and its advertised `gpt-oss:20b` suggestion resolve to one identity.
    // Normalising only the row would silently drop every model whose snapshot
    // membership was written in the pullable form.
    let freeKeys = Set(snapshot.freeVerified.map(OllamaSetupService.hostedCatalogKey))

    var free: [Row] = []
    var mayNeedPaid: [Row] = []
    for row in rows {
      if freeKeys.contains(OllamaSetupService.hostedCatalogKey(modelName(row))) {
        free.append(row)
      } else {
        mayNeedPaid.append(row)
      }
    }
    return (free, mayNeedPaid, snapshot.verifiedAt)
  }

  /// Splits the hosted rows into free-verified-first order while the snapshot is
  /// current, and returns them untouched once it expires.
  ///
  /// Every input row appears in the output exactly once in both forms. The
  /// snapshot decides ORDER only.
  static func hostedTierGroups(
    entries: [OllamaModelCatalogEntry],
    snapshot: HostedTierSnapshot = tierSnapshot,
    now: Date = Date()
  ) -> HostedTierGroups {
    guard
      let split = hostedTierPartition(
        entries, modelName: \.name, snapshot: snapshot, now: now)
    else {
      return .neutral(entries: entries)
    }
    return .split(
      freeVerified: split.free, mayNeedPaid: split.mayNeedPaid, checkedAt: split.checkedAt)
  }

}
