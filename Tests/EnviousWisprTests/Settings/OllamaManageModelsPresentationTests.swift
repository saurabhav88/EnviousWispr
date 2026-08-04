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
}
