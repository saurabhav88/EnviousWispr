import EnviousWisprLlamaEngine
import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprLLM
@testable import EnviousWisprLocalPolish
@testable import EnviousWisprPipeline

/// #4473 (plan §3.1.1 S6 to S10): each EG-1 size is its own model.
///
/// When this fails, the user's words are polished by another EG-1 size than the one their
/// dictation, import or recovered recording was started with: a small Mac loads the large
/// model, a take is answered by weights it was not qualified on, a size switched during a file
/// import takes the import over, a paused download of one size shows on another, or a
/// recording saved by a newer build loses its other settings (or is replayed on a guess).
/// Encounter: every polish once more than one size is installed. Owner: plan #4473 P5.
@MainActor
@Suite(
  "Each EG-1 size is its own model: no size runs, holds or answers for another (#4473)",
  .tags(.productOutcome))
struct LocalPolishExactModelTests {
  static func target(_ model: LocalPolishModelID, _ name: String) -> LocalPolishTarget {
    LocalPolishTarget(
      configuration: LocalPolishProcessManager.Configuration(
        spec: .fixture(
          modelID: model, serverBinaryURL: URL(fileURLWithPath: "/nonexistent/\(name)-server"),
          modelURL: URL(fileURLWithPath: "/nonexistent/\(name)"), contextTokens: 8192),
        makeArguments: LlamaServerLaunchBuilder.arguments, readinessBudgetSeconds: 1))
  }

  static func runtime(
    _ model: LocalPolishModelID, _ coordinator: LocalPolishServerCoordinator? = nil,
    defaults: UserDefaults? = nil
  ) -> LocalPolishRuntime {
    LocalPolishRuntime(
      manifest: nil, serverBinaryURL: nil, delivery: nil, engine: LlamaServerEngine(),
      defaults: defaults, coordinator: coordinator, modelID: model)
  }

  @Test(
    "with the full size running, another size gets no hold and no server, cannot stop it, and replaces it only after the full size's hold is released"
  )
  func theRunningSizeIsNotAnotherSize() async {
    let coordinator = LocalPolishServerCoordinator()
    await coordinator.transition(
      to: .run(Self.target(.egOne(.full), "full")), intent: coordinator.claimIntent())
    #expect(await coordinator.residentModelForTesting == .egOne(.full))

    for other in [LocalPolishModelID.egOne(.mini), .egOne(.micro)] {
      guard case .changing = await coordinator.acquireLease(for: other, purpose: .inference)
      else {
        Issue.record("\(other) was given a hold on the full size's server")
        continue
      }
      #expect(await coordinator.endpoint(for: other) == nil)
      // "I should not be running" from another size is not news about the full size.
      await coordinator.transition(to: .idle(other), intent: coordinator.claimIntent())
      #expect(await coordinator.residentModelForTesting == .egOne(.full))
    }

    // An import holds the full size. Mini is selected: it waits, then runs.
    guard
      case .granted(let hold) = await coordinator.acquireLease(
        for: .egOne(.full), purpose: .residency)
    else {
      Issue.record("the running size was refused its own hold")
      return
    }
    await coordinator.transition(
      to: .run(Self.target(.egOne(.mini), "mini")), intent: coordinator.claimIntent())
    #expect(await coordinator.residentModelForTesting == .egOne(.full), "the held size stays")
    #expect(await coordinator.hasLease(for: .egOne(.full)))
    #expect(!(await coordinator.hasLease(for: .egOne(.mini))))
    await coordinator.releaseLease(hold)
    #expect(await coordinator.residentModelForTesting == .egOne(.mini), "the waiting size runs")
  }

  @Test("a summary holds the server for its size; a size picked meanwhile runs when it ends")
  func aSummaryHoldsItsOwnSize() async {
    let coordinator = LocalPolishServerCoordinator()
    await coordinator.transition(
      to: .run(Self.target(.egOne(.full), "full")), intent: coordinator.claimIntent())
    guard case .granted(let reservation) = await coordinator.reserveForSummary(.egOne(.full))
    else {
      Issue.record("the summary was not given the server")
      return
    }
    #expect(reservation.model == .egOne(.full))
    await coordinator.transition(
      to: .run(Self.target(.egOne(.micro), "micro")), intent: coordinator.claimIntent())
    #expect(await coordinator.residentModelForTesting == .egOne(.full))
    await coordinator.releaseSummaryReservation(reservation)
    await coordinator.awaitSelectionAfterSummaryForTesting()
    #expect(await coordinator.residentModelForTesting == .egOne(.micro))
  }

  @Test(
    "the runtime of a size is found by that size only, and an import or a summary holds exactly the size it names"
  )
  func lookupAndHoldsAreBySize() async {
    let coordinator = LocalPolishServerCoordinator()
    let full = Self.runtime(.egOne(.full), coordinator)
    let s1 = Self.runtime(.s1Mini, coordinator)
    let mini = Self.runtime(.egOne(.mini), coordinator)
    let set = LocalPolishRuntimeSet(egOne: full, s1Mini: s1, additional: [mini])
    #expect(set.all.count == 3)
    #expect(set.runtime(for: .egOne(.full)) === full)
    #expect(set.runtime(for: .egOne(.mini)) === mini)
    #expect(set.runtime(for: .egOne(.micro)) == nil, "no runtime: never another size's")
    #expect(set.runtime(for: .s1Mini) === s1)

    await coordinator.transition(
      to: .run(Self.target(.egOne(.full), "full")), intent: coordinator.claimIntent())
    #expect(!(await set.holdForImport(.egOne(.micro))), "a size with no runtime")
    #expect(!(await set.holdForImport(.egOne(.mini))), "a size that is not the running one")
    #expect(await set.holdForImport(.egOne(.full)))
    await set.releaseImportHold()?.value

    guard case .held(let hold) = await set.beginSummaryHold(.egOne(.full)) else {
      Issue.record("the summary did not get its hold")
      return
    }
    #expect(hold.model == .egOne(.full) && set.summaryHeldModel == .egOne(.full))
    #expect(set.summaryHeldProvider == .egOne)
    await set.endSummaryHold(hold)
    #expect(set.summaryHeldModel == nil)
    #expect(await set.beginSummaryHold(.egOne(.micro)) == .retryLater)
    #expect(set.summaryHeldModel == nil)
  }

  @Test("each size keeps its own paused-download record; the full size keeps the key EG-1 had")
  func pausedDownloadRecordsArePerSize() throws {
    let suite = "ew-4473-paused-\(UUID().uuidString)"
    let store = try #require(TestDefaults.suite(suite))
    defer { store.removePersistentDomain(forName: suite) }
    let keys = [
      "eg1.pausedInstallProjection", "eg1.mini.pausedInstallProjection",
      "eg1.micro.pausedInstallProjection", "s1.pausedInstallProjection",
    ]
    func stored() -> [String?] { keys.map { store.string(forKey: $0) } }

    Self.runtime(.egOne(.mini), defaults: store).applyInstallStateForTesting(.paused)
    #expect(stored() == [nil, "paused", nil, nil])
    Self.runtime(.egOne(.micro), defaults: store).applyInstallStateForTesting(.paused)
    #expect(stored() == [nil, "paused", "paused", nil])
    Self.runtime(.egOne(.full), defaults: store).applyInstallStateForTesting(.paused)
    #expect(stored() == ["paused", "paused", "paused", nil])
  }

  // MARK: - Saved recordings

  static func snapshot(provider: LLMProvider, size: String?) -> RecordingSettingsSnapshot {
    RecordingSettingsSnapshot(
      backendType: .parakeet, backendSupportsLanguageDetection: false, languageMode: .auto,
      wordCorrectionEnabled: true, fillerRemovalEnabled: true, emojiFormatterEnabled: false,
      spokenPunctuationEnabled: nil, spokenPunctuationStartWords: nil,
      spokenPunctuationEnglishPeriodWord: nil, llmProvider: provider.rawValue,
      llmModel: "the-model", egOneSize: size, s1Control: nil, englishSpelling: nil,
      casualModeEnabled: nil)
  }

  /// The snapshot as a build would have written it: the real encoding, with the one key set
  /// (or removed) by hand.
  static func decoded(provider: LLMProvider, storedSize: String?) throws
    -> RecordingSettingsSnapshot
  {
    let data = try JSONEncoder().encode(snapshot(provider: provider, size: nil))
    var fields = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(fields["egOneSize"] == nil, "a snapshot with no size writes no key")
    if let storedSize { fields["egOneSize"] = storedSize }
    return try JSONDecoder().decode(
      RecordingSettingsSnapshot.self, from: JSONSerialization.data(withJSONObject: fields))
  }

  @Test(
    "a saved recording names its size: none saved means the full size, an unknown one keeps every other setting and names no model"
  )
  func aSavedRecordingNamesItsSize() throws {
    #expect(try Self.decoded(provider: .egOne, storedSize: nil).polishModelID == .egOne(.full))
    #expect(try Self.decoded(provider: .egOne, storedSize: "mini").polishModelID == .egOne(.mini))
    #expect(
      try Self.decoded(provider: .egOne, storedSize: "micro").polishModelID == .egOne(.micro))

    let unknown = try Self.decoded(provider: .egOne, storedSize: "giant")
    #expect(unknown.polishModelID == nil)
    var expected = try JSONSerialization.jsonObject(
      with: JSONEncoder().encode(Self.snapshot(provider: .egOne, size: nil))) as! [String: Any]
    expected["egOneSize"] = "giant"
    let kept = try JSONSerialization.jsonObject(with: JSONEncoder().encode(unknown))
      as! [String: Any]
    #expect(NSDictionary(dictionary: kept) == NSDictionary(dictionary: expected))

    // A size means nothing for a provider that has none.
    #expect(
      try Self.decoded(provider: .s1Mini, storedSize: "mini").polishModelID
        == .singleModel(for: .s1Mini))
    #expect(
      try Self.decoded(provider: .claude, storedSize: nil).polishModelID
        == .singleModel(for: .claude))
    // What a writer stores.
    #expect(LocalPolishModelID.egOne(.micro).storedEGOneSize == "micro")
    #expect(LocalPolishModelID.egOne(.full).storedEGOneSize == "full")
    #expect(LocalPolishModelID.singleModel(for: .s1Mini).storedEGOneSize == nil)
    #expect(
      Self.snapshot(provider: .egOne, size: "mini").polishModelID == .egOne(.mini))
  }

  // MARK: - The polish step

  @Test(
    "a take on another size, or on a size this build does not know, is skipped as not ready and is not polished by the full size"
  )
  func aTakeIsPolishedByItsOwnSizeOrNotAtAll() async throws {
    let rig = LLMPolishStepLanguageHintTests()
    func context() -> TextProcessingContext {
      rig.context(
        text: "we should move the launch to friday", textLanguage: "en", language: "en",
        source: .dictation)
    }
    // The control: the full size's take is polished by the full size's server.
    let full = rig.step(spy: LLMPolishStepTelemetryTests.Spy())
    #expect(full.polishModelID == .egOne(.full))
    _ = try await full.process(context())

    for model in [LocalPolishModelID.egOne(.mini), .egOne(.micro), nil] as [LocalPolishModelID?] {
      let step = rig.step(spy: LLMPolishStepTelemetryTests.Spy())
      step.polishModelID = model
      let error = try await rig.requireThrow { _ = try await step.process(context()) }
      guard case LLMError.localEngineSkipped(.notReady, .egOne) = error else {
        Issue.record("\(String(describing: model)): expected a not-ready skip, got \(error)")
        continue
      }
    }

    // A size with its own server is polished by it, with the full size's server absent.
    let mini = rig.step(spy: LLMPolishStepTelemetryTests.Spy())
    mini.egOneRuntime = nil
    mini.polishModelID = .egOne(.mini)
    mini.localRuntimes[.egOne(.mini)] = LLMPolishStepLanguageHintTests.Runtime()
    _ = try await mini.process(context())

    // Naming the provider again names its one model again: the model is set after it.
    mini.llmProvider = .egOne
    #expect(mini.polishModelID == .egOne(.full))
    mini.llmProvider = .s1Mini
    #expect(mini.polishModelID == .singleModel(for: .s1Mini))
  }
}
