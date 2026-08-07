import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
// #1956: the cross-surface agreement test compares the picker's tier split
// against the catalog's, so it needs the catalog row type and the shared key.
@testable import EnviousWisprLLM

/// #1914: the MODEL SELECTION DROPDOWN — the picker you choose an armed model
/// from, NOT the Manage Models catalog (that is
/// `OllamaManageModelsPresentationTests`).
///
/// Same scope boundary as its sibling, and worth restating because it is the
/// thing a reader will assume wrongly: this suite protects the GROUPING POLICY.
/// It does NOT prove SwiftUI renders the hosted section, places it correctly,
/// or that the picker's selection binds. If the view stopped calling this type
/// entirely, every test here would still pass. That half is a Live UAT item.
@Suite("Ollama model picker presentation (#1914)")
struct OllamaModelPickerPresentationTests {

  private func model(
    _ id: String, available: Bool = true, isRemote: Bool = false,
    provider: LLMProvider = .ollama
  ) -> LLMModelInfo {
    LLMModelInfo(
      id: id, displayName: id, provider: provider, isAvailable: available, isRemote: isRemote)
  }

  // MARK: - The partition itself

  /// The property that makes every other assertion here meaningful: no row is
  /// dropped, and no row appears twice. Structural in `groups(from:)` (one
  /// pass, no overlapping filters), asserted anyway because a future edit could
  /// reintroduce filters.
  @Test("every input row lands in exactly one group")
  func partitionsExactlyOnce() {
    let input = [
      model("llama3.2"),
      model("phi3-mini"),
      model("gpt-oss:120b-cloud", isRemote: true),
      model("deepseek-v3.1:671b-cloud", isRemote: true),
      model("locked-model", available: false),
      model("qwen3:4b"),
    ]

    let groups = OllamaModelPickerPresentation.groups(from: input, provider: .ollama)
    let placed =
      groups.recommended.map(\.id) + groups.other.map(\.id) + groups.hosted.map(\.id)
      + groups.locked.map(\.id)

    #expect(placed.count == input.count, "a row was dropped or duplicated")
    #expect(Set(placed) == Set(input.map(\.id)))
  }

  // MARK: - Hosted models get their own group

  @Test("available hosted Ollama models go to the hosted group and nowhere else")
  func hostedRowsAreSeparated() {
    let groups = OllamaModelPickerPresentation.groups(
      from: [model("llama3.2"), model("gpt-oss:120b-cloud", isRemote: true)],
      provider: .ollama)

    #expect(groups.hosted.map(\.id) == ["gpt-oss:120b-cloud"])
    #expect(!groups.recommended.map(\.id).contains("gpt-oss:120b-cloud"))
    #expect(!groups.other.map(\.id).contains("gpt-oss:120b-cloud"))
  }

  /// The ordering trap. `isRecommendedForCleanup` keys on tokens in the id, and
  /// a hosted model can carry one — Ollama really does host models whose names
  /// contain "flash" and "mini". If remoteness were checked AFTER the
  /// recommended split, a model running on someone else's servers would sit at
  /// the top of the list under a heading that says nothing about where it runs.
  @Test("a hosted model whose id LOOKS recommended is still hosted, not recommended")
  func hostedBeatsRecommended() {
    let id = "some-mini-model:cloud"
    #expect(
      AIPolishModelClassifier.isRecommendedForCleanup(id),
      "fixture must genuinely satisfy the recommended predicate or this test proves nothing")

    let groups = OllamaModelPickerPresentation.groups(
      from: [model(id, isRemote: true)], provider: .ollama)

    #expect(groups.hosted.map(\.id) == [id])
    #expect(groups.recommended.isEmpty)
  }

  /// Unavailable wins over hosted: a locked row must stay disabled, and a
  /// hosted row is enabled. Getting this backwards would make an unselectable
  /// model look selectable.
  @Test("an unavailable hosted model is locked, not hosted")
  func lockedBeatsHosted() {
    let groups = OllamaModelPickerPresentation.groups(
      from: [model("gpt-oss:120b-cloud", available: false, isRemote: true)],
      provider: .ollama)

    #expect(groups.locked.map(\.id) == ["gpt-oss:120b-cloud"])
    #expect(groups.hosted.isEmpty)
  }

  // MARK: - Local Ollama rows keep today's behaviour

  @Test("local Ollama rows keep the recommended and other split")
  func localRowsUnchanged() {
    let groups = OllamaModelPickerPresentation.groups(
      from: [model("phi3-mini"), model("llama3.2")], provider: .ollama)

    #expect(groups.recommended.map(\.id) == ["phi3-mini"])
    #expect(groups.other.map(\.id) == ["llama3.2"])
    #expect(groups.hosted.isEmpty)
  }

  @Test("group order within each section follows input order")
  func orderPreserved() {
    let groups = OllamaModelPickerPresentation.groups(
      from: [
        model("b-cloud", isRemote: true), model("a-cloud", isRemote: true),
      ], provider: .ollama)

    #expect(groups.hosted.map(\.id) == ["b-cloud", "a-cloud"])
  }

  // MARK: - Other providers are untouched

  /// Remoteness is an Ollama-daemon fact. A cloud provider's rows carry `false`
  /// by construction, but the gate is written on the PROVIDER too, so a
  /// hypothetical `true` from a cloud row could never invent a hosted group in
  /// an OpenAI picker.
  @Test("non-Ollama providers never produce a hosted group, even if a row claims remoteness")
  func otherProvidersNeverGroupHosted() {
    for provider in [LLMProvider.openAI, .gemini, .claude] {
      let groups = OllamaModelPickerPresentation.groups(
        from: [
          model("gpt-4o-mini", isRemote: true, provider: provider),
          model("gpt-4o", isRemote: true, provider: provider),
          model("legacy", available: false, provider: provider),
        ], provider: provider)

      #expect(groups.hosted.isEmpty, "\(provider) must never show a hosted group")
      #expect(groups.recommended.map(\.id) == ["gpt-4o-mini"], "\(provider) recommended split")
      #expect(groups.other.map(\.id) == ["gpt-4o"], "\(provider) other split")
      #expect(groups.locked.map(\.id) == ["legacy"], "\(provider) locked split")
    }
  }

  @Test("an empty input produces four empty groups")
  func emptyInput() {
    let groups = OllamaModelPickerPresentation.groups(from: [], provider: .ollama)
    #expect(groups.recommended.isEmpty)
    #expect(groups.other.isEmpty)
    #expect(groups.hosted.isEmpty)
    #expect(groups.locked.isEmpty)
  }

  // MARK: - Heading copy

  /// One heading, one string, shared with the Manage Models list. Two spellings
  /// of the same fact is how the two surfaces would come to describe the same
  /// model differently.
  @Test("the hosted heading is shared with the Manage Models list")
  func headingIsShared() {
    #expect(
      OllamaModelPickerPresentation.hostedGroupTitle
        == OllamaCatalogPresentation.hostedGroupTitle)
    #expect(OllamaModelPickerPresentation.hostedGroupTitle == "Runs on Ollama's servers")
  }

  /// Rule 6: no em or en dashes in user-facing copy.
  // MARK: - #1956 Three buckets in the dropdown

  /// The founder's request: installed locally, free cloud, paid cloud.
  @Test("hosted picker rows split into free and may-need-paid")
  func hostedRowsSplitIntoTiers() throws {
    let hosted = [
      model("gpt-oss:20b-cloud", isRemote: true),
      model("glm-5.2:cloud", isRemote: true),
      model("nemotron-3-super:cloud", isRemote: true),
    ]
    let tiers = try #require(
      OllamaModelPickerPresentation.hostedTiers(
        hosted, now: OllamaCatalogPresentation.tierSnapshot.verifiedAt))
    #expect(tiers.free.map(\.id) == ["gpt-oss:20b-cloud", "nemotron-3-super:cloud"])
    #expect(tiers.mayNeedPaid.map(\.id) == ["glm-5.2:cloud"])
    #expect(tiers.checkedAt == OllamaCatalogPresentation.tierSnapshot.verifiedAt)
  }

  /// The whole reason the picker calls the catalog's partition instead of
  /// carrying its own: the two surfaces must never disagree about a model's
  /// bucket. A copied implementation would pass its own tests while drifting.
  @Test("the picker and the Manage Models list bucket the same model identically")
  func pickerAndCatalogAgree() throws {
    let now = OllamaCatalogPresentation.tierSnapshot.verifiedAt
    // Deliberately the two NAME FORMS of one model: the picker sees the
    // registered `-cloud` id, the catalog can see the advertised one.
    let pickerRows = [
      model("gpt-oss:20b-cloud", isRemote: true),
      model("glm-5.2:cloud", isRemote: true),
    ]
    let catalogRows = [
      OllamaModelCatalogEntry(
        name: "gpt-oss:20b", displayName: "gpt-oss:20b", parameterCount: "",
        qualityTier: .medium, downloadSize: "", isDownloaded: false, isRemote: true),
      OllamaModelCatalogEntry(
        name: "glm-5.2", displayName: "glm-5.2", parameterCount: "",
        qualityTier: .medium, downloadSize: "", isDownloaded: false, isRemote: true),
    ]

    let picker = try #require(OllamaModelPickerPresentation.hostedTiers(pickerRows, now: now))
    let catalog = try #require(
      OllamaCatalogPresentation.hostedTierPartition(catalogRows, modelName: \.name, now: now))

    #expect(picker.free.count == catalog.free.count)
    #expect(picker.mayNeedPaid.count == catalog.mayNeedPaid.count)
    #expect(
      picker.free.map { OllamaSetupService.hostedCatalogKey($0.id) }
        == catalog.free.map { OllamaSetupService.hostedCatalogKey($0.name) })
  }

  /// Expiry degrades to no claim, exactly as the list does, and the caller
  /// renders one neutral section from that.
  @Test("an expired snapshot makes no tier claim in the picker either")
  func expiredSnapshotMakesNoPickerClaim() {
    let expired = OllamaCatalogPresentation.tierSnapshot.verifiedAt
      .addingTimeInterval(OllamaCatalogPresentation.tierSnapshotLifetime + 1)
    #expect(
      OllamaModelPickerPresentation.hostedTiers(
        [model("gpt-oss:20b-cloud", isRemote: true)], now: expired) == nil)
  }

  /// Two-way control: nothing is dropped by the split.
  @Test("every hosted row survives the tier split exactly once")
  func tierSplitLosesNothing() throws {
    let hosted =
      (1...6).map { model("model-\($0):cloud", isRemote: true) }
      + [model("gpt-oss:120b-cloud", isRemote: true)]
    let tiers = try #require(
      OllamaModelPickerPresentation.hostedTiers(
        hosted, now: OllamaCatalogPresentation.tierSnapshot.verifiedAt))
    #expect(tiers.free.count + tiers.mayNeedPaid.count == hosted.count)
    #expect(Set(tiers.free.map(\.id)).isDisjoint(with: Set(tiers.mayNeedPaid.map(\.id))))
  }

  @Test("the hosted heading contains no em or en dash")
  func headingHasNoDashes() {
    let title = OllamaModelPickerPresentation.hostedGroupTitle
    #expect(!title.contains("\u{2014}"))
    #expect(!title.contains("\u{2013}"))
  }
}
