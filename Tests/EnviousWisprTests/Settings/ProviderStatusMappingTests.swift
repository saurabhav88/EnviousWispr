import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprLLM

/// Issue #1286 Phase 2 — locks the single at-a-glance status authority
/// `ProviderStatusMapping.status`. Two contracts:
///   1. Each engine maps its OWN coordinator states to the right (label, tone).
///   2. Provider-first, no cross-provider leak: a coordinator state that is
///      "blocking" for one engine must not change another engine's result
///      (a cloud key state never reaches the EG-1/Apple/Ollama branch, etc.).
@Suite("ProviderStatusMapping — one status authority, no cross-provider leak", .tags(.productOutcome))
struct ProviderStatusMappingTests {

  // Neutral "everything nominal" inputs for the engines NOT under test, so a
  // per-engine assertion isolates the one coordinator that should matter. Defaults describe
  // the provider as the CHOSEN one with its verdict about it; the unselected tests below say so.
  private func status(
    for provider: LLMProvider,
    selected: Bool = true,
    egOneInstall: EGOneInstallState = .installed(version: "1"),
    egOneHealth: EGOneHealth = .green,
    s1MiniInstall: EGOneInstallState = .installed(version: "1"),
    s1MiniHealth: EGOneHealth = .green,
    appleStatus: AIAvailabilityStatus? = .available,
    appleIsChecking: Bool = false,
    validationProvider: LLMProvider? = nil,
    cloudValidation: LLMModelDiscoveryCoordinator.KeyValidationState = .valid,
    cloudKeySaved: Bool? = true,
    ollamaSetup: OllamaSetupState = .ready
  ) -> ProviderStatus? {
    ProviderStatusMapping.status(
      for: provider,
      context: ProviderStatusContext(selected: selected, healthApplies: selected),
      facts: PolishSetupFacts(
        egOneInstall: egOneInstall, egOneHealth: egOneHealth,
        s1MiniInstall: s1MiniInstall, s1MiniHealth: s1MiniHealth,
        appleStatus: appleStatus, appleFailureReasons: [], appleIsChecking: appleIsChecking,
        validationProvider: validationProvider ?? provider,
        cloudValidation: cloudValidation, credentialRevisions: [:], cloudVerdicts: [:],
        openAIKeySaved: cloudKeySaved, geminiKeySaved: cloudKeySaved,
        claudeKeySaved: cloudKeySaved,
        ollamaSetup: ollamaSetup, ollamaModel: .installed))
  }

  // MARK: - S1-mini (#2649: same renderer as EG-1, separate state)

  /// S1-mini and EG-1 share `localServer`, so the rows that matter are the ones
  /// proving they do NOT share state. A single-engine assertion cannot tell a
  /// correct arm from one reading its neighbour's coordinator.
  @Test("S1-mini not installed → Not installed / neutral")
  func s1MiniNotInstalled() {
    let s = status(for: .s1Mini, s1MiniInstall: .notInstalled)
    #expect(s?.label == "Not installed")
    #expect(s?.tone == .unavailable)
  }

  @Test("S1-mini reads its own state, never EG-1's")
  func s1MiniDoesNotReadEGOneState() {
    // EG-1 broken, S1-mini fine: S1-mini must still be fine.
    let healthy = status(
      for: .s1Mini, egOneInstall: .notInstalled, egOneHealth: .red(reason: "eg1 down"),
      s1MiniInstall: .installed(version: "1"), s1MiniHealth: .green)
    #expect(healthy?.tone == .ready)

    // And the reverse, so neither direction can leak.
    let egOneHealthy = status(
      for: .egOne, egOneInstall: .installed(version: "1"), egOneHealth: .green,
      s1MiniInstall: .notInstalled, s1MiniHealth: .red(reason: "s1 down"))
    #expect(egOneHealthy?.tone == .ready)
  }

  @Test("S1-mini installed but unhealthy is not reported as ready")
  func s1MiniUnhealthy() {
    let s = status(
      for: .s1Mini, s1MiniInstall: .installed(version: "1"),
      s1MiniHealth: .red(reason: "server down"))
    #expect(s?.tone != .ready)
  }

  // MARK: - EG-1 (install lifecycle first, health once installed)

  @Test("EG-1 not installed → Not installed / neutral")
  func egOneNotInstalled() {
    let s = status(for: .egOne, egOneInstall: .notInstalled)
    #expect(s?.label == "Not installed")
    #expect(s?.tone == .unavailable)
  }

  // MARK: - Paused states (#2109)

  /// An interrupted FIRST install. The user chose to stop and their progress
  /// is kept, so the chip must read as setup-pending, never as an error —
  /// this used to arrive here as `.failed` and paint the error tone.
  @Test("EG-1 paused → Download paused / needs-setup")
  func egOnePaused() {
    let s = status(for: .egOne, egOneInstall: .paused)
    #expect(s?.label == "Download paused")
    #expect(s?.tone == .needsSetup)
  }

  /// A working older revision is on disk but the pinned one is not, so AI
  /// cleanup is genuinely OFF. The chip must agree with the detailed row
  /// rather than reassure: a calm chip beside an alarmed row is worse than
  /// either alone, because it teaches the user to distrust the screen. This is
  /// the silently-off state #2109 exists to surface.
  @Test(arguments: [true, false])
  func egOneUpdatePausedReadsAsNeedingAttention(_ resumable: Bool) {
    let s = status(
      for: .egOne, egOneInstall: .updatePaused(resumable: resumable, targetVersion: "1.1"))
    #expect(s?.label == "Update paused")
    #expect(s?.tone == .error)
  }

  // MARK: - Rail and row agreement (#2109)

  /// Every EG-1 install state, so the agreement checks below cannot silently
  /// skip the case that matters.
  nonisolated static let everyEGOneState: [EGOneInstallState] = [
    .notInstalled,
    .downloading(fractionCompleted: 0.4, upgrade: nil),
    .verifying,
    .installed(version: "1.1"),
    .installed(version: nil),
    .paused,
    .updatePaused(resumable: true, targetVersion: "1.1"),
    .updatePaused(resumable: false, targetVersion: "1.1"),
    .failed(.network),
  ]

  /// THE agreement invariant, and the reason the row's copy was extracted into
  /// a value at all: the chip and the row render the same state through two
  /// independent code paths. Compile-time exhaustiveness forces both to HANDLE
  /// every case and does nothing to make them AGREE — a reassuring chip beside
  /// an alarmed row is worse than either being wrong alone, because it teaches
  /// the user to distrust the screen.
  ///
  /// Stated as a property rather than a table of expected pairs: a table would
  /// just restate both implementations and pass whatever they happened to say.
  @Test("ready chip if and only if the model is actually serving")
  func railReadyMatchesRowServing() {
    for state in Self.everyEGOneState {
      let chip = status(for: .egOne, egOneInstall: state, egOneHealth: .green)
      let isInstalled: Bool = { if case .installed = state { return true } else { return false } }()
      #expect(
        (chip?.tone == .ready) == isInstalled,
        "\(state): chip ready tone must track installed exactly")
    }
  }

  /// Anything the chip flags as needing attention must give the user something
  /// to DO in the row. A red chip beside a row with no action is a dead end.
  @Test("an attention-seeking chip always has a row action behind it")
  func attentionStatesOfferAnAction() {
    for state in Self.everyEGOneState {
      let chip = status(for: .egOne, egOneInstall: state, egOneHealth: .green)
      guard chip?.tone == .error || chip?.tone == .needsSetup else { continue }
      let row = egOneRow(state)
      // `verifying` is the one legitimate exception: it is transient and
      // resolves on its own, so there is nothing for the user to do.
      if case .verifying = state { continue }
      #expect(
        row.primaryAction != nil,
        "\(state): chip asks for attention but the row offers no action")
    }
  }

  /// Remove Model appears exactly when a usable model is on disk. The
  /// `updatePaused` row is the case worth pinning: a full model IS present, and
  /// the help centre promises users can delete models to reclaim storage.
  @Test("remove is offered exactly when bytes are on disk")
  func removeOfferedOnlyWithAModelPresent() {
    for state in Self.everyEGOneState {
      let row = egOneRow(state)
      let hasModelOnDisk: Bool = {
        switch state {
        // `updatePaused` is deliberately FALSE: a model is on disk, but
        // `remove()` targets the current manifest, which is not the installed
        // revision in that state, so the button could not remove it.
        case .installed: return true
        case .updatePaused, .notInstalled, .downloading, .verifying, .paused, .failed: return false
        }
      }()
      #expect(
        row.showsRemove == hasModelOnDisk,
        "\(state): Remove Model offered without a model, or withheld with one")
    }
  }

  /// The version label, composed where it is tested rather than in the view.
  @Test("the version label renders only when there is something honest to show")
  func versionLabelSuppressesNilAndBlank() {
    #expect(egOneRow(.installed(version: "1.1")).versionLabel == "EG-1 V1.1")
    #expect(egOneRow(.installed(version: nil)).versionLabel == nil)
    #expect(egOneRow(.installed(version: "")).versionLabel == nil)
  }

  /// The upgrade copy is COMPOSED from the manifest's version, never a
  /// literal. A new EG-2/EG-3 revision ships as a manifest edit with no Swift
  /// change, so a hard-coded "V1.1" would keep naming the previous model after
  /// the real one moved on — confidently wrong, which is worse than silent.
  @Test func upgradeCopyFollowsTheTargetVersion() {
    let next = egOneRow(.updatePaused(resumable: false, targetVersion: "2.0"))
    #expect(next.message.contains("EG-1 V2.0"))
    #expect(next.message.contains("V1.1") == false, "copy still names a hard-coded version")

    let resuming = egOneRow(
      .updatePaused(resumable: true, targetVersion: "2.0"))
    #expect(resuming.message.contains("EG-1 V2.0"))
  }

  /// No target version means generic copy, not a placeholder and not a stale
  /// literal.
  @Test func upgradeCopyWithoutAVersionStaysGeneric() {
    let unknown = egOneRow(
      .updatePaused(resumable: false, targetVersion: nil))
    #expect(unknown.message.contains("the new EG-1"))
    #expect(unknown.message.contains("V") == false, "a nil version must not render a version token")
  }

  @Test("EG-1 downloading → Downloading / needs-setup")
  func egOneDownloading() {
    let s = status(for: .egOne, egOneInstall: .downloading(fractionCompleted: 0.4, upgrade: nil))
    #expect(s?.label == "Downloading")
    #expect(s?.tone == .needsSetup)
  }

  @Test("EG-1 verifying → Verifying / needs-setup")
  func egOneVerifying() {
    let s = status(for: .egOne, egOneInstall: .verifying)
    #expect(s?.tone == .needsSetup)
  }

  @Test("EG-1 download failed → error")
  func egOneFailed() {
    let s = status(for: .egOne, egOneInstall: .failed(.network))
    #expect(s?.tone == .error)
  }

  @Test("EG-1 installed + green → Installed / ready")
  func egOneLive() {
    let s = status(for: .egOne, egOneInstall: .installed(version: "1"), egOneHealth: .green)
    #expect(s?.label == "Installed")
    #expect(s?.tone == .ready)
  }

  @Test("EG-1 installed + yellow → Starting / needs-setup")
  func egOneStarting() {
    let s = status(
      for: .egOne, egOneInstall: .installed(version: "1"),
      egOneHealth: .yellow(reason: "starting"))
    #expect(s?.tone == .needsSetup)
  }

  @Test("EG-1 installed + red → Not working / error")
  func egOneNotWorking() {
    let s = status(
      for: .egOne, egOneInstall: .installed(version: "1"),
      egOneHealth: .red(reason: "crashed_twice"))
    #expect(s?.label == "Not working")
    #expect(s?.tone == .error)
  }

  // MARK: - Apple Intelligence

  @Test("Apple available → ready")
  func appleAvailable() {
    #expect(status(for: .appleIntelligence, appleStatus: .available)?.tone == .ready)
  }

  @Test("Apple degraded / unavailable / unknown / nil each keep their own tone")
  func appleNonReady() {
    #expect(status(for: .appleIntelligence, appleStatus: .degraded)?.tone == .needsSetup)
    #expect(status(for: .appleIntelligence, appleStatus: .unavailable)?.tone == .error)
    #expect(status(for: .appleIntelligence, appleStatus: .unknown)?.tone == .unavailable)
    #expect(status(for: .appleIntelligence, appleStatus: nil)?.tone == .unavailable)
  }

  // MARK: - Cloud (OpenAI / Gemini share the mapping)

  @Test("Cloud valid → Key valid / ready")
  func cloudValid() {
    for p in [LLMProvider.openAI, .gemini, .claude] {
      let s = status(for: p, cloudValidation: .valid)
      #expect(s?.label == "Key valid")
      #expect(s?.tone == .ready)
    }
  }

  @Test("Cloud validating → needs-setup")
  func cloudValidating() {
    #expect(status(for: .openAI, cloudValidation: .validating)?.tone == .needsSetup)
  }

  @Test("Cloud with NO saved key → Key needed, selected or not, whatever the verdict")
  func cloudIdleNoKey() {
    for selected in [true, false] {
      for validation: LLMModelDiscoveryCoordinator.KeyValidationState in [.idle, .valid] {
        let s = status(for: .gemini, selected: selected, cloudValidation: validation, cloudKeySaved: false)
        #expect(s?.label == "Key needed")
        #expect(s?.tone == .unavailable)
      }
    }
  }

  @Test("Cloud with an unreadable saved key → Could not check, never Key needed")
  func cloudUnknownKey() {
    for selected in [true, false] {
      let s = status(for: .claude, selected: selected, cloudKeySaved: nil)
      #expect(s?.label == "Could not check")
      #expect(s?.tone == .needsSetup)
    }
  }

  @Test("Cloud idle WITH a saved key → neutral Not checked, never a false Key needed")
  func cloudIdleWithSavedKey() {
    // A saved key loaded on settings-open leaves validation .idle; the chip must
    // not alarm the user with "Key needed" (cloud review PR #1293).
    for p in [LLMProvider.openAI, .gemini, .claude] {
      let s = status(for: p, cloudValidation: .idle, cloudKeySaved: true)
      #expect(s?.label == "Not checked")
      #expect(s?.tone == .unavailable)
    }
  }

  @Test("Cloud invalid → Check failed / error, never a claim that the key was rejected")
  func cloudInvalid() {
    let s = status(for: .openAI, cloudValidation: .invalid("Network error: offline"))
    #expect(s?.label == "Check failed")
    #expect(s?.tone == .error)
  }

  @Test("An unselected cloud provider or another provider's verdict says only Key saved")
  func cloudVerdictStaysWithItsProvider() {
    #expect(status(for: .openAI, selected: false, cloudValidation: .valid)?.label == "Key saved")
    #expect(
      status(for: .openAI, validationProvider: .gemini, cloudValidation: .valid)?.label
        == "Key saved")
    #expect(
      status(for: .openAI, validationProvider: .gemini, cloudValidation: .invalid("x"))?.label
        == "Key saved")
  }

  // MARK: - Ollama

  @Test("Ollama ready → Installed / ready")
  func ollamaRunning() {
    let s = status(for: .ollama, ollamaSetup: .ready)
    #expect(s?.label == "Installed")
    #expect(s?.tone == .ready)
  }

  @Test("Ollama not-installed/not-running/no-model/pulling/detecting → needs-setup")
  func ollamaNeedsSetup() {
    #expect(status(for: .ollama, ollamaSetup: .detecting)?.tone == .needsSetup)
    #expect(status(for: .ollama, ollamaSetup: .notInstalled)?.tone == .unavailable)
    #expect(status(for: .ollama, ollamaSetup: .installedNotRunning)?.tone == .needsSetup)
    #expect(status(for: .ollama, ollamaSetup: .runningNoModels)?.tone == .needsSetup)
    #expect(
      status(for: .ollama, ollamaSetup: .pullingModel(progress: 0.2, status: "x"))?.tone
        == .needsSetup)
  }

  @Test("An unselected Ollama says only what does not go stale")
  func ollamaUnselected() {
    #expect(status(for: .ollama, selected: false, ollamaSetup: .detecting) == nil)
    #expect(status(for: .ollama, selected: false, ollamaSetup: .error("x")) == nil)
    #expect(status(for: .ollama, selected: false, ollamaSetup: .notInstalled)?.label == "Not installed")
    for state: OllamaSetupState in [.installedNotRunning, .runningNoModels, .ready] {
      #expect(status(for: .ollama, selected: false, ollamaSetup: state)?.label == "Installed")
    }
    #expect(
      status(for: .ollama, selected: false, ollamaSetup: .pullingModel(progress: 0.2, status: "x"))?
        .label == "Downloading")
  }

  @Test("An unselected local engine reports its install state, never its unprobed health")
  func localUnselectedIgnoresHealth() {
    for health: EGOneHealth in [.red(reason: "not_running"), .yellow(reason: "not_started"), .green] {
      let s = status(for: .egOne, selected: false, egOneHealth: health)
      #expect(s?.label == "Installed")
      #expect(s?.tone == .ready)
    }
  }

  @Test("Apple says Checking only for a check running for the chosen provider")
  func appleChecking() {
    #expect(status(for: .appleIntelligence, appleIsChecking: true)?.label == "Checking")
    #expect(
      status(for: .appleIntelligence, selected: false, appleIsChecking: true)?.label == "Available")
  }

  @Test("Ollama error → error")
  func ollamaError() {
    #expect(status(for: .ollama, ollamaSetup: .error("boom"))?.tone == .error)
  }

  // MARK: - No cross-provider leak

  @Test("A blocking cloud key state does NOT change EG-1/Apple/Ollama results")
  func cloudStateDoesNotLeak() {
    // Cloud is .invalid (an error state) but the OTHER engines are nominal.
    #expect(
      status(for: .egOne, cloudValidation: .invalid("x"))?.tone == .ready,
      "EG-1 stays Live regardless of a broken cloud key")
    #expect(
      status(for: .appleIntelligence, cloudValidation: .invalid("x"))?.tone == .ready,
      "Apple stays Available regardless of a broken cloud key")
    #expect(
      status(for: .ollama, cloudValidation: .invalid("x"))?.tone == .ready,
      "Ollama stays Running regardless of a broken cloud key")
  }

  @Test("A blocking EG-1 state does NOT change cloud/Apple/Ollama results")
  func egOneStateDoesNotLeak() {
    #expect(
      status(for: .openAI, egOneInstall: .notInstalled)?.tone == .ready,
      "OpenAI stays Key valid regardless of EG-1 not being installed")
    #expect(
      status(for: .appleIntelligence, egOneHealth: .red(reason: "x"))?.tone == .ready,
      "Apple stays Available regardless of EG-1 health")
    #expect(
      status(for: .ollama, egOneInstall: .notInstalled)?.tone == .ready,
      "Ollama stays Running regardless of EG-1 not being installed")
  }

  @Test("Off provider → neutral, never a real engine status")
  func offProvider() {
    #expect(status(for: .none)?.tone == .unavailable)
  }

  /// An UPGRADE download must be distinguishable from a FIRST install while the
  /// bytes are moving (founder, from Live UAT 2026-08-17).
  ///
  /// Both rendered the identical sentence — "Downloading EG-1 (2.9 GB)" — so a
  /// user who already had EG-1 could not tell a 2.9 GB upgrade from a 2.9 GB
  /// fresh install, and was never told which version was arriving. Same defect
  /// as the row this change began with, one state further along.
  ///
  /// BOTH ARMS, because a label that appeared unconditionally would satisfy the
  /// upgrade arm while mislabelling every first install as an upgrade — a
  /// worse bug than the one being fixed, and invisible to a one-armed test.
  @MainActor
  @Test func onlyAnUpgradeDownloadCarriesAVersionLabel() throws {
    let upgrading = egOneRow(
      .downloading(fractionCompleted: 0.4, upgrade: .named("1.1")))
    #expect(
      upgrading.versionLabel == "EG-1 V1.1",
      "an upgrade in flight did not name the version arriving")

    let firstInstall = egOneRow(
      .downloading(fractionCompleted: 0.4, upgrade: nil))
    #expect(
      firstInstall.versionLabel == nil,
      "a first install was labelled as an upgrade, which is a worse lie than the missing label")

    // A blank display version must never produce a DANGLING "EG-1 V" — that is
    // what this assertion has always been about. It used to demand `nil`, which
    // conflated "do not print a half-written version" with "do not say this is
    // an upgrade"; the second was wrong and is what the cloud-review P2 named.
    // A blank version now reads as an UNNAMED upgrade, so assert the property
    // rather than the old value.
    let blank = egOneRow(
      .downloading(fractionCompleted: 0.4, upgrade: EGOneUpgradeContext(displayVersion: "")))
    let blankLabel = try #require(blank.versionLabel)
    #expect(
      !blankLabel.hasPrefix("EG-1 V"),
      "a blank display version rendered a dangling version label: \(blankLabel)")
    #expect(
      blankLabel == "the new EG-1",
      "a blank display version stopped reading as an upgrade")

    // Cancel stays reachable throughout: an upgrade the user cannot stop is
    // how a resumable download becomes an unresumable one.
    #expect(upgrading.primaryAction == "Cancel")
    #expect(firstInstall.primaryAction == "Cancel")
  }

  /// A manifest with NO display version still describes an UPGRADE.
  ///
  /// Cloud-review P2 on 5fdd0d53. `displayVersion` is optional by contract, and
  /// a bare `String?` marker could not tell "not an upgrade" from "an upgrade I
  /// cannot name" — so a blank one erased the upgrade and the row fell back to
  /// the FIRST-INSTALL sentence while an upgrade was running.
  @MainActor
  @Test func anUnnamedUpgradeStillReadsAsAnUpgrade() {
    let unnamed = egOneRow(
      .downloading(fractionCompleted: 0.4, upgrade: .unnamed))
    #expect(
      unnamed.versionLabel == "the new EG-1",
      "an upgrade with no display version fell back to first-install copy")

    // The same fallback the PAUSED row already uses, so the two states do not
    // describe one situation with two vocabularies.
    let paused = egOneRow(
      .updatePaused(resumable: false, targetVersion: nil))
    #expect(
      paused.message.contains("the new EG-1"),
      "paused-row fallback wording drifted from the downloading row's")

    // And a blank string must land on `.unnamed`, never `.named("")`.
    #expect(EGOneUpgradeContext(displayVersion: "") == .unnamed)
    #expect(EGOneUpgradeContext(displayVersion: "   ") == .unnamed)
    #expect(EGOneUpgradeContext(displayVersion: "1.1") == .named("1.1"))
    #expect(EGOneUpgradeContext(displayVersion: nil) == .unnamed)
  }
}


/// Every row above is about EG-1, so the engine name is bound in ONE place
/// rather than repeated at each call. #2649 made the name an argument because a
/// second bundled engine renders through the same value; binding it here keeps
/// these rows asserting exactly what they asserted before, so a failure means
/// the presentation changed rather than the call sites did.
private func egOneRow(_ state: EGOneInstallState) -> EGOneRowPresentation {
  EGOneRowPresentation.forState(state, engine: "EG-1")
}
