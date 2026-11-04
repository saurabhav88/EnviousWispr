import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprLLM

/// #4353 D6: the cloud model list in the three model menus, their labels and notes.
///
/// When this fails a menu offers a model the list hides, recommends one the list does not,
/// shows a stale name or date, or orders models by the wrong date.
@MainActor
@Suite("Cloud model presentation (#4353)", .tags(.productOutcome))
struct CloudModelPresentationTests {

  /// Every value is the opposite of what the compiled heuristics would say for its id.
  static func list(_ rows: String) -> CloudModelList? {
    try? CloudModelList.validated(
      from: Data(#"{"schema":1,"updated":"2026-11-04","models":[\#(rows)]}"#.utf8)
    ).get()
  }

  static func row(
    _ id: String, recommended: Bool = false, hidden: Bool = false, chat: Bool = true,
    extra: String = ""
  ) -> String {
    #"{"provider":"openAI","id":"\#(id)","recommended":\#(recommended),"hidden":\#(hidden),"request":{"openAIEffort":"omit","temperature":"include"},"supportsChatCompletions":\#(chat),"allowsFileBatch":true\#(extra)}"#
  }

  static let observed = ContinuousClock.now

  static func info(
    _ id: String, name: String? = nil, released: Date? = nil,
    availability: LLMModelAvailability = .available
  ) -> LLMModelInfo {
    LLMModelInfo(
      id: id, displayName: name ?? id, provider: .openAI, availability: availability,
      isRemote: false, availabilityObservedAt: observed, releaseDate: released)
  }

  static func day(_ text: String) -> Date? { CloudModelPresentation.releaseDate(text) }

  @Test("a listed recommendation overrides the tier words; unlisted ids keep them")
  func listedRecommendationOverrides() {
    let list = Self.list(
      [Self.row("gpt-x-mini", recommended: false), Self.row("gpt-x-sol", recommended: true)]
        .joined(separator: ","))
    #expect(!CloudModelPresentation.isRecommended("gpt-x-mini", provider: .openAI, list: list))
    #expect(CloudModelPresentation.isRecommended("gpt-x-sol", provider: .openAI, list: list))
    #expect(
      CloudModelPresentation.isRecommended("gpt-x-sol-2026-04-23", provider: .openAI, list: list),
      "a dated copy is recommended with its base")
    #expect(CloudModelPresentation.isRecommended("gpt-y-mini", provider: .openAI, list: list))
    #expect(!CloudModelPresentation.isRecommended("gpt-y-sol", provider: .openAI, list: list))
    #expect(
      !CloudModelPresentation.isRecommended("gpt-5.6-luna", provider: .openAI, list: nil),
      "the named fast tier lives only in the list now")
  }

  @Test("names and dates come from the list, then the provider; metadata gone falls back")
  func metadataPrecedence() throws {
    let models = [
      Self.info("gpt-a", name: "Gpt A", released: Self.day("2025-01-01")),
      Self.info("gpt-b", name: "Gpt B", released: Self.day("2026-06-01")),
    ]
    let withMetadata = Self.list(
      [
        Self.row("gpt-a", extra: #","displayName":"GPT A Listed","released":"2026-09-01""#),
        Self.row("gpt-b"),
      ].joined(separator: ","))
    let groups = OllamaModelPickerPresentation.groups(
      from: models, provider: .openAI, chosenModel: "", list: withMetadata)
    #expect(groups.selectable.map(\.id) == ["gpt-a", "gpt-b"], "the list date moves gpt-a first")
    #expect(groups.selectable.first?.localizedDisplayName == "GPT A Listed")
    #expect(groups.selectable.last?.localizedDisplayName == "Gpt B", "no list name: the provider's")
    #expect(models[0].displayName == "Gpt A", "the discovered row is never edited")
    #expect(groups.selectable.first?.availabilityObservedAt == Self.observed)

    let without = Self.list([Self.row("gpt-a"), Self.row("gpt-b")].joined(separator: ","))
    let plain = OllamaModelPickerPresentation.groups(
      from: models, provider: .openAI, chosenModel: "", list: without)
    #expect(plain.selectable.map(\.id) == ["gpt-b", "gpt-a"])
    #expect(plain.selectable.first?.localizedDisplayName == "Gpt B")
  }

  @Test("a hidden row is never offered, chosen or dated; a dated copy inherits hiding")
  func hiddenRows() {
    let list = Self.list(
      [Self.row("gpt-hidden", hidden: true), Self.row("gpt-shown")].joined(separator: ","))
    let models = [
      Self.info("gpt-hidden"), Self.info("gpt-hidden-2026-04-23"), Self.info("gpt-shown"),
      Self.info("gpt-shown-2026-04-23"),
    ]
    let chosenHidden = OllamaModelPickerPresentation.groups(
      from: models, provider: .openAI, chosenModel: "gpt-hidden", list: list)
    #expect(chosenHidden.selectable.map(\.id) == ["gpt-shown"])
    let chosenDated = OllamaModelPickerPresentation.groups(
      from: models, provider: .openAI, chosenModel: "gpt-shown-2026-04-23", list: list)
    #expect(
      Set(chosenDated.selectable.map(\.id)) == ["gpt-shown", "gpt-shown-2026-04-23"],
      "the chosen dated copy stays; hidden rows stay out")
    // The stored hidden choice keeps its own label and is not replaced.
    #expect(
      CloudModelPresentation.label(for: "gpt-hidden", provider: .openAI, models: models, list: list)
        == "gpt-hidden")
  }

  @Test("the label resolves a choice absent from the catalog without inventing one")
  func labelForAbsentChoice() {
    let list = Self.list(Self.row("gpt-gone", extra: #","displayName":"GPT Gone""#))
    #expect(
      CloudModelPresentation.label(for: "gpt-gone", provider: .openAI, models: [], list: list)
        == "GPT Gone")
    #expect(
      CloudModelPresentation.label(for: "gpt-unknown", provider: .openAI, models: [], list: list)
        == "gpt-unknown")
    #expect(
      CloudModelPresentation.label(
        for: "gpt-gone-2026-04-23", provider: .openAI, models: [], list: list)
        == "GPT Gone", "a dated copy takes its base row's name")
    // The production closed-menu decision names an absent choice the same way, also while the
    // catalog is empty, and keeps its other states.
    func field(_ chosen: String, models: [LLMModelInfo] = [], discovering: Bool = false) -> String {
      ModelFieldLabel.text(
        provider: .openAI, chosen: chosen, models: models, isDiscovering: discovering, list: list)
    }
    #expect(field("gpt-gone") == "GPT Gone")
    #expect(field("gpt-gone", models: [Self.info("gpt-other")]) == "GPT Gone")
    #expect(field("gpt-gone", discovering: true) == "Refreshing models…")
    #expect(field("") == "Save API key to discover models")
    #expect(field("", models: [Self.info("gpt-other")]) == PolishSetupSurfaceCopy.chooseAModel)
  }

  @Test("dated copies inherit their base row's name and date; an exact dated row wins")
  func datedMetadataInheritance() {
    let list = Self.list(
      [
        Self.row("gpt-a", extra: #","displayName":"GPT A","released":"2026-09-01""#),
        Self.row("gpt-a-2026-10-10", extra: #","displayName":"GPT A October""#),
      ].joined(separator: ","))
    let inherited = CloudModelPresentation.presented(
      Self.info("gpt-a-2026-04-23", name: "Gpt A Dated"), list: list)
    #expect(inherited.id == "gpt-a-2026-04-23", "the id never changes")
    #expect(inherited.localizedDisplayName == "GPT A")
    #expect(inherited.releaseDate == Self.day("2026-09-01"))
    let exact = CloudModelPresentation.presented(
      Self.info("gpt-a-2026-10-10", released: Self.day("2026-10-10")), list: list)
    #expect(exact.localizedDisplayName == "GPT A October")
    #expect(exact.releaseDate == Self.day("2026-10-10"), "no list date: the provider's")
    let unlisted = CloudModelPresentation.presented(Self.info("gpt-z", name: "Gpt Z"), list: list)
    #expect(unlisted.localizedDisplayName == "Gpt Z")
  }

  @Test("a refreshed list that makes a cached OpenAI row ineligible removes it without rediscovery")
  func endpointEligibilityFollowsTheList() {
    let models = [Self.info("gpt-a"), Self.info("gpt-b")]
    let eligible = Self.list([Self.row("gpt-a"), Self.row("gpt-b")].joined(separator: ","))
    let ineligible = Self.list(
      [Self.row("gpt-a"), Self.row("gpt-b", chat: false)].joined(separator: ","))
    #expect(
      OllamaModelPickerPresentation.groups(
        from: models, provider: .openAI, chosenModel: "gpt-b", list: eligible
      ).selectable.map(\.id).sorted() == ["gpt-a", "gpt-b"])
    let after = OllamaModelPickerPresentation.groups(
      from: models, provider: .openAI, chosenModel: "gpt-b", list: ineligible)
    #expect(after.selectable.map(\.id) == ["gpt-a"])
    #expect(after.locked.isEmpty)
    #expect(
      CloudModelPresentation.label(for: "gpt-b", provider: .openAI, models: models, list: ineligible)
        == "gpt-b", "the stored choice keeps its label")
  }

  @Test("a holder refresh changes the menu without touching settings or availability")
  func refreshChangesPresentationOnly() throws {
    let models = [Self.info("gpt-a", availability: .inconclusive)]
    let before = OllamaModelPickerPresentation.groups(
      from: models, provider: .openAI, chosenModel: "gpt-a", list: Self.list(Self.row("gpt-a")))
    let after = OllamaModelPickerPresentation.groups(
      from: models, provider: .openAI, chosenModel: "gpt-a",
      list: Self.list(Self.row("gpt-a", extra: #","displayName":"Renamed""#)))
    #expect(before.selectable.first?.localizedDisplayName == "gpt-a")
    #expect(after.selectable.first?.localizedDisplayName == "Renamed")
    #expect(after.selectable.first?.availability == .inconclusive, "no fresh evidence is invented")
    #expect(models[0].displayName == "gpt-a")
  }
}
