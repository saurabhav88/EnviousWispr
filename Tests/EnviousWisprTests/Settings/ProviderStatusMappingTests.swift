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
@Suite("ProviderStatusMapping — one status authority, no cross-provider leak")
struct ProviderStatusMappingTests {

  // Neutral "everything nominal" inputs for the engines NOT under test, so a
  // per-engine assertion isolates the one coordinator that should matter.
  private func status(
    for provider: LLMProvider,
    egOneInstall: EGOneInstallState = .installed(version: "1"),
    egOneHealth: EGOneHealth = .green,
    appleStatus: AIAvailabilityStatus? = .available,
    cloudValidation: LLMModelDiscoveryCoordinator.KeyValidationState = .valid,
    cloudKeyPresent: Bool = false,
    ollamaSetup: OllamaSetupState = .ready
  ) -> ProviderStatus {
    ProviderStatusMapping.status(
      for: provider,
      egOneInstall: egOneInstall,
      egOneHealth: egOneHealth,
      appleStatus: appleStatus,
      cloudValidation: cloudValidation,
      cloudKeyPresent: cloudKeyPresent,
      ollamaSetup: ollamaSetup)
  }

  // MARK: - EG-1 (install lifecycle first, health once installed)

  @Test("EG-1 not installed → Not installed / needs-setup")
  func egOneNotInstalled() {
    let s = status(for: .egOne, egOneInstall: .notInstalled)
    #expect(s.label == "Not installed")
    #expect(s.tone == .needsSetup)
  }

  // MARK: - Paused states (#2109)

  /// An interrupted FIRST install. The user chose to stop and their progress
  /// is kept, so the chip must read as setup-pending, never as an error —
  /// this used to arrive here as `.failed` and paint the error tone.
  @Test("EG-1 paused → Paused / needs-setup")
  func egOnePaused() {
    let s = status(for: .egOne, egOneInstall: .paused)
    #expect(s.label == "Paused")
    #expect(s.tone == .needsSetup)
  }

  /// A working older revision is on disk but the pinned one is not, so AI
  /// cleanup is genuinely OFF. The chip must agree with the detailed row
  /// rather than reassure: a calm chip beside an alarmed row is worse than
  /// either alone, because it teaches the user to distrust the screen. This is
  /// the silently-off state #2109 exists to surface.
  @Test(arguments: [true, false])
  func egOneUpdatePausedReadsAsNeedingAttention(_ resumable: Bool) {
    let s = status(for: .egOne, egOneInstall: .updatePaused(resumable: resumable, targetVersion: "1.1"))
    #expect(s.label == "Update paused")
    #expect(s.tone == .error)
  }

  /// Two-way control on the pair above: the two paused states must NOT collapse
  /// to the same chip. `paused` means "nothing works yet, finish when you like";
  /// `updatePaused` means "something that was working has stopped". A mapping
  /// that returned one tone for both would pass each test above in isolation.
  @Test("the two paused states are distinguishable at the chip")
  func pausedAndUpdatePausedDoNotCollapse() {
    let paused = status(for: .egOne, egOneInstall: .paused)
    let updatePaused = status(for: .egOne, egOneInstall: .updatePaused(resumable: true, targetVersion: "1.1"))
    #expect(paused.label != updatePaused.label)
    #expect(paused.tone != updatePaused.tone)
  }

  // MARK: - Rail and row agreement (#2109)

  /// Every EG-1 install state, so the agreement checks below cannot silently
  /// skip the case that matters.
  nonisolated static let everyEGOneState: [EGOneInstallState] = [
    .notInstalled,
    .downloading(fractionCompleted: 0.4, upgradeTo: nil),
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
        (chip.tone == .ready) == isInstalled,
        "\(state): chip ready tone must track installed exactly")
    }
  }

  /// Anything the chip flags as needing attention must give the user something
  /// to DO in the row. A red chip beside a row with no action is a dead end.
  @Test("an attention-seeking chip always has a row action behind it")
  func attentionStatesOfferAnAction() {
    for state in Self.everyEGOneState {
      let chip = status(for: .egOne, egOneInstall: state, egOneHealth: .green)
      guard chip.tone == .error || chip.tone == .needsSetup else { continue }
      let row = EGOneRowPresentation.forState(state)
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
      let row = EGOneRowPresentation.forState(state)
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

  /// The properties above are necessary and NOT sufficient: they would all
  /// still pass with "Resume upgrade" and "Finish upgrade" REVERSED, or with
  /// reassuring copy on `updatePaused`. Both would be user-visibly wrong and
  /// invisible to a property test, so the founder-decided wording is pinned
  /// directly here.
  ///
  /// The pairing is the point. `resumable` means the user already started the
  /// download, so the verb must be Resume; not-resumable means they have not,
  /// so it must be Finish. Swapping them tells people to resume something they
  /// never began.
  @Test("the paused actions are pinned to the right state")
  func pausedActionsUseTheDecidedWording() {
    #expect(EGOneRowPresentation.forState(.paused).primaryAction == "Resume")
    #expect(
      EGOneRowPresentation.forState(.updatePaused(resumable: true, targetVersion: "1.1")).primaryAction
        == "Resume upgrade")
    #expect(
      EGOneRowPresentation.forState(.updatePaused(resumable: false, targetVersion: "1.1")).primaryAction
        == "Finish upgrade")
    // Never "Install": the user already has a working model, and Install reads
    // as a new product to acquire — Frank's stated failure mode.
    #expect(
      EGOneRowPresentation.forState(.updatePaused(resumable: false, targetVersion: "1.1")).primaryAction?
        .contains("Install") == false)
  }

  /// Both update messages must SAY that cleanup is off. A reassuring string
  /// here would satisfy every structural invariant while hiding the exact
  /// condition #2109 exists to surface.
  @Test("the update messages state that cleanup is paused")
  func updateMessagesSayCleanupIsPaused() {
    for resumable in [true, false] {
      let message = EGOneRowPresentation.forState(.updatePaused(resumable: resumable, targetVersion: "1.1")).message
      #expect(message.contains("AI cleanup is paused"), "\(resumable): message must not reassure")
      // The download size is deliberately absent: leading with 2.9 GB to
      // someone who already has a working model reads as a cost, not a fix.
      #expect(message.contains("GB") == false, "\(resumable): size must not lead this row")
    }
  }

  /// The version label, composed where it is tested rather than in the view.
  @Test("the version label renders only when there is something honest to show")
  func versionLabelSuppressesNilAndBlank() {
    #expect(EGOneRowPresentation.forState(.installed(version: "1.1")).versionLabel == "EG-1 V1.1")
    #expect(EGOneRowPresentation.forState(.installed(version: nil)).versionLabel == nil)
    #expect(EGOneRowPresentation.forState(.installed(version: "")).versionLabel == nil)
  }

  /// The upgrade copy is COMPOSED from the manifest's version, never a
  /// literal. A new EG-2/EG-3 revision ships as a manifest edit with no Swift
  /// change, so a hard-coded "V1.1" would keep naming the previous model after
  /// the real one moved on — confidently wrong, which is worse than silent.
  @Test func upgradeCopyFollowsTheTargetVersion() {
    let next = EGOneRowPresentation.forState(.updatePaused(resumable: false, targetVersion: "2.0"))
    #expect(next.message.contains("EG-1 V2.0"))
    #expect(next.message.contains("V1.1") == false, "copy still names a hard-coded version")

    let resuming = EGOneRowPresentation.forState(
      .updatePaused(resumable: true, targetVersion: "2.0"))
    #expect(resuming.message.contains("EG-1 V2.0"))
  }

  /// No target version means generic copy, not a placeholder and not a stale
  /// literal.
  @Test func upgradeCopyWithoutAVersionStaysGeneric() {
    let unknown = EGOneRowPresentation.forState(
      .updatePaused(resumable: false, targetVersion: nil))
    #expect(unknown.message.contains("the new EG-1"))
    #expect(unknown.message.contains("V") == false, "a nil version must not render a version token")
  }

  /// Remove Model is NOT offered while an upgrade is pending. `remove()`
  /// deletes the CURRENT manifest's files, and in this state the current
  /// revision is exactly what is not installed — the button would leave the
  /// older model's gigabytes untouched and return the row to this state.
  @Test func removeIsNotOfferedWhileAnUpgradeIsPending() {
    for resumable in [true, false] {
      let row = EGOneRowPresentation.forState(
        .updatePaused(resumable: resumable, targetVersion: "1.1"))
      #expect(
        row.showsRemove == false,
        "Remove is offered in a state where it cannot remove the installed model")
    }
    // Two-way control: it IS offered where it works.
    #expect(EGOneRowPresentation.forState(.installed(version: "1.1")).showsRemove)
  }

  /// The two paused rows must not read identically. One means "nothing works
  /// yet"; the other means "something that WAS working has stopped".
  @Test("the paused rows say different things")
  func pausedRowsAreDistinguishable() {
    let paused = EGOneRowPresentation.forState(.paused)
    let update = EGOneRowPresentation.forState(.updatePaused(resumable: true, targetVersion: "1.1"))
    #expect(paused.message != update.message)
    #expect(paused.primaryAction != update.primaryAction)
  }

  @Test("EG-1 downloading → Downloading / needs-setup")
  func egOneDownloading() {
    let s = status(for: .egOne, egOneInstall: .downloading(fractionCompleted: 0.4, upgradeTo: nil))
    #expect(s.label == "Downloading")
    #expect(s.tone == .needsSetup)
  }

  @Test("EG-1 verifying → Verifying / needs-setup")
  func egOneVerifying() {
    let s = status(for: .egOne, egOneInstall: .verifying)
    #expect(s.tone == .needsSetup)
  }

  @Test("EG-1 download failed → error")
  func egOneFailed() {
    let s = status(for: .egOne, egOneInstall: .failed(.network))
    #expect(s.tone == .error)
  }

  @Test("EG-1 installed + green → Live / ready")
  func egOneLive() {
    let s = status(for: .egOne, egOneInstall: .installed(version: "1"), egOneHealth: .green)
    #expect(s.label == "Live")
    #expect(s.tone == .ready)
  }

  @Test("EG-1 installed + yellow → Starting / needs-setup")
  func egOneStarting() {
    let s = status(
      for: .egOne, egOneInstall: .installed(version: "1"),
      egOneHealth: .yellow(reason: "starting"))
    #expect(s.tone == .needsSetup)
  }

  @Test("EG-1 installed + red → Not working / error")
  func egOneNotWorking() {
    let s = status(
      for: .egOne, egOneInstall: .installed(version: "1"),
      egOneHealth: .red(reason: "crashed_twice"))
    #expect(s.label == "Not working")
    #expect(s.tone == .error)
  }

  // MARK: - Apple Intelligence

  @Test("Apple available → ready")
  func appleAvailable() {
    #expect(status(for: .appleIntelligence, appleStatus: .available).tone == .ready)
  }

  @Test("Apple degraded/unavailable/unknown/nil → unavailable tone")
  func appleNonReady() {
    #expect(status(for: .appleIntelligence, appleStatus: .degraded).tone == .unavailable)
    #expect(status(for: .appleIntelligence, appleStatus: .unavailable).tone == .unavailable)
    #expect(status(for: .appleIntelligence, appleStatus: .unknown).tone == .unavailable)
    #expect(status(for: .appleIntelligence, appleStatus: nil).tone == .unavailable)
  }

  // MARK: - Cloud (OpenAI / Gemini share the mapping)

  @Test("Cloud valid → Key valid / ready")
  func cloudValid() {
    for p in [LLMProvider.openAI, .gemini, .claude] {
      let s = status(for: p, cloudValidation: .valid)
      #expect(s.label == "Key valid")
      #expect(s.tone == .ready)
    }
  }

  @Test("Cloud validating → needs-setup")
  func cloudValidating() {
    #expect(status(for: .openAI, cloudValidation: .validating).tone == .needsSetup)
  }

  @Test("Cloud idle with NO key → Key needed / needs-setup")
  func cloudIdleNoKey() {
    let s = status(for: .gemini, cloudValidation: .idle, cloudKeyPresent: false)
    #expect(s.label == "Key needed")
    #expect(s.tone == .needsSetup)
  }

  @Test("Cloud idle WITH a saved key → neutral Not checked, never a false Key needed")
  func cloudIdleWithSavedKey() {
    // A saved key loaded on settings-open leaves validation .idle; the chip must
    // not alarm the user with "Key needed" (cloud review PR #1293).
    for p in [LLMProvider.openAI, .gemini, .claude] {
      let s = status(for: p, cloudValidation: .idle, cloudKeyPresent: true)
      #expect(s.label == "Not checked")
      #expect(s.tone == .unavailable)
    }
  }

  @Test("Cloud invalid → Key needed / error")
  func cloudInvalid() {
    let s = status(for: .openAI, cloudValidation: .invalid("bad key"))
    #expect(s.label == "Key needed")
    #expect(s.tone == .error)
  }

  // MARK: - Ollama

  @Test("Ollama ready → Running / ready")
  func ollamaRunning() {
    let s = status(for: .ollama, ollamaSetup: .ready)
    #expect(s.label == "Running")
    #expect(s.tone == .ready)
  }

  @Test("Ollama not-installed/not-running/no-model/pulling/detecting → needs-setup")
  func ollamaNeedsSetup() {
    #expect(status(for: .ollama, ollamaSetup: .detecting).tone == .needsSetup)
    #expect(status(for: .ollama, ollamaSetup: .notInstalled).tone == .needsSetup)
    #expect(status(for: .ollama, ollamaSetup: .installedNotRunning).tone == .needsSetup)
    #expect(status(for: .ollama, ollamaSetup: .runningNoModels).tone == .needsSetup)
    #expect(
      status(for: .ollama, ollamaSetup: .pullingModel(progress: 0.2, status: "x")).tone
        == .needsSetup)
  }

  @Test("Ollama error → error")
  func ollamaError() {
    #expect(status(for: .ollama, ollamaSetup: .error("boom")).tone == .error)
  }

  // MARK: - No cross-provider leak

  @Test("A blocking cloud key state does NOT change EG-1/Apple/Ollama results")
  func cloudStateDoesNotLeak() {
    // Cloud is .invalid (an error state) but the OTHER engines are nominal.
    #expect(
      status(for: .egOne, cloudValidation: .invalid("x")).tone == .ready,
      "EG-1 stays Live regardless of a broken cloud key")
    #expect(
      status(for: .appleIntelligence, cloudValidation: .invalid("x")).tone == .ready,
      "Apple stays Available regardless of a broken cloud key")
    #expect(
      status(for: .ollama, cloudValidation: .invalid("x")).tone == .ready,
      "Ollama stays Running regardless of a broken cloud key")
  }

  @Test("A blocking EG-1 state does NOT change cloud/Apple/Ollama results")
  func egOneStateDoesNotLeak() {
    #expect(
      status(for: .openAI, egOneInstall: .notInstalled).tone == .ready,
      "OpenAI stays Key valid regardless of EG-1 not being installed")
    #expect(
      status(for: .appleIntelligence, egOneHealth: .red(reason: "x")).tone == .ready,
      "Apple stays Available regardless of EG-1 health")
    #expect(
      status(for: .ollama, egOneInstall: .notInstalled).tone == .ready,
      "Ollama stays Running regardless of EG-1 not being installed")
  }

  @Test("Off provider → neutral, never a real engine status")
  func offProvider() {
    #expect(status(for: .none).tone == .unavailable)
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
  @Test func onlyAnUpgradeDownloadCarriesAVersionLabel() {
    let upgrading = EGOneRowPresentation.forState(
      .downloading(fractionCompleted: 0.4, upgradeTo: "1.1"))
    #expect(
      upgrading.versionLabel == "EG-1 V1.1",
      "an upgrade in flight did not name the version arriving")

    let firstInstall = EGOneRowPresentation.forState(
      .downloading(fractionCompleted: 0.4, upgradeTo: nil))
    #expect(
      firstInstall.versionLabel == nil,
      "a first install was labelled as an upgrade, which is a worse lie than the missing label")

    // A manifest carrying a blank display version must render NOTHING, never
    // "EG-1 V" with an empty tail. Same rule already enforced for `installed`.
    let blank = EGOneRowPresentation.forState(
      .downloading(fractionCompleted: 0.4, upgradeTo: ""))
    #expect(blank.versionLabel == nil, "a blank display version rendered a dangling label")

    // Cancel stays reachable throughout: an upgrade the user cannot stop is
    // how a resumable download becomes an unresumable one.
    #expect(upgrading.primaryAction == "Cancel")
    #expect(firstInstall.primaryAction == "Cancel")
  }
}
