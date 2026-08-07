import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprLLM

/// #1914: the MANAGE MODELS catalog — the list where models are downloaded and
/// deleted, NOT the selection dropdown.
///
/// Scope boundary, stated rather than implied: this suite proves every catalog
/// row carries correct remoteness and that both construction branches preserve
/// it. It does NOT prove SwiftUI renders two groups — a view body is not
/// reachable from a unit test, and asserting on it would mean re-implementing
/// the view, which tests the copy rather than the app. The rendered grouping,
/// the suppressed columns and the VoiceOver announcement are Live UAT items.
///
/// What that division buys: the failure this suite CAN catch is the silent one
/// (a remote model indistinguishable from a local one in the data), while the
/// failure it cannot catch is the visible one (a heading in the wrong place).
@Suite("Ollama Manage Models catalog presentation (#1914)")
struct OllamaManageModelsPresentationTests {

  private func row(
    _ name: String, isRemote: Bool, sizeBytes: Int64 = 2_900_000_000,
    parameterSize: String? = "4B"
  ) -> OllamaDownloadedModel {
    OllamaDownloadedModel(
      exactName: name,
      canonicalName: OllamaSetupService.canonicalModelName(name),
      parameterSize: parameterSize,
      parameterBillions: 4.0,
      fileSizeBytes: sizeBytes,
      displayName: name,
      facts: OllamaModelFacts(isRemote: isRemote, thinks: false)
    )
  }

  private func entry(named name: String, in catalog: [OllamaModelCatalogEntry])
    -> OllamaModelCatalogEntry?
  {
    catalog.first { OllamaSetupService.canonicalModelName($0.name) == name }
  }

  @Test("a hosted model's row is marked remote and a local one is not")
  func remotenessReachesTheRow() {
    let catalog = OllamaSetupService.dynamicCatalog(from: [
      row("gpt-oss:120b-cloud", isRemote: true),
      row("llama3.2", isRemote: false),
    ])
    #expect(entry(named: "gpt-oss:120b-cloud", in: catalog)?.isRemote == true)
    #expect(entry(named: "llama3.2", in: catalog)?.isRemote == false)
  }

  /// The branch most likely to lose remoteness silently. `dynamicCatalog` builds
  /// a row two ways — a curated overlay for a model we ship metadata for, and an
  /// inferred row for anything else. Setting `isRemote` on only the inferred
  /// branch would drop it for exactly the well-known models, which is the
  /// hardest case to notice by eye.
  @Test("remoteness survives the curated-overlay branch, not just the custom branch")
  func remotenessSurvivesCuratedOverlay() {
    // `llama3.2` is in the shipped curated catalog, so this row takes the
    // overlay path. A hosted build of a curated model is unusual but the code
    // must not assume it cannot happen.
    let curated = OllamaSetupService.dynamicCatalog(from: [row("llama3.2", isRemote: true)])
    #expect(entry(named: "llama3.2", in: curated)?.isRemote == true)

    // And a model with no curated entry takes the inferred path.
    let custom = OllamaSetupService.dynamicCatalog(from: [
      row("some-unknown-model:7b", isRemote: true)
    ])
    #expect(entry(named: "some-unknown-model:7b", in: custom)?.isRemote == true)
  }

  /// Curated SUGGESTIONS are models the user has not downloaded. Every one is a
  /// local pull by definition, so none may be marked remote — otherwise a
  /// perfectly ordinary Download row would file itself under a hosted heading.
  @Test("undownloaded suggestions are never remote")
  func suggestionsAreNeverRemote() {
    let catalog = OllamaSetupService.dynamicCatalog(from: [])
    #expect(!catalog.isEmpty)
    #expect(catalog.allSatisfy { !$0.isRemote })
    #expect(catalog.allSatisfy { !$0.isDownloaded })
  }

  /// Two-way control on the partition, asserted against the PRODUCTION policy
  /// the view actually reads — not against a filter re-implemented here. An
  /// earlier version of this test wrote its own `isRemote` predicate, which
  /// meant it stayed green even if the view dropped the hosted group entirely:
  /// it was testing its own copy, not the app.
  @Test("catalogPresentation partitions into exactly the local and hosted rows")
  func catalogPartitionsBothWays() {
    let catalog = OllamaSetupService.dynamicCatalog(from: [
      row("gpt-oss:120b-cloud", isRemote: true),
      row("gemma4:31b-cloud", isRemote: true),
      row("llama3.2", isRemote: false),
    ])
    let groups = OllamaCatalogPresentation.groups(from: catalog.filter(\.isDownloaded))
    #expect(groups.hosted.count == 2)
    #expect(groups.local.count == 1)
    #expect(groups.local.first?.name == "llama3.2")
    // Nothing may be dropped or duplicated by the split.
    #expect(groups.local.count + groups.hosted.count == catalog.filter(\.isDownloaded).count)
  }

  /// The heading is production-owned so the view cannot silently reword it into
  /// something that no longer says where the model runs.
  @Test("the hosted group heading states where the model runs")
  func hostedGroupHeadingIsAccurate() {
    let title = OllamaCatalogPresentation.hostedGroupTitle
    #expect(title == "Runs on Ollama's servers")
    // It is a statement of fact, not a warning — no scare words.
    for word in ["warning", "caution", "unsafe", "risk", "privacy"] {
      #expect(!title.lowercased().contains(word))
    }
  }

  /// Metadata suppression is also production-owned, and asserted in BOTH
  /// directions: a policy that hid everything, or showed everything, would each
  /// pass a one-sided test while breaking one of the two groups.
  @Test("size and quality are shown for local rows and suppressed for hosted ones")
  func metadataVisibilityDiscriminatesBothWays() {
    let catalog = OllamaSetupService.dynamicCatalog(from: [
      row("gpt-oss:120b-cloud", isRemote: true),
      row("llama3.2", isRemote: false),
    ])
    let hosted = entry(named: "gpt-oss:120b-cloud", in: catalog)!
    let local = entry(named: "llama3.2", in: catalog)!
    #expect(OllamaCatalogPresentation.showsSizeAndQuality(local) == true)
    #expect(OllamaCatalogPresentation.showsSizeAndQuality(hosted) == false)
  }

  /// Local rows keep their metadata. The view suppresses size and quality for
  /// hosted rows at render time; this asserts the LOCAL side is untouched, so a
  /// suppression bug cannot quietly blank a local model's columns too.
  @Test("local rows keep parameter count and download size")
  func localRowsKeepMetadata() {
    let catalog = OllamaSetupService.dynamicCatalog(from: [row("llama3.2", isRemote: false)])
    let local = entry(named: "llama3.2", in: catalog)
    #expect(local?.parameterCount == "4B")
    #expect(local?.downloadSize.isEmpty == false)
  }

  /// Why the view suppresses size for hosted rows: the daemon reports a
  /// manifest-only size for a remote model. This freezes the reason in a test so
  /// a future reader does not "fix" the suppression as a cosmetic inconsistency.
  @Test("a hosted row's reported size is manifest-only and would mislead if shown")
  func remoteSizeIsManifestOnlyAndMustNotBeTrusted() {
    // 316 bytes was the measured manifest size for a 158-billion-parameter
    // cloud model on 2026-08-01.
    let catalog = OllamaSetupService.dynamicCatalog(from: [
      row("deepseek-v4-flash", isRemote: true, sizeBytes: 316, parameterSize: nil)
    ])
    let remote = entry(named: "deepseek-v4-flash", in: catalog)
    #expect(remote?.isRemote == true)
    // The entry still CARRIES the misleading value — suppression is the view's
    // job, not the catalog's. Asserting it here documents that the data layer
    // deliberately does not lie about what the daemon said.
    #expect(remote?.downloadSize.isEmpty == false)
  }

  // MARK: - Parsing feeds all of the above

  /// The catalog's facts must come from the shared decoder over each row, so a
  /// payload that mixes hosted and local models classifies each correctly.
  @Test("parsing a mixed /api/tags payload assigns remoteness per row")
  func parsingAssignsRemotenessPerRow() {
    let models: [[String: Any]] = [
      ["name": "gpt-oss:120b-cloud", "remote_host": "https://ollama.com"],
      ["name": "llama3.2"],
    ]
    let parsed = OllamaSetupService.parseDownloadedModels(fromTagsModels: models)
    #expect(parsed.count == 2)
    #expect(parsed.first { $0.exactName == "gpt-oss:120b-cloud" }?.facts.isRemote == true)
    #expect(parsed.first { $0.exactName == "llama3.2" }?.facts.isRemote == false)
  }

  @Test("parsing carries the thinking capability through to the catalog model")
  func parsingCarriesThinking() {
    let models: [[String: Any]] = [
      ["name": "qwen3:0.6b", "capabilities": ["completion", "thinking"]],
      ["name": "tinyllama:latest", "capabilities": ["completion"]],
    ]
    let parsed = OllamaSetupService.parseDownloadedModels(fromTagsModels: models)
    #expect(parsed.first { $0.exactName == "qwen3:0.6b" }?.facts.thinks == true)
    #expect(parsed.first { $0.exactName == "tinyllama:latest" }?.facts.thinks == false)
  }

  @Test("a row without a name is dropped, as before")
  func namelessRowsDropped() {
    let parsed = OllamaSetupService.parseDownloadedModels(fromTagsModels: [
      ["size": 123], ["name": "llama3.2"],
    ])
    #expect(parsed.count == 1)
    #expect(parsed.first?.exactName == "llama3.2")
  }

  // MARK: - #1956 helpers

  /// A catalog entry, built directly rather than through the daemon parser,
  /// because these policies take entries and the parse path is already covered
  /// above.
  private func catalogEntry(
    _ name: String, isRemote: Bool, isDownloaded: Bool = false,
    displayName: String? = nil, parameterCount: String = "4B",
    downloadSize: String = "~2 GB", qualityTier: OllamaQualityTier = .best
  ) -> OllamaModelCatalogEntry {
    OllamaModelCatalogEntry(
      name: name, displayName: displayName ?? name, parameterCount: parameterCount,
      qualityTier: qualityTier, downloadSize: downloadSize,
      isDownloaded: isDownloaded, isRemote: isRemote)
  }

  /// Compares two catalogs field by field, in order. Count first and then `zip`,
  /// never a subscript after a non-halting `#expect`: a count regression would
  /// otherwise replace a readable failure with an out-of-bounds crash.
  private func expectSameEntries(
    _ actual: [OllamaModelCatalogEntry], _ expected: [OllamaModelCatalogEntry],
    _ label: String, sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(actual.count == expected.count, "\(label): count", sourceLocation: sourceLocation)
    for (index, pair) in zip(actual, expected).enumerated() {
      let (lhs, rhs) = pair
      #expect(lhs.name == rhs.name, "\(label): name at \(index)", sourceLocation: sourceLocation)
      #expect(
        lhs.displayName == rhs.displayName, "\(label): displayName at \(index)",
        sourceLocation: sourceLocation)
      #expect(
        lhs.parameterCount == rhs.parameterCount, "\(label): parameterCount at \(index)",
        sourceLocation: sourceLocation)
      #expect(
        lhs.downloadSize == rhs.downloadSize, "\(label): downloadSize at \(index)",
        sourceLocation: sourceLocation)
      #expect(
        lhs.qualityTier == rhs.qualityTier, "\(label): qualityTier at \(index)",
        sourceLocation: sourceLocation)
      #expect(
        lhs.isDownloaded == rhs.isDownloaded, "\(label): isDownloaded at \(index)",
        sourceLocation: sourceLocation)
      #expect(
        lhs.isRemote == rhs.isRemote, "\(label): isRemote at \(index)",
        sourceLocation: sourceLocation)
    }
  }

  private func splitTiers(
    _ groups: OllamaCatalogPresentation.HostedTierGroups
  ) -> (free: [OllamaModelCatalogEntry], paid: [OllamaModelCatalogEntry], checkedAt: Date)? {
    if case .split(let free, let paid, let checkedAt) = groups {
      return (free, paid, checkedAt)
    }
    return nil
  }

  private func neutralEntries(
    _ groups: OllamaCatalogPresentation.HostedTierGroups
  ) -> [OllamaModelCatalogEntry]? {
    if case .neutral(let entries) = groups { return entries }
    return nil
  }

  /// `verifiedAt` plus whole days, computed on a UTC calendar so the boundary
  /// tests do not move with the machine's time zone.
  private func daysAfterSnapshot(_ days: Int, sourceLocation: SourceLocation = #_sourceLocation)
    throws -> Date
  {
    var calendar = Calendar(identifier: .gregorian)
    let utc = try #require(TimeZone(identifier: "UTC"), sourceLocation: sourceLocation)
    calendar.timeZone = utc
    return try #require(
      calendar.date(
        byAdding: .day, value: days,
        to: OllamaCatalogPresentation.tierSnapshot.verifiedAt),
      sourceLocation: sourceLocation)
  }

  // MARK: - #1956 Delete policy

  @Test("a local row may be deleted")
  func localRowShowsDelete() {
    #expect(OllamaCatalogPresentation.showsDeleteAction(catalogEntry("llama3.2", isRemote: false)))
  }

  @Test("a hosted row may never be deleted, registered or merely advertised")
  func hostedRowHidesDelete() {
    #expect(
      OllamaCatalogPresentation.showsDeleteAction(
        catalogEntry("gpt-oss:20b-cloud", isRemote: true, isDownloaded: true)) == false)
    #expect(
      OllamaCatalogPresentation.showsDeleteAction(
        catalogEntry("glm-5.2", isRemote: true, isDownloaded: false)) == false)
  }

  /// The delete policy must not consult `isDownloaded`. A policy keyed on it
  /// would hide Delete from a local model the user has not downloaded yet, and
  /// would show it on a registered hosted one.
  @Test("delete eligibility follows remoteness alone, never downloaded state")
  func deletePolicyIgnoresDownloadedState() {
    for downloaded in [true, false] {
      #expect(
        OllamaCatalogPresentation.showsDeleteAction(
          catalogEntry("llama3.2", isRemote: false, isDownloaded: downloaded)))
      #expect(
        OllamaCatalogPresentation.showsDeleteAction(
          catalogEntry("glm-5.2", isRemote: true, isDownloaded: downloaded)) == false)
    }
  }

  // MARK: - #1956 Action label

  @Test("a local row's action is Download")
  func localRowSaysDownload() {
    #expect(
      OllamaCatalogPresentation.actionLabel(for: catalogEntry("llama3.2", isRemote: false))
        == "Download")
  }

  @Test("a hosted row's action is Add, registered or merely advertised")
  func hostedRowSaysAdd() {
    #expect(
      OllamaCatalogPresentation.actionLabel(
        for: catalogEntry("gpt-oss:20b-cloud", isRemote: true, isDownloaded: true)) == "Add")
    #expect(
      OllamaCatalogPresentation.actionLabel(
        for: catalogEntry("glm-5.2", isRemote: true, isDownloaded: false)) == "Add")
  }

  @Test("the action label follows remoteness alone, never downloaded state")
  func actionLabelIgnoresDownloadedState() {
    for downloaded in [true, false] {
      #expect(
        OllamaCatalogPresentation.actionLabel(
          for: catalogEntry("llama3.2", isRemote: false, isDownloaded: downloaded)) == "Download")
      #expect(
        OllamaCatalogPresentation.actionLabel(
          for: catalogEntry("glm-5.2", isRemote: true, isDownloaded: downloaded)) == "Add")
    }
  }

  // MARK: - #1956 Pull-progress row matching (whole-diff review r2)

  /// The defect: a hosted row is keyed by the ADVERTISED id while the pull runs
  /// under the REGISTRABLE name, so exact equality could never match and the row
  /// showed no progress and no Cancel for the pull's whole duration.
  @Test("a hosted row matches the pull its own Add started")
  func hostedRowMatchesResolvedPullName() {
    let entry = catalogEntry("glm-5.2", isRemote: true, isDownloaded: false)
    #expect(
      OllamaCatalogPresentation.rowIsPulling(
        entry, currentPullingModel: "glm-5.2:cloud", hostedPullAdvertisedID: "glm-5.2"))
    #expect(
      OllamaCatalogPresentation.rowIsPulling(
        entry, currentPullingModel: "glm-5.2-cloud", hostedPullAdvertisedID: "glm-5.2"))
  }

  /// Anti-vacuity: the pre-fix implementation was exact equality, which passes
  /// any test that only ever asks about the advertised name.
  @Test("a hosted row does not match an unrelated model's pull")
  func hostedRowIgnoresUnrelatedPull() {
    let entry = catalogEntry("glm-5.2", isRemote: true, isDownloaded: false)
    #expect(
      !OllamaCatalogPresentation.rowIsPulling(
        entry, currentPullingModel: "kimi-k3:cloud", hostedPullAdvertisedID: "kimi-k3"))
    #expect(
      !OllamaCatalogPresentation.rowIsPulling(
        entry, currentPullingModel: nil, hostedPullAdvertisedID: "glm-5.2"))
  }

  /// Review round 3: the first fix normalised both sides through
  /// `hostedCatalogKey`, which moved the collision rather than removing it. A
  /// local `gpt-oss:20b` pull and a hosted `gpt-oss:20b` row share that key, and
  /// both rows CAN coexist because only a remote registration suppresses a
  /// hosted suggestion. The hosted row would have shown progress and a Cancel
  /// that aborts a download it never started.
  @Test("a hosted row never matches a LOCAL pull that shares its base name")
  func hostedRowDoesNotMatchLocalPullOfSameBaseName() {
    let hosted = catalogEntry("gpt-oss:20b", isRemote: true, isDownloaded: false)
    // A local pull records no advertised id, which is what makes them distinct.
    #expect(
      !OllamaCatalogPresentation.rowIsPulling(
        hosted, currentPullingModel: "gpt-oss:20b", hostedPullAdvertisedID: nil))
  }

  /// The mirror of the case above, and the one the first fix was written for.
  @Test("a local row never matches a hosted pull of the same base name")
  func localRowDoesNotMatchHostedPull() {
    let local = catalogEntry("gpt-oss:20b", isRemote: false, isDownloaded: false)
    #expect(
      !OllamaCatalogPresentation.rowIsPulling(
        local, currentPullingModel: "gpt-oss:20b-cloud", hostedPullAdvertisedID: "gpt-oss:20b"))
    // And the local row still matches its own pull, so the scoping did not
    // simply disable matching for local rows.
    #expect(
      OllamaCatalogPresentation.rowIsPulling(
        local, currentPullingModel: "gpt-oss:20b", hostedPullAdvertisedID: nil))
  }

  /// A stale advertised id cannot outlive its pull, because liveness is read
  /// from `currentPullingModel` and not from the id.
  @Test("a leftover advertised id matches nothing once the pull has ended")
  func staleAdvertisedIDMatchesNothing() {
    let hosted = catalogEntry("glm-5.2", isRemote: true, isDownloaded: false)
    #expect(
      !OllamaCatalogPresentation.rowIsPulling(
        hosted, currentPullingModel: nil, hostedPullAdvertisedID: "glm-5.2"))
  }

  // MARK: - #1956 Hosted rows keep their variant tag (whole-diff review r3)

  /// The defect: `inferDisplayName` drops everything after the colon, and hosted
  /// rows suppress size and quality, so two models differing only in their tag
  /// rendered as one indistinguishable pair with no way to tell the Add buttons
  /// apart. Four of the eighteen advertised on 2026-08-06 were two such pairs.
  @Test("advertised hosted models differing only by tag render distinctly")
  func hostedSuggestionsKeepTheirTag() {
    let catalog = OllamaSetupService.dynamicCatalog(
      from: [],
      cloudCatalogIDs: [
        "gpt-oss:20b", "gpt-oss:120b", "deepseek-v4-flash:0731", "deepseek-v4-flash:preview",
      ])
    let hosted = catalog.filter(\.isRemote)
    #expect(hosted.count == 4)
    let names = hosted.map(\.displayName)
    #expect(Set(names).count == 4, "collided: \(names)")
    #expect(names.contains("gpt-oss:20b"))
    #expect(names.contains("gpt-oss:120b"))
  }

  /// REGISTERED hosted rows have the same defect, inherited from #1914 rather
  /// than introduced here. Fixing only the advertised half would leave the
  /// collision on the rows a user already has.
  @Test("registered hosted models differing only by tag also render distinctly")
  func registeredHostedRowsKeepTheirTag() {
    let catalog = OllamaSetupService.dynamicCatalog(from: [
      row("gpt-oss:20b-cloud", isRemote: true),
      row("gpt-oss:120b-cloud", isRemote: true),
    ])
    let names = catalog.filter(\.isRemote).map(\.displayName)
    #expect(names.count == 2)
    #expect(Set(names).count == 2, "collided: \(names)")
  }

  /// Two-way control. Local rows keep their prettified names, so the fix did not
  /// simply stop prettifying everything.
  @Test("local rows still get their curated or prettified display name")
  func localRowsKeepPrettifiedNames() {
    let catalog = OllamaSetupService.dynamicCatalog(from: [
      row("llama3.2", isRemote: false),
      row("someones-finetune:7b", isRemote: false),
    ])
    let local = catalog.filter { !$0.isRemote && $0.isDownloaded }
    let names = local.map(\.displayName)
    // The curated entry keeps its shipped name, and the unknown one is still
    // prettified rather than shown raw.
    #expect(names.contains("Llama 3.2"), "\(names)")
    #expect(names.contains("Someones Finetune"), "\(names)")
  }

  // MARK: - #1956 The snapshot itself

  /// Built independently through a UTC calendar rather than by restating the
  /// production number, so this proves the shipped instant IS that date rather
  /// than proving the constant equals itself.
  @Test("the snapshot is dated exactly 2026-08-05, independent of machine time zone")
  func snapshotDateIsExactlyTheFifthOfAugust() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    var components = DateComponents()
    components.year = 2026
    components.month = 8
    components.day = 5
    let expected = try #require(calendar.date(from: components))
    #expect(OllamaCatalogPresentation.tierSnapshot.verifiedAt == expected)
  }

  @Test("the snapshot lists exactly the seven advertised ids measured free on that date")
  func snapshotMembershipIsExactlyTheSeven() {
    let expected: Set<String> = [
      "gemma4:31b", "gpt-oss:120b", "gpt-oss:20b", "minimax-m3",
      "nemotron-3-nano:30b", "nemotron-3-super", "nemotron-3-ultra",
    ]
    #expect(OllamaCatalogPresentation.tierSnapshot.freeVerified == expected)
    #expect(OllamaCatalogPresentation.tierSnapshot.freeVerified.count == 7)
  }

  /// The snapshot holds ADVERTISED ids. A pullable form here would still work,
  /// because membership is normalised, but its presence would mean the shipped
  /// data had drifted from what the endpoint actually advertises.
  @Test("the snapshot holds advertised ids, not pullable cloud registrations")
  func snapshotHoldsAdvertisedIDs() {
    for id in OllamaCatalogPresentation.tierSnapshot.freeVerified {
      #expect(id.hasSuffix(":cloud") == false, "\(id) is a pullable form")
      #expect(id.hasSuffix("-cloud") == false, "\(id) is a pullable form")
    }
  }

  // MARK: - #1956 Expiry boundary

  @Test("at 29 days the snapshot still orders the list")
  func splitAtTwentyNineDays() throws {
    let entries = [catalogEntry("gpt-oss:20b", isRemote: true)]
    let groups = OllamaCatalogPresentation.hostedTierGroups(
      entries: entries, now: try daysAfterSnapshot(29))
    let split = try #require(splitTiers(groups))
    #expect(split.free.map(\.name) == ["gpt-oss:20b"])
    #expect(split.checkedAt == OllamaCatalogPresentation.tierSnapshot.verifiedAt)
  }

  @Test("at exactly 30 days the snapshot still orders the list")
  func splitAtExactlyThirtyDays() throws {
    let entries = [catalogEntry("gpt-oss:20b", isRemote: true)]
    let groups = OllamaCatalogPresentation.hostedTierGroups(
      entries: entries, now: try daysAfterSnapshot(30))
    let split = try #require(splitTiers(groups))
    #expect(split.free.map(\.name) == ["gpt-oss:20b"])
  }

  /// The point of the whole design: a stale snapshot degrades to NO claim, not a
  /// wrong one. So the expired form carries no tiers and no date at all.
  @Test("at 31 days the split disappears entirely and makes no dated claim")
  func neutralAtThirtyOneDays() throws {
    let entries = [
      catalogEntry("gpt-oss:20b", isRemote: true),
      catalogEntry("deepseek-v4-pro", isRemote: true),
    ]
    let groups = OllamaCatalogPresentation.hostedTierGroups(
      entries: entries, now: try daysAfterSnapshot(31))
    let neutral = try #require(neutralEntries(groups))
    expectSameEntries(neutral, entries, "expired")
    #expect(splitTiers(groups) == nil)
  }

  /// A clock earlier than the snapshot date cannot establish its age, so the
  /// snapshot must make no claim rather than appear infinitely fresh. Without
  /// this the split would render a verification date in the future.
  @Test("a clock earlier than the snapshot date makes no tier claim")
  func neutralWhenClockPredatesSnapshot() throws {
    let entries = [
      catalogEntry("gpt-oss:20b", isRemote: true),
      catalogEntry("deepseek-v4-pro", isRemote: true),
    ]
    let groups = OllamaCatalogPresentation.hostedTierGroups(
      entries: entries,
      now: OllamaCatalogPresentation.tierSnapshot.verifiedAt.addingTimeInterval(-1))

    let neutral = try #require(neutralEntries(groups))
    expectSameEntries(neutral, entries, "backdated clock")
    #expect(splitTiers(groups) == nil)
  }

  /// The boundary on the other side: exactly the snapshot instant IS current.
  @Test("a clock exactly at the snapshot instant still orders the list")
  func splitAtExactlyTheSnapshotInstant() throws {
    let entries = [catalogEntry("gpt-oss:20b", isRemote: true)]
    let groups = OllamaCatalogPresentation.hostedTierGroups(
      entries: entries, now: OllamaCatalogPresentation.tierSnapshot.verifiedAt)
    let split = try #require(splitTiers(groups))
    #expect(split.free.map(\.name) == ["gpt-oss:20b"])
  }

  // MARK: - #1956 Tier classification

  @Test("a model absent from the snapshot is kept and placed under may-need-paid")
  func unknownModelGoesToPaidTier() throws {
    let entries = [
      catalogEntry("gpt-oss:20b", isRemote: true),
      catalogEntry("some-model-ollama-added-yesterday", isRemote: true),
    ]
    let groups = OllamaCatalogPresentation.hostedTierGroups(
      entries: entries, now: try daysAfterSnapshot(1))
    let split = try #require(splitTiers(groups))
    #expect(split.free.map(\.name) == ["gpt-oss:20b"])
    #expect(split.paid.map(\.name) == ["some-model-ollama-added-yesterday"])
  }

  /// The line between ordering and membership, asserted directly.
  @Test("an id present only in the snapshot creates no row")
  func snapshotOnlyMembershipCreatesNothing() throws {
    let entries = [catalogEntry("glm-5.2", isRemote: true)]
    let groups = OllamaCatalogPresentation.hostedTierGroups(
      entries: entries, now: try daysAfterSnapshot(1))
    let split = try #require(splitTiers(groups))
    #expect(split.free.isEmpty)
    expectSameEntries(split.paid, entries, "snapshot-only")
    #expect(split.free.contains { $0.name == "gpt-oss:120b" } == false)
    #expect(split.paid.contains { $0.name == "gpt-oss:120b" } == false)
  }

  @Test("a registered cloud row and its advertised suggestion get the same tier")
  func registeredAndAdvertisedFormsShareATier() throws {
    let entries = [
      catalogEntry("gpt-oss:20b-cloud", isRemote: true, isDownloaded: true),
      catalogEntry("gpt-oss:20b", isRemote: true, isDownloaded: false),
    ]
    let groups = OllamaCatalogPresentation.hostedTierGroups(
      entries: entries, now: try daysAfterSnapshot(1))
    let split = try #require(splitTiers(groups))
    #expect(split.free.map(\.name) == ["gpt-oss:20b-cloud", "gpt-oss:20b"])
    #expect(split.paid.isEmpty)
  }

  /// Normalisation has to happen on BOTH sides. This injects a snapshot whose
  /// membership is written in the pullable form; without membership
  /// normalisation the advertised row would fall through to may-need-paid.
  @Test("snapshot membership is normalised too, not only the entry name")
  func snapshotMembershipIsNormalised() throws {
    let injected = OllamaCatalogPresentation.HostedTierSnapshot(
      verifiedAt: OllamaCatalogPresentation.tierSnapshot.verifiedAt,
      freeVerified: ["kimi-k3:cloud"])
    let entries = [catalogEntry("kimi-k3", isRemote: true)]
    let groups = OllamaCatalogPresentation.hostedTierGroups(
      entries: entries, snapshot: injected, now: try daysAfterSnapshot(1))
    let split = try #require(splitTiers(groups))
    #expect(split.free.map(\.name) == ["kimi-k3"])
    #expect(split.paid.isEmpty)
  }

  // MARK: - #1956 Preservation

  @Test("every row survives the split exactly once, with its fields intact")
  func splitPreservesEveryRowExactlyOnce() throws {
    let entries = [
      catalogEntry("gpt-oss:20b", isRemote: true, displayName: "GPT OSS 20B"),
      catalogEntry("deepseek-v4-pro", isRemote: true, parameterCount: "671B"),
      catalogEntry("minimax-m3", isRemote: true, downloadSize: ""),
      catalogEntry("glm-5.2", isRemote: true, qualityTier: .medium),
    ]
    let groups = OllamaCatalogPresentation.hostedTierGroups(
      entries: entries, now: try daysAfterSnapshot(1))
    let split = try #require(splitTiers(groups))

    let flattened = split.free + split.paid
    #expect(flattened.count == entries.count)
    for entry in entries {
      #expect(flattened.filter { $0.name == entry.name }.count == 1, "\(entry.name) appears once")
    }
    expectSameEntries(
      flattened.sorted { $0.name < $1.name }, entries.sorted { $0.name < $1.name }, "flattened")
  }

  @Test("input order is preserved inside each tier")
  func splitKeepsStableOrderWithinTiers() throws {
    let entries = [
      catalogEntry("minimax-m3", isRemote: true),
      catalogEntry("deepseek-v4-pro", isRemote: true),
      catalogEntry("gpt-oss:20b", isRemote: true),
      catalogEntry("glm-5.2", isRemote: true),
      catalogEntry("gemma4:31b", isRemote: true),
    ]
    let groups = OllamaCatalogPresentation.hostedTierGroups(
      entries: entries, now: try daysAfterSnapshot(1))
    let split = try #require(splitTiers(groups))
    #expect(split.free.map(\.name) == ["minimax-m3", "gpt-oss:20b", "gemma4:31b"])
    #expect(split.paid.map(\.name) == ["deepseek-v4-pro", "glm-5.2"])
  }

  @Test("an empty hosted list produces empty tiers rather than a crash or a claim")
  func emptyInputIsHandled() throws {
    let current = OllamaCatalogPresentation.hostedTierGroups(
      entries: [], now: try daysAfterSnapshot(1))
    let split = try #require(splitTiers(current))
    #expect(split.free.isEmpty)
    #expect(split.paid.isEmpty)

    let expired = OllamaCatalogPresentation.hostedTierGroups(
      entries: [], now: try daysAfterSnapshot(31))
    #expect(try #require(neutralEntries(expired)).isEmpty)
  }

  // MARK: - #1956 Copy

  @Test("no heading promises current free access")
  func headingsMakeNoCurrentFreeClaim() {
    let headings = [
      OllamaCatalogPresentation.freeVerifiedGroupTitle,
      OllamaCatalogPresentation.mayNeedPaidGroupTitle,
      OllamaCatalogPresentation.hostedGroupTitle,
    ]
    #expect(OllamaCatalogPresentation.freeVerifiedGroupTitle == "Try these first")
    #expect(OllamaCatalogPresentation.mayNeedPaidGroupTitle == "May need a paid Ollama plan")
    for heading in headings {
      #expect(heading.lowercased().contains("free") == false, "\(heading) claims free")
      #expect(heading.lowercased().contains("no cost") == false, "\(heading) claims free")
    }
  }

  // MARK: - #1956 The verification date is stated in UTC (review r6)

  /// The defect, observed in the founder's own screenshot of the shipped build:
  /// "Checked on Aug 4, 2026" for a snapshot dated the 5th. `snapshotVerifiedAt`
  /// is midnight UTC, so rendering it in a zone west of Greenwich moves it back a
  /// day — and a dated advisory whose date is wrong points the reader at the
  /// wrong evidence while looking authoritative.
  ///
  /// Locale is pinned here so this asserts the ZONE, which is what changed, and
  /// not the machine's date-format preferences.
  @Test("the checked-on date is the snapshot's UTC day, not the viewer's local day")
  func checkedOnDateIsStatedInUTC() {
    let text = OllamaCatalogPresentation.checkedOnDateText(
      OllamaCatalogPresentation.tierSnapshot.verifiedAt, locale: Locale(identifier: "en_US"))
    #expect(text.contains("5"), "\(text) is not the 5th")
    #expect(text.contains("Aug"), "\(text) is not August")
    #expect(!text.contains("4"), "\(text) shows the previous day")
  }

  /// Two-way control on the zone: the same instant one second later is still the
  /// 5th, and one second BEFORE midnight UTC is the 4th. Without this, a
  /// hard-coded string would pass the test above.
  @Test("the formatter reads the instant, not a constant")
  func checkedOnDateTracksTheInstant() {
    let us = Locale(identifier: "en_US")
    let midnight = OllamaCatalogPresentation.tierSnapshot.verifiedAt
    #expect(
      OllamaCatalogPresentation.checkedOnDateText(midnight.addingTimeInterval(-1), locale: us)
        .contains("4"))
    #expect(
      OllamaCatalogPresentation.checkedOnDateText(midnight.addingTimeInterval(1), locale: us)
        .contains("5"))
  }

  /// The sentence and the bare date share one formatter, so the list and the
  /// picker cannot drift on wording or zone.
  @Test("the sentence form wraps the same date text")
  func checkedOnSentenceWrapsTheDate() {
    let date = OllamaCatalogPresentation.tierSnapshot.verifiedAt
    let us = Locale(identifier: "en_US")
    #expect(
      OllamaCatalogPresentation.checkedOnText(date, locale: us)
        == "Checked on \(OllamaCatalogPresentation.checkedOnDateText(date, locale: us))")
  }

  // MARK: - #1956 Partition still accepts a suggestion

  @Test("a remote not-downloaded suggestion joins the hosted group and nothing is lost")
  func partitionAcceptsAdvertisedSuggestion() {
    let catalog = [
      catalogEntry("llama3.2", isRemote: false, isDownloaded: true),
      catalogEntry("gpt-oss:20b-cloud", isRemote: true, isDownloaded: true),
      catalogEntry("glm-5.2", isRemote: true, isDownloaded: false),
    ]
    let groups = OllamaCatalogPresentation.groups(from: catalog)
    #expect(groups.local.map(\.name) == ["llama3.2"])
    #expect(groups.hosted.map(\.name) == ["gpt-oss:20b-cloud", "glm-5.2"])
    #expect(groups.local.count + groups.hosted.count == catalog.count)
  }
}
