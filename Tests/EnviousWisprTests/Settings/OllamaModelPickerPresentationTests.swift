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

  // MARK: - Local Ollama rows are grouped by measurement (#1950)

  @Test("an unmeasured model is not recommended just because its name carries a cloud token")
  func tokenBearingLocalNameIsNotRecommended() {
    // This test asserted the OPPOSITE before #1950: it pinned `phi3-mini` into "Recommended for
    // cleanup" because the token classifier saw `mini`. We have never run a case through that
    // model. MUTATION CONTROL: restore the classifier for local Ollama and this fails.
    //
    // The fixture precondition is what keeps this test meaningful. If a future edit removed `mini`
    // from the classifier's positives, these names would stop satisfying it and the test would pass
    // without ever exercising the routing boundary, since an unmeasured model is not recommended
    // either way. Same guard as `hostedBeatsRecommended` above, for the same reason.
    for modelID in ["phi3-mini", "acme-mini"] {
      #expect(
        AIPolishModelClassifier.isRecommendedForCleanup(modelID),
        "\(modelID) must genuinely satisfy the cloud token classifier")
    }

    let groups = OllamaModelPickerPresentation.groups(
      from: [model("phi3-mini"), model("acme-mini"), model("llama3.2")], provider: .ollama)

    #expect(groups.recommended.isEmpty)
    #expect(groups.other.map(\.id) == ["phi3-mini", "acme-mini", "llama3.2"])
    #expect(groups.hosted.isEmpty)
  }

  @Test("the models we measured well are the ones recommended")
  func measuredModelsAreRecommended() {
    // The other half of the old defect: no standard local name carries a cloud token, so every
    // model we measured landed under "other" including the best one.
    let groups = OllamaModelPickerPresentation.groups(
      from: [model("qwen2.5:3b"), model("qwen3:0.6b"), model("qwen2.5:7b")], provider: .ollama)

    #expect(groups.recommended.map(\.id) == ["qwen2.5:3b", "qwen3:0.6b", "qwen2.5:7b"])
    #expect(groups.other.isEmpty)
  }

  @Test(
    "every verdict other than recommended lands under other",
    arguments: [
      "gemma2:2b", "gemma2", "gemma3n:e4b",  // mixed
      "llama3.2", "mistral", "deepseek-r1:1.5b",  // unreliable
      "phi3", "llama3.2:1b", "tinyllama",  // no acceptable output
      "eg-1", "eg-1:q4",  // firstParty: makes no claim, so it earns no heading
      "someones-finetune:7b",  // notTested
    ])
  func nonRecommendedVerdictsGoToOther(modelID: String) {
    let groups = OllamaModelPickerPresentation.groups(
      from: [model(modelID)], provider: .ollama)
    #expect(groups.recommended.isEmpty, "\(modelID) must not be recommended")
    #expect(groups.other.map(\.id) == [modelID])
  }

  @Test("a locked recommended model stays locked")
  func lockedBeatsRecommended() {
    // Precedence: availability is decided before any recommendation question.
    let groups = OllamaModelPickerPresentation.groups(
      from: [model("qwen2.5:3b", available: false)], provider: .ollama)
    #expect(groups.locked.map(\.id) == ["qwen2.5:3b"])
    #expect(groups.recommended.isEmpty)
  }

  @Test("a hosted model with a MEASURED-recommended id stays hosted")
  func hostedBeatsMeasuredVerdict() {
    // Sibling of `hostedBeatsRecommended` above, which covers the token-classifier era. Remoteness
    // is still decided before the verdict, so a hosted row never lands under a heading that says
    // nothing about where it runs, even when we measured that model well locally.
    let groups = OllamaModelPickerPresentation.groups(
      from: [model("qwen2.5:3b", isRemote: true)], provider: .ollama)
    #expect(groups.hosted.map(\.id) == ["qwen2.5:3b"])
    #expect(groups.recommended.isEmpty)
  }

  @Test("cloud providers still use the token classifier")
  func cloudProvidersUnchanged() {
    // #617's classifier is correct for the providers it was validated against, and #1950 does not
    // touch them. `gpt-4o-mini` is unmeasured by our local benchmark, so if it were routed through
    // the verdict authority it would drop out of recommended.
    let openAI = OllamaModelPickerPresentation.groups(
      from: [model("gpt-4o-mini"), model("gpt-4o")], provider: .openAI)
    #expect(openAI.recommended.map(\.id) == ["gpt-4o-mini"])
    #expect(openAI.other.map(\.id) == ["gpt-4o"])
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
        downloadSize: "", isDownloaded: false, isRemote: true),
      OllamaModelCatalogEntry(
        name: "glm-5.2", displayName: "glm-5.2", parameterCount: "",
        downloadSize: "", isDownloaded: false, isRemote: true),
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

  /// Review r6: the picker rendered the tier headings with no date, so a dated
  /// snapshot read as current guidance on that surface. A `Section` header is a
  /// single string, so the date goes inline rather than on its own line.
  @Test("a picker tier heading carries its verification date")
  func tierSectionTitleCarriesTheDate() {
    let title = OllamaModelPickerPresentation.tierSectionTitle(
      OllamaModelPickerPresentation.freeVerifiedGroupTitle,
      checkedAt: OllamaCatalogPresentation.tierSnapshot.verifiedAt,
      locale: Locale(identifier: "en_US"))
    #expect(title.hasPrefix("Try these first"))
    #expect(title.contains("checked"))
    // The same UTC day the list shows, not the viewer's local day.
    #expect(title.contains("5"), "\(title)")
    #expect(title.contains("Aug"), "\(title)")
  }

  /// Both surfaces format the date through one owner, so neither can drift on
  /// wording or time zone.
  @Test("the picker heading's date matches the Manage Models date exactly")
  func pickerDateMatchesListDate() {
    let date = OllamaCatalogPresentation.tierSnapshot.verifiedAt
    let us = Locale(identifier: "en_US")
    let listDate = OllamaCatalogPresentation.checkedOnDateText(date, locale: us)
    let pickerTitle = OllamaModelPickerPresentation.tierSectionTitle(
      "Try these first", checkedAt: date, locale: us)
    #expect(pickerTitle.contains(listDate), "\(pickerTitle) does not contain \(listDate)")
  }

  /// Rule 6: no em or en dashes in user-facing copy.
  @Test("the hosted heading contains no em or en dash")
  func headingHasNoDashes() {
    let title = OllamaModelPickerPresentation.hostedGroupTitle
    #expect(!title.contains("\u{2014}"))
    #expect(!title.contains("\u{2013}"))
  }
}
