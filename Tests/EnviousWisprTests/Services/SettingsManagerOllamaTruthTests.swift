import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// #1305: settings truth for the Ollama model fields. The picker's `llmModel`
/// may never be armed to a model the installed list does not contain — empty
/// discovery clears it (was: refilled the remembered phantom, the #1305 root
/// cause), launch-time canonicalization leaves "" alone, and the remembered
/// `ollamaModel` preference survives both (it powers the Download-suggestion
/// copy).
@MainActor
@Suite("SettingsManager Ollama model truth (#1305)")
struct SettingsManagerOllamaTruthTests {

  private func freshSettings(seed: ((UserDefaults) -> Void)? = nil) -> SettingsManager {
    let suite = UserDefaults(suiteName: "SM-1305-\(UUID().uuidString)")!
    seed?(suite)
    return SettingsManager(defaults: suite)
  }

  private func model(
    _ id: String, available: Bool = true, isRemote: Bool = false
  ) -> LLMModelInfo {
    LLMModelInfo(
      id: id, displayName: id, provider: .ollama, isAvailable: available, isRemote: isRemote)
  }

  // MARK: - Empty discovery (the root-cause fix)

  @Test("ollama empty discovery clears llmModel and preserves ollamaModel")
  func emptyDiscoveryClears() {
    let settings = freshSettings()
    settings.llmProvider = .ollama
    settings.llmModel = "llama2:latest"  // the Baltimore phantom
    settings.ollamaModel = "llama2:latest"

    settings.applyDiscoveredModels([], for: .ollama)

    #expect(settings.llmModel == "")
    // The remembered preference stays — it drives the Download-button copy.
    #expect(settings.ollamaModel == "llama2:latest")
  }

  @Test("cloud empty discovery keeps the provider default (unchanged behavior)")
  func cloudEmptyDiscoveryKeepsDefault() {
    let settings = freshSettings()
    settings.llmProvider = .openAI

    settings.applyDiscoveredModels([], for: .openAI)

    #expect(settings.llmModel == LLMProvider.defaultModel(for: .openAI))
    #expect(!settings.llmModel.isEmpty)
  }

  @Test("stale empty discovery for a switched-away provider is dropped")
  func staleEmptyDiscoveryDropped() {
    let settings = freshSettings()
    settings.llmProvider = .openAI
    let before = settings.llmModel

    settings.applyDiscoveredModels([], for: .ollama)

    #expect(settings.llmModel == before)
  }

  // MARK: - Armed-model-deleted, others remain (characterization of :754-758)

  @Test("armed model missing from discovery auto-selects the first available and mirrors it")
  func armedMissingAutoSelectsFirst() {
    let settings = freshSettings()
    settings.llmProvider = .ollama
    settings.llmModel = "deleted-model"
    settings.ollamaModel = "deleted-model"

    settings.applyDiscoveredModels([model("mistral"), model("phi3")], for: .ollama)

    #expect(settings.llmModel == "mistral")
    #expect(settings.ollamaModel == "mistral")
  }

  // MARK: - Never auto-arm a hosted model (#1914, founder decision 2026-08-04)

  /// The defect this closes. `applyDiscoveredModels` is the only site in the app
  /// that can arm a model the user never chose, and its fallback used to be
  /// plain first-available. With a hosted model pulled and the armed local one
  /// deleted, that silently moved the user's dictation off their Mac.
  @Test("a remote-only discovery arms NOTHING rather than a hosted model")
  func remoteOnlyArmsNothing() {
    let settings = freshSettings()
    settings.llmProvider = .ollama
    settings.llmModel = "deleted-model"
    settings.ollamaModel = "deleted-model"

    settings.applyDiscoveredModels(
      [
        model("gpt-oss:120b-cloud", isRemote: true),
        model("deepseek-v3.1:671b-cloud", isRemote: true),
      ],
      for: .ollama)

    #expect(settings.llmModel == "")
    // BOTH fields, because the runtime reads `ollamaModel`, not `llmModel`.
    // Clearing only the picker field would leave the refusal cosmetic while
    // dictation still went to the hosted model.
    #expect(settings.ollamaModel == "")
    #expect(settings.effectiveLLMModel == "", "the runtime must genuinely be armed to nothing")
  }

  /// PR #1949 cloud review. Switching provider away from Ollama and back must
  /// not throw away a deliberately chosen HOSTED model.
  ///
  /// The mechanism: `effectiveLLMModel` reads `ollamaModel` for this provider,
  /// but `canonicalizeLLMModelForProvider` deliberately does not refill
  /// `llmModel` from it (#1305). So after a round trip through OpenAI,
  /// `llmModel` holds an OpenAI id while `ollamaModel` still holds the user's
  /// hosted pick. Judging armed-ness by `llmModel` made that pick look unarmed,
  /// and the repair branch — which excludes hosted rows on purpose — then
  /// replaced it with a local model.
  ///
  /// This is the founder's "existing selections are LEFT ALONE" decision, which
  /// the repair branch documents in its own comment, being violated by that
  /// same branch.
  @Test("a remembered hosted pick survives a round trip through another provider")
  func rememberedHostedSelectionSurvivesProviderRoundTrip() {
    let settings = freshSettings()
    settings.llmProvider = .ollama
    settings.llmModel = "gemma4:31b-cloud"
    settings.ollamaModel = "gemma4:31b-cloud"

    // Away to OpenAI, which canonicalizes `llmModel` to an OpenAI id and leaves
    // `ollamaModel` alone, then back.
    settings.llmProvider = .openAI
    settings.llmProvider = .ollama
    #expect(
      settings.ollamaModel == "gemma4:31b-cloud",
      "precondition: the round trip itself must not clear the remembered pick")

    settings.applyDiscoveredModels(
      [
        model("gemma4:31b-cloud", isRemote: true),
        model("llama3.2", isRemote: false),
      ],
      for: .ollama)

    #expect(
      settings.ollamaModel == "gemma4:31b-cloud",
      "the deliberate hosted pick is the armed model and must be preserved")
    #expect(
      settings.effectiveLLMModel == "gemma4:31b-cloud",
      "the runtime must still be armed to the user's choice")
    #expect(
      settings.llmModel == "gemma4:31b-cloud",
      "the picker binds llmModel, so it must show the model the runtime will use")
  }

  /// The control that keeps the test above from passing vacuously: a hosted
  /// model that is genuinely GONE from discovery must still be repaired away,
  /// and the replacement must still be local. Without this, an implementation
  /// that simply never repaired Ollama would pass.
  @Test("a hosted pick that vanished from discovery is still repaired to a local model")
  func vanishedHostedPickIsStillRepaired() {
    let settings = freshSettings()
    settings.llmProvider = .ollama
    settings.llmModel = "gemma4:31b-cloud"
    settings.ollamaModel = "gemma4:31b-cloud"

    settings.applyDiscoveredModels([model("llama3.2", isRemote: false)], for: .ollama)

    #expect(settings.ollamaModel == "llama3.2")
    #expect(settings.effectiveLLMModel == "llama3.2")
  }

  /// The two-way control. Without it, an implementation that cleared both
  /// fields unconditionally would pass the test above while disabling Ollama
  /// polish entirely.
  @Test("a local model is still auto-selected when one is available")
  func localStillAutoSelected() {
    let settings = freshSettings()
    settings.llmProvider = .ollama
    settings.llmModel = "deleted-model"
    settings.ollamaModel = "deleted-model"

    settings.applyDiscoveredModels([model("mistral")], for: .ollama)

    #expect(settings.llmModel == "mistral")
    #expect(settings.ollamaModel == "mistral")
    #expect(settings.effectiveLLMModel == "mistral")
  }

  /// Order independence. A first-available pick over the raw list would pass
  /// whenever the local model happened to sort first, so the local model is
  /// placed LAST here on purpose.
  @Test("a local model wins even when hosted models sort ahead of it")
  func localWinsRegardlessOfOrder() {
    let settings = freshSettings()
    settings.llmProvider = .ollama
    settings.llmModel = "deleted-model"
    settings.ollamaModel = "deleted-model"

    settings.applyDiscoveredModels(
      [
        model("aaa-cloud", isRemote: true),
        model("bbb-cloud", isRemote: true),
        model("zzz-local"),
      ], for: .ollama)

    #expect(settings.llmModel == "zzz-local")
    #expect(settings.ollamaModel == "zzz-local")
  }

  /// The preferred-default branch has its own candidate search, so it needs its
  /// own guard. `defaultModel(for: .ollama, ollamaModel:)` returns the
  /// remembered name, so a remembered HOSTED model is exactly the input that
  /// would sail through a fix applied only to the plain fallback.
  ///
  /// RE-AIMED, not weakened (PR #1949 cloud review + founder decision
  /// 2026-08-05). This test used to seed a remembered hosted model that WAS
  /// present in discovery and assert the repair replaced it with a local one.
  /// That asserted the defect the review found: a model the user picked being
  /// undone by the repair. Founder ruling, verbatim: "If a user selects a model
  /// -> that is the model they want to use -> swapping to a different ai
  /// polishing provider should not 'undo' their selection in Ollama."
  ///
  /// The branch under test is unchanged and still needs its guard, so the setup
  /// now describes the state where the repair legitimately RUNS: the remembered
  /// hosted model is GONE from discovery, so nothing is armed, and the
  /// candidate search must still refuse the hosted row that remains.
  @Test("a hosted preferred-default never wins over an available local model")
  func hostedPreferredDefaultLosesToLocal() {
    let settings = freshSettings()
    settings.llmProvider = .ollama
    settings.llmModel = "deleted-model"
    // The remembered preference IS a hosted model, so it is the preferred
    // default candidate on this pass — and it is NOT in discovery below, so the
    // repair genuinely runs instead of preserving an armed selection.
    settings.ollamaModel = "gpt-oss:120b-cloud"

    settings.applyDiscoveredModels(
      [model("nemotron-3-super:cloud", isRemote: true), model("mistral")], for: .ollama)

    #expect(settings.llmModel == "mistral")
    #expect(settings.ollamaModel == "mistral")
  }

  /// An already-armed hosted model stays armed while it is available.
  ///
  /// This asserts PRESERVATION, not that the user chose it. The stored fields
  /// record no provenance, so the selection may have come from a manual pick or
  /// from the pre-#1914 automatic fallback, whose result is byte-identical.
  ///
  /// Founder decision 2026-08-04: preservation is the shipped behaviour and no
  /// migration clears existing selections. So this expectation is final, not
  /// provisional — see the decision note in `applyDiscoveredModels` for the
  /// reasoning and for the condition that would reopen it.
  @Test("an already armed available hosted model is left alone")
  func armedHostedModelSurvives() {
    let settings = freshSettings()
    settings.llmProvider = .ollama
    settings.llmModel = "gpt-oss:120b-cloud"
    settings.ollamaModel = "gpt-oss:120b-cloud"

    settings.applyDiscoveredModels(
      [model("gpt-oss:120b-cloud", isRemote: true), model("mistral")], for: .ollama)

    #expect(settings.llmModel == "gpt-oss:120b-cloud")
    #expect(settings.ollamaModel == "gpt-oss:120b-cloud")
    #expect(settings.effectiveLLMModel == "gpt-oss:120b-cloud")
  }

  /// Availability still gates the local pool: an unavailable local model is not
  /// a usable answer, so a list of one unavailable local plus hosted models
  /// must still arm nothing.
  @Test("an UNAVAILABLE local model does not rescue a remote-only list")
  func unavailableLocalIsNotSelected() {
    let settings = freshSettings()
    settings.llmProvider = .ollama
    settings.llmModel = "deleted-model"
    settings.ollamaModel = "deleted-model"

    settings.applyDiscoveredModels(
      [model("broken-local", available: false), model("gpt-oss:120b-cloud", isRemote: true)],
      for: .ollama)

    #expect(settings.llmModel == "")
    #expect(settings.ollamaModel == "")
  }

  /// The refusal is scoped to Ollama. Remoteness is an Ollama-daemon fact and
  /// means nothing for a cloud provider, whose models are all "remote" in the
  /// ordinary sense — filtering them out would disable cloud polish entirely.
  @Test("cloud auto-selection is unaffected by remoteness")
  func cloudAutoSelectionUnaffected() {
    for provider in [LLMProvider.openAI, .gemini, .claude] {
      let settings = freshSettings()
      settings.llmProvider = provider
      settings.llmModel = "deleted-model"

      settings.applyDiscoveredModels(
        [
          LLMModelInfo(
            id: "some-model", displayName: "S", provider: provider, isAvailable: true,
            isRemote: true)
        ], for: provider)

      #expect(settings.llmModel == "some-model", "\(provider) must still auto-select")
    }
  }

  @Test("an armed model present in discovery is left alone")
  func armedPresentUntouched() {
    let settings = freshSettings()
    settings.llmProvider = .ollama
    settings.llmModel = "phi3"
    settings.ollamaModel = "phi3"

    settings.applyDiscoveredModels([model("mistral"), model("phi3")], for: .ollama)

    #expect(settings.llmModel == "phi3")
    #expect(settings.ollamaModel == "phi3")
  }

  // MARK: - Launch-time canonicalization

  @Test("a persisted empty llmModel stays empty at launch under ollama")
  func persistedEmptyStaysEmpty() {
    let settings = freshSettings { suite in
      suite.set("ollama", forKey: "llmProvider")
      suite.set("", forKey: "llmModel")
      suite.set("llama3.2", forKey: "ollamaModel")
    }

    // Pre-#1305, init's canonicalize pass refilled "" from ollamaModel,
    // silently re-arming the phantom the last discovery pass had cleared.
    #expect(settings.llmProvider == .ollama)
    #expect(settings.llmModel == "")
    #expect(settings.ollamaModel == "llama3.2")
  }

  @Test("a persisted fixed literal is still swept at launch under ollama")
  func fixedLiteralStillSwept() {
    let settings = freshSettings { suite in
      suite.set("ollama", forKey: "llmProvider")
      suite.set("apple-intelligence", forKey: "llmModel")
      suite.set("llama3.2", forKey: "ollamaModel")
    }

    // The fixed-literal sweep (#1271 r7) must survive the empty-stays-empty
    // change: an AFM literal leaking into the ollama slot is still repaired
    // from the remembered preference.
    #expect(settings.llmModel == "llama3.2")
  }

  @Test("cloud providers still refill an empty llmModel at launch (unchanged)")
  func cloudEmptyRefilledAtLaunch() {
    let settings = freshSettings { suite in
      suite.set("openAI", forKey: "llmProvider")
      suite.set("", forKey: "llmModel")
    }

    #expect(settings.llmModel == LLMProvider.defaultModel(for: .openAI))
  }

  // MARK: - Cross-cloud-provider model bleed (#158, Codex r4)

  @Test("a live provider switch away from a cloud provider sweeps that provider's model id")
  func liveSwitchSweepsForeignCloudModel() {
    let settings = freshSettings()
    settings.llmProvider = .openAI
    settings.llmModel = "gpt-4o"

    settings.llmProvider = .claude

    // Without the sweep, "gpt-4o" would survive the switch unchanged and
    // every Claude prewarm/polish request would fail until async discovery
    // happens to repair it (or persist broken across relaunches if
    // discovery never runs, e.g. offline or no key saved yet).
    #expect(settings.llmModel == LLMProvider.defaultModel(for: .claude))
  }

  @Test("a persisted foreign-cloud model id is swept at launch too")
  func launchSweepsForeignCloudModel() {
    let settings = freshSettings { suite in
      suite.set("claude", forKey: "llmProvider")
      suite.set("gemini-2.0-flash", forKey: "llmModel")
    }

    #expect(settings.llmModel == LLMProvider.defaultModel(for: .claude))
  }

  // MARK: - Retired-model sweep (#1770)

  /// Google shut down `gemini-2.0-flash` on 2026-06-01. It is a well-formed
  /// Gemini id, so the foreign-provider check waves it through and a pinned
  /// user 404s on every dictation forever — discovery does not run at launch,
  /// and opening AI Polish settings only loads cached rows.
  @Test("a persisted RETIRED model id is swept at launch")
  func launchSweepsRetiredModel() {
    let settings = freshSettings { suite in
      suite.set("gemini", forKey: "llmProvider")
      suite.set("gemini-2.0-flash", forKey: "llmModel")
    }

    #expect(settings.llmModel == LLMProvider.defaultModel(for: .gemini))
  }

  /// The direction that protects user choice. This sweep rewrites a persisted
  /// setting, so it must touch ONLY ids the provider actually withdrew — a
  /// predicate that caught legitimate models would silently override what the
  /// user picked, which is far worse than the bug it fixes.
  @Test("a persisted LIVE model id is NOT swept")
  func launchPreservesLiveModel() {
    for live in ["gemini-3.6-flash", "gemini-2.5-pro", "gemini-3.1-flash-lite"] {
      let settings = freshSettings { suite in
        suite.set("gemini", forKey: "llmProvider")
        suite.set(live, forKey: "llmModel")
      }
      #expect(settings.llmModel == live, "\(live) is live and must survive the sweep untouched")
    }
  }

  /// The sweep runs during initialization, and this file persists
  /// initialization-time values by write-through rather than relying on the
  /// `didSet` observer. Without that, the repair would be forgotten on quit.
  @Test("the swept value survives a reload")
  func sweptValuePersistsAcrossReload() {
    let suiteName = "ew-tests-\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: suiteName)!
    suite.set("gemini", forKey: "llmProvider")
    suite.set("gemini-2.0-flash", forKey: "llmModel")

    _ = SettingsManager(defaults: suite)
    let reloaded = SettingsManager(defaults: suite)

    #expect(reloaded.llmModel == LLMProvider.defaultModel(for: .gemini))
    suite.removePersistentDomain(forName: suiteName)
  }

  @Test("turning polish off preserves the selected model (#158 Codex r5 P1 claim, verified false)")
  func polishOffPreservesSelectedModel() {
    let settings = freshSettings()
    settings.llmProvider = .claude
    settings.llmModel = "claude-opus-4-8"

    // `.none` is the "polish off" state (#1285). `modelIDLooksLikeCloudProvider`
    // returns true for `.none` specifically so this arm's sweep condition
    // never fires for it -- a real cloud model must survive polish being
    // turned off, or turning it back on would silently lose the user's pick.
    settings.llmProvider = .none

    #expect(settings.llmModel == "claude-opus-4-8")
  }

  @Test("a model id that already belongs to the currently selected cloud provider is left alone")
  func ownProviderModelSurvivesCanonicalization() {
    let settings = freshSettings()
    settings.llmProvider = .claude
    settings.llmModel = "claude-opus-4-8"

    // Re-selecting the SAME provider (the didSet still fires, still
    // re-canonicalizes) must not disturb a model id that already belongs
    // to it -- this is a user's real, deliberately picked non-default
    // model, not a stale foreign one the sweep should touch.
    settings.llmProvider = .claude

    #expect(settings.llmModel == "claude-opus-4-8")
  }
}
