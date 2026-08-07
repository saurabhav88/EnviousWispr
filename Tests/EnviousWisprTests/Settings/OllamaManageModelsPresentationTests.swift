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
