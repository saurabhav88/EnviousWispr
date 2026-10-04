import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprLLM

/// #3142: AI Polish Settings copy that is localized where it is authored keeps its English
/// bytes, checked against independent literals. Unit tests run outside the app bundle, so
/// they always read English.
@Suite("AI Polish copy", .tags(.productOutcome))
struct AIPolishCopyTests {

  private func chip(
    _ provider: LLMProvider,
    selected: Bool = true,
    install: EGOneInstallState = .installed(version: "1"),
    health: EGOneHealth = .green,
    apple: AIAvailabilityStatus? = .available,
    appleChecking: Bool = false,
    cloud: LLMModelDiscoveryCoordinator.KeyValidationState = .valid,
    keySaved: Bool? = true,
    ollama: OllamaSetupState = .ready
  ) -> String? {
    ProviderStatusMapping.status(
      for: provider,
      context: ProviderStatusContext(selected: selected, healthApplies: selected),
      inputs: ProviderStatusInputs(
        egOneInstall: install, egOneHealth: health, s1MiniInstall: install,
        s1MiniHealth: health, appleStatus: apple, appleIsChecking: appleChecking,
        validationProvider: provider, cloudValidation: cloud,
        openAIKeySaved: keySaved, geminiKeySaved: keySaved, claudeKeySaved: keySaved,
        ollamaSetup: ollama)
    )?.label
  }

  @Test("every status chip keeps its English")
  func statusChips() {
    #expect(chip(.none) == "Off")
    #expect(chip(.egOne, install: .notInstalled) == "Not installed")
    #expect(chip(.egOne, install: .paused) == "Download paused")
    #expect(
      chip(.egOne, install: .updatePaused(resumable: true, targetVersion: "2")) == "Update paused")
    #expect(
      chip(.egOne, install: .downloading(fractionCompleted: 0.1, upgrade: nil)) == "Downloading")
    #expect(
      chip(.egOne, install: .downloading(fractionCompleted: 0.1, upgrade: .named("2")))
        == "Upgrading")
    #expect(chip(.egOne, install: .verifying) == "Verifying")
    #expect(chip(.egOne, install: .failed(.network)) == "Needs attention")
    #expect(chip(.egOne, health: .green) == "Installed")
    #expect(chip(.egOne, health: .yellow(reason: "starting")) == "Starting")
    #expect(chip(.egOne, health: .red(reason: "crashed_twice")) == "Not working")
    #expect(chip(.appleIntelligence, apple: .available) == "Available")
    #expect(chip(.appleIntelligence, apple: .degraded) == "Degraded")
    #expect(chip(.appleIntelligence, apple: .unavailable) == "Unavailable")
    #expect(chip(.appleIntelligence, apple: .unknown) == "Unknown")
    #expect(chip(.appleIntelligence, apple: nil) == "Not checked")
    #expect(chip(.appleIntelligence, appleChecking: true) == "Checking")
    #expect(chip(.openAI, cloud: .idle) == "Not checked")
    #expect(chip(.openAI, keySaved: false) == "Key needed")
    #expect(chip(.openAI, keySaved: nil) == "Could not check")
    #expect(chip(.openAI, selected: false) == "Key saved")
    #expect(chip(.openAI, cloud: .validating) == "Checking")
    #expect(chip(.openAI, cloud: .valid) == "Key valid")
    #expect(chip(.openAI, cloud: .invalid("x")) == "Check failed")
    #expect(chip(.ollama, ollama: .detecting) == "Checking")
    #expect(chip(.ollama, ollama: .notInstalled) == "Not installed")
    #expect(chip(.ollama, ollama: .installedNotRunning) == "Not running")
    #expect(chip(.ollama, ollama: .runningNoModels) == "No model")
    #expect(chip(.ollama, ollama: .pullingModel(progress: 0, status: "")) == "Downloading")
    #expect(chip(.ollama, ollama: .ready) == "Installed")
    #expect(chip(.ollama, ollama: .error("x")) == "Error")
  }

  @Test("the provider groups keep their headings and spoken phrases")
  func railGroups() {
    #expect(PolishRailGroup.allCases.map(\.heading) == ["On this Mac", "Your own setup", "Cloud"])
    #expect(
      PolishRailGroup.allCases.map(\.accessibilityPhrase) == [
        "on this Mac", "your own setup", "cloud",
      ])
  }

  @Test("the provider card keeps each provider's line, and S1-mini's credits Superwhisper")
  func cardLines() {
    #expect(
      PolishRailCatalog.all.map(\.short) == [
        "Our model for cleaning up dictation on this Mac.",
        "Small model by Superwhisper, on this Mac and happiest in English.",
        "On-device polish on supported Macs with macOS 26+.",
        "Your models, local or hosted.",
        "Use your OpenAI API key for cloud polish.",
        "Use your Gemini API key for cloud polish.",
        "Use your Claude API key for cloud polish.",
      ])
    #expect(SettingsCopy.frozenPerRecording == "Changes apply to the next recording")
  }

  @Test("the S1-mini writing-style rows keep every sentence and option name")
  func writingStyleCard() {
    #expect(
      S1ControlCopy.fileImportIntro
        == "Superwhisper trained S1-mini on these three settings. They are shared with dictation. Change them any time; a new pick applies to your next file and your next dictation."
    )
    #expect(S1ControlCopy.stylingLabel == "Tone")
    #expect(S1ControlCopy.stylingShort == "Choose how formal your text sounds.")
    #expect(S1ControlCopy.structureLabel == "Structure")
    #expect(S1ControlCopy.structureShort == "Keep sentences or turn spoken items into lists.")
    #expect(S1ControlCopy.contextLabel == "Context")
    #expect(S1ControlCopy.contextShort == "Format dictated greetings and sign-offs as email.")
    #expect(
      S1Styling.allCases.map(S1ControlCopy.label(for:)) == [
        "Casual", "Semi-casual", "Semi-formal", "Formal",
      ])
    #expect(S1Structure.allCases.map(S1ControlCopy.label(for:)) == ["Prose", "Lists"])
    #expect(S1Context.allCases.map(S1ControlCopy.label(for:)) == ["General", "Email"])
  }

  @Test("the Download more models count says how many local models are on this Mac")
  func installedCount() {
    func entry(_ name: String, downloaded: Bool, remote: Bool = false) -> OllamaModelCatalogEntry {
      OllamaModelCatalogEntry(
        name: name, displayName: name, parameterCount: "", downloadSize: "",
        isDownloaded: downloaded, isRemote: remote)
    }
    let catalog = [
      entry("a", downloaded: true), entry("b", downloaded: false), entry("c", downloaded: true),
      entry("h", downloaded: true, remote: true),
    ]
    let counts = OllamaCatalogPresentation.installedCount(from: catalog)
    #expect(counts.installed == 2)
    #expect(counts.total == 3)
    #expect(
      OllamaCatalogPresentation.installedCountText(installed: 2, total: 3)
        == "2 of 3 installed on this Mac")
  }

  @Test("each paused-upgrade row is one whole sentence, named or not")
  func pausedUpgradeSentences() {
    func message(_ resumable: Bool, _ version: String?) -> String {
      EGOneRowPresentation.forState(
        .updatePaused(resumable: resumable, targetVersion: version), engine: "EG-1"
      ).message
    }
    #expect(
      message(true, "2.0") == "AI cleanup is paused. Your upgrade to EG-1 V2.0 stopped part-way.")
    #expect(
      message(true, nil) == "AI cleanup is paused. Your upgrade to the new EG-1 stopped part-way.")
    #expect(message(false, "2.0") == "AI cleanup is paused until EG-1 V2.0 finishes installing.")
    #expect(message(false, nil) == "AI cleanup is paused until the new EG-1 finishes installing.")
  }

  @Test("the download line names a first install, a named upgrade and an unnamed one")
  func downloadingLines() {
    func line(_ upgrade: EGOneUpgradeContext?) -> String {
      EGOneRowPresentation.downloadingLine(engine: "EG-1", upgrade: upgrade, downloadSize: "2.9 GB")
    }
    #expect(line(nil) == "Downloading EG-1 (2.9 GB)")
    #expect(line(.named("1.1")) == "Upgrading to EG-1 V1.1 (2.9 GB)")
    #expect(line(.unnamed) == "Upgrading to the new EG-1 (2.9 GB)")
  }

  @Test("every local-model row button keeps its English")
  func rowButtons() {
    func action(_ state: EGOneInstallState) -> String? {
      EGOneRowPresentation.forState(state, engine: "EG-1").primaryAction
    }
    #expect(action(.notInstalled) == "Download EG-1")
    #expect(action(.paused) == "Resume")
    #expect(action(.updatePaused(resumable: true, targetVersion: "2")) == "Resume upgrade")
    #expect(action(.updatePaused(resumable: false, targetVersion: "2")) == "Finish upgrade")
    #expect(action(.downloading(fractionCompleted: 0.1, upgrade: nil)) == "Cancel")
    #expect(
      EGOneRowPresentation.forState(.paused, engine: "EG-1").message
        == "Download paused. Resume anytime.")
  }

  @Test("every health reason line keeps its English")
  func healthReasons() {
    let yellow: [(String, String)] = [
      ("starting", "The model is starting up. This takes a few seconds."),
      (
        "paused_for_memory",
        "Paused to free memory for other apps. Use the refresh button to restart it."
      ),
      ("probe_slow", "Working, but responding slowly right now."),
      (
        "probe_output_unexpected",
        "The model responded, but not as expected. Try re-downloading it."
      ),
      ("not_started", "Starting the model. This takes a few seconds."),
      ("download_paused", "Download paused. Resume anytime."),
      ("something_new", "Something needs attention. Try the refresh button."),
    ]
    for (reason, expected) in yellow {
      #expect(LocalEngineHealthCopy.detail(for: .yellow(reason: reason)) == expected)
    }
    let red: [(String, String)] = [
      ("download_required", "Download the model to get started."),
      ("update_required", "This model needs a newer version of EnviousWispr."),
      ("crashed_twice", "The model stopped twice in a row. Use the refresh button to try again."),
      ("not_running", "Not running. Use the refresh button to start it."),
      (
        "probe_failed",
        "The model did not answer a test request. Use the refresh button to try again."
      ),
      ("something_new", "Not running. Use the refresh button to try again."),
    ]
    for (reason, expected) in red {
      #expect(LocalEngineHealthCopy.detail(for: .red(reason: reason)) == expected)
    }
  }

  @Test("the Ollama list keeps its headings, buttons and progress wording")
  func ollamaList() {
    #expect(OllamaCatalogPresentation.hostedGroupTitle == "Runs on Ollama's servers")
    #expect(OllamaCatalogPresentation.freeVerifiedGroupTitle == "Try these first")
    #expect(OllamaCatalogPresentation.mayNeedPaidGroupTitle == "May need a paid Ollama plan")
    let local = OllamaModelCatalogEntry(
      name: "m", displayName: "M", parameterCount: "1B", downloadSize: "1 GB", isDownloaded: false)
    let hosted = OllamaModelCatalogEntry(
      name: "h", displayName: "H", parameterCount: "", downloadSize: "", isDownloaded: false,
      isRemote: true)
    #expect(OllamaCatalogPresentation.actionLabel(for: local) == "Download")
    #expect(OllamaCatalogPresentation.actionLabel(for: hosted) == "Add")
    #expect(OllamaCatalogPresentation.progressLabel(for: local, percent: 42) == "Downloading… 42%")
    #expect(OllamaCatalogPresentation.progressLabel(for: hosted, percent: 42) == "Adding…")
    #expect(OllamaSetupService.formatFileSize(0) == "Unknown")
    // #3142: the decimal follows the user's REGION, as macOS formats numbers (measured: a German
    // interface on a US-region Mac is de_US and keeps "."). English is unchanged.
    let fourPointSevenGB: Int64 = 5_046_586_573  // 4.7 GiB
    #expect(OllamaSetupService.formatFileSize(fourPointSevenGB, locale: Locale(identifier: "en_US")) == "4.7 GB")
    #expect(OllamaSetupService.formatFileSize(fourPointSevenGB, locale: Locale(identifier: "de_DE")) == "4,7 GB")
    #expect(OllamaSetupService.formatFileSize(fourPointSevenGB, locale: Locale(identifier: "de_US")) == "4.7 GB")
  }

  /// #3142: the two cases converted in Chunk 7 have translated display copy with the same
  /// English, while the description logs read stays fixed English.
  @Test("Model errors converted for screens keep their English, and diagnostics do not move")
  func llmErrorDisplayCopy() {
    #expect(LLMError.emptyResponse.localizedDisplayMessage == "LLM returned an empty response.")
    #expect(
      LLMError.requestFailed("HTTP 500").localizedDisplayMessage
        == "LLM request failed: HTTP 500")
    #expect(LLMError.emptyResponse.errorDescription == "LLM returned an empty response.")
    #expect(LLMError.requestFailed("HTTP 500").errorDescription == "LLM request failed: HTTP 500")
    // The other cases here have no proven screen path for their descriptions.
    #expect(LLMError.invalidAPIKey.localizedDisplayMessage == nil)
    #expect(LLMError.rateLimited.localizedDisplayMessage == nil)
    // #3142: the on-device model's reason is typed, translated on screen, English in logs.
    #expect(
      LLMError.modelNotReady(.downloadingOrRestricted).localizedDisplayMessage
        == "The on-device model is not ready. It may still be downloading or restricted by your organization. Try again later or use a different provider."
    )
    #expect(
      LLMError.modelNotReady(.downloadingOrRestricted).errorDescription
        == "The on-device model is not ready. It may still be downloading or restricted by your organization. Try again later or use a different provider."
    )
  }

  @Test("The key check shows a model error's display copy, and any other error's description")
  @MainActor
  func keyCheckFailureMessage() {
    #expect(
      LLMModelDiscoveryCoordinator.validationFailureMessage(
        for: LLMError.requestFailed("Network error: offline"))
        == "LLM request failed: Network error: offline")
    let other = NSError(
      domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Something else."])
    #expect(LLMModelDiscoveryCoordinator.validationFailureMessage(for: other) == "Something else.")
  }

  /// #3142: failures the app describes itself during model discovery. The diagnostic is the
  /// exact English the key check showed before; the screen reads the translated sentence.
  @Test("discovery failures keep their English, and the key check shows them")
  @MainActor
  func discoveryFailures() {
    let english: [(ModelDiscoveryFailure, String)] = [
      (.invalidURL, "LLM request failed: Invalid URL"),
      (.invalidResponse, "LLM request failed: Invalid response"),
      (.httpStatus(500), "LLM request failed: HTTP 500"),
      (.httpStatus(1000), "LLM request failed: HTTP 1000"),
      (
        .malformedPagination,
        "LLM request failed: Claude model pagination returned a malformed cursor"
      ),
      (.invalidOllamaURL, "LLM request failed: Invalid Ollama URL"),
      (
        .network("The Internet connection appears to be offline."),
        "LLM request failed: Network error: The Internet connection appears to be offline."
      ),
    ]
    for (failure, text) in english {
      #expect(failure.errorDescription == text, "\(failure)")
      #expect(failure.displayMessage == text, "\(failure)")
      #expect(LLMModelDiscoveryCoordinator.validationFailureMessage(for: failure) == text)
    }
  }

  /// The Apple Intelligence row is recomputed from a local check with its typed status, and its
  /// stored name keeps the English it always had.
  @Test("the Apple Intelligence row carries its status and its English name")
  func appleIntelligenceRow() {
    let rows = LLMModelDiscovery.appleIntelligenceModelInfo()
    #expect(rows.count == 1)
    let row = rows[0]
    #expect(row.id == "apple-intelligence")
    let status = row.appleIntelligenceStatus
    #expect(status != nil)
    if let status {
      #expect(row.displayName == LLMModelDiscovery.englishAppleIntelligenceLabel(status))
      #expect(row.localizedDisplayName == status.displayName)
      #expect(row.isAvailable == (status == .onDevice))
    }
    // Every status's stored English name equals its catalog default, so the data and the label
    // cannot drift apart for the statuses this Mac does not produce.
    for status in AppleIntelligenceModelStatus.allCases {
      let candidate = LLMModelDiscovery.appleIntelligenceRow(
        status, isAvailable: status == .onDevice)
      #expect(candidate.displayName == status.displayName, "\(status)")
    }
  }
}
