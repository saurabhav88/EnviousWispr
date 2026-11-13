import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

#if DEBUG

  /// #1176 (Telemetry Bible Phase 7) — onboarding drop-off telemetry.
  ///
  /// Covers the `OnboardingProgress` session box (single-terminal dedup, re-entry
  /// reset, source derivation) and the two new `TelemetryService` event payloads.
  /// Synchronous bodies install + assert the process-global `testEventHook` with no
  /// await between, so they are immune to the cross-test global-delegate flake class.
  @MainActor
  @Suite("Onboarding telemetry", .serialized)
  struct OnboardingTelemetryTests {

    final class Events: @unchecked Sendable {
      private let lock = NSLock()
      private var stored: [CapturedTelemetryEvent] = []
      func add(_ e: CapturedTelemetryEvent) { lock.withLock { stored.append(e) } }
      var all: [CapturedTelemetryEvent] { lock.withLock { stored } }
      func named(_ n: String) -> [CapturedTelemetryEvent] { all.filter { $0.name == n } }
    }

    // MARK: #3881 microphone row state

    @Test("#3881: a live denial wins over the cached grant and marks the row denied")
    func micLiveDenialWinsOverCachedGrant() {
      let vm = OnboardingV2ViewModel()
      let granted = vm.syncMicrophone(isDenied: true, isAuthorized: true, emitGrant: true)
      #expect(granted == false)
      #expect(vm.micGranted == false)
      #expect(vm.micDenied == true)
    }

    @Test("#3881: never asked is neither granted nor denied (the row offers Grant)")
    func micNotDeterminedIsNeither() {
      let vm = OnboardingV2ViewModel()
      vm.syncMicrophone(isDenied: false, isAuthorized: false, emitGrant: true)
      #expect(vm.micGranted == false)
      #expect(vm.micDenied == false)
    }

    @Test("#3881: a poll-observed grant emits step_completed once, even after revoke and re-grant")
    func micGrantTelemetryFiresOncePerSession() {
      withHook { events in
        let vm = OnboardingV2ViewModel()
        vm.syncMicrophone(isDenied: true, isAuthorized: false, emitGrant: true)  // arrives denied
        vm.syncMicrophone(isDenied: false, isAuthorized: true, emitGrant: true)  // user turns it on
        #expect(vm.micGranted == true)
        #expect(vm.micDenied == false)
        vm.syncMicrophone(isDenied: true, isAuthorized: true, emitGrant: true)  // turned off again
        #expect(vm.micGranted == false)
        vm.syncMicrophone(isDenied: false, isAuthorized: true, emitGrant: true)  // and on again
        #expect(vm.micGranted == true)
        let done = events.named("onboarding.step_completed").filter {
          $0.stringProps["step"] == "mic_permission"
        }
        #expect(done.count == 1)
      }
    }

    @Test("#3881: a grant seen at appearance, restore or the dialog sets the latch without emitting")
    func micGrantSeenOutsideThePollEmitsNothing() {
      withHook { events in
        let vm = OnboardingV2ViewModel()
        vm.syncMicrophone(isDenied: false, isAuthorized: true, emitGrant: false)
        vm.syncMicrophone(isDenied: false, isAuthorized: true, emitGrant: true)  // next poll
        #expect(vm.micGranted == true)
        #expect(events.named("onboarding.step_completed").isEmpty)
      }
    }

    private func withHook(_ body: (Events) -> Void) {
      let events = Events()
      TelemetryService.shared.testEventHook = { @Sendable e in events.add(e) }
      defer { TelemetryService.shared.testEventHook = nil }
      body(events)
    }

    private func makeBox() -> OnboardingProgress { OnboardingProgress() }

    // MARK: #4528 §3.8 new Setup events (payload contract only; F2 wires them)

    @Test("completed keeps its two original fields alone, and adds the typed summary when given")
    func completedContract() {
      withHook { events in
        TelemetryService.shared.onboardingCompleted(asrBackend: "parakeet", recordingMode: "pushToTalk")
        let legacy = events.named("onboarding.completed").last
        #expect(legacy?.stringProps == ["asr_backend": "parakeet", "recording_mode": "pushToTalk"])
        #expect(legacy?.boolProps.isEmpty == true)

        TelemetryService.shared.onboardingCompleted(
          asrBackend: "whisper", recordingMode: "toggle",
          summary: .init(
            polishProvider: .egOne, polishModel: .local("eg1.mini"), speechModel: .whisper,
            followedAllRecommendations: false, languageMode: .locked("de"), rulesVersion: "2026.11.12",
            filmResult: nil))
        let full = events.named("onboarding.completed").last
        #expect(full?.stringProps["polish_provider"] == "egOne")
        #expect(full?.stringProps["polish_model_id"] == "eg1.mini")
        #expect(full?.stringProps["speech_model_id"] == "whisper")
        // Mode only, like settings telemetry; the code belongs to the language choice row.
        #expect(full?.stringProps["language_mode"] == "locked")
        #expect(full?.stringProps["film_result"] == "not_shown")  // summary-only state
        #expect(full?.stringProps["asr_backend"] == "whisper")
        #expect(full?.boolProps["followed_all_recommendations"] == false)
      }
    }

    @Test("the completion summary reports a cloud polish model as the projection, private names as custom")
    func completedCloudModel() {
      // A model the committed list recognises passes as its id; a private name reads custom.
      guard let listed = CloudModelListSeed.current?.models.first(where: { $0.provider == .openAI })?.id
      else {
        Issue.record("the committed cloud model list has no OpenAI model")
        return
      }
      withHook { events in
        for (id, expected) in [(listed, listed), ("MyPrivateModel", "custom")] {
          let projected = SettingsProjection.model(
            provider: .openAI, id: id, list: CloudModelListSeed.current)
          TelemetryService.shared.onboardingCompleted(
            asrBackend: "parakeet", recordingMode: "pushToTalk",
            summary: .init(
              polishProvider: .openAI, polishModel: .projected(.init(projectedBySettingsTelemetry: projected)),
              speechModel: .parakeet, followedAllRecommendations: false, languageMode: .auto,
              rulesVersion: "r1", filmResult: .watched))
          let e = events.named("onboarding.completed").last
          #expect(e?.stringProps["polish_model_id"] == expected, "\(id)")
          #expect(e?.stringProps["language_mode"] == "auto")
        }
      }
      #expect(OnboardingTelemetry.PolishModel.local("custom-weights").id == "other")
    }

    @Test("screen_viewed carries step, entry and seconds as a number in elapsed_seconds and $value")
    func screenViewedPayload() {
      withHook { events in
        TelemetryService.shared.onboardingScreenViewed(step: "polishPick", entry: .back, elapsedSeconds: 42.5)
        let e = events.named("onboarding.screen_viewed").last
        #expect(e?.stringProps == ["step": "polishPick", "entry": "back"])
        #expect(e?.doubleProps == ["elapsed_seconds": 42.5, "$value": 42.5])
      }
    }

    @Test("choice_made values are closed by type: offered ids pass, anything else reads other")
    func choiceMadePayload() {
      withHook { events in
        TelemetryService.shared.onboardingChoiceMade(
          .polish("eg1.mini"), recommended: .polish("eg1.mini"), followedRecommendation: true,
          rulesVersion: "2026.11.12")
        let polish = events.named("onboarding.choice_made").last
        #expect(polish?.stringProps["kind"] == "polish")
        #expect(polish?.stringProps["value"] == "eg1.mini")
        #expect(polish?.stringProps["recommended_value"] == "eg1.mini")
        #expect(polish?.boolProps["followed_recommendation"] == true)

        TelemetryService.shared.onboardingChoiceMade(
          .key(.checkFailed), recommended: nil, followedRecommendation: false, rulesVersion: "r1")
        let key = events.named("onboarding.choice_made").last
        #expect(key?.stringProps["kind"] == "key" && key?.stringProps["value"] == "check_failed")
        #expect(key?.stringProps["recommended_value"] == nil)
      }
      // Credential-shaped and private ASCII never pass as an offered value.
      #expect(OnboardingTelemetry.Choice.polish("sk-test-secret123").value == "other")
      #expect(OnboardingTelemetry.Choice.polish("MyPrivateModel").value == "other")
      #expect(OnboardingTelemetry.Choice.language(.locked("sk-test")).value == "other")
      #expect(OnboardingTelemetry.Choice.language(.auto).value == "auto")
      #expect(OnboardingTelemetry.Choice.cloudProvider(.ollama).value == "other")
      #expect(OnboardingTelemetry.Choice.cloudProvider(.claude).value == "claude")
      #expect(OnboardingTelemetry.Choice.speech(.parakeet).value == "parakeet")
    }

    @Test("a cloud model reaches telemetry only as the settings projection, which redacts private names")
    func cloudModelProjectionBoundary() {
      // The AppKit projection is the boundary (F2 calls it before building the choice).
      for privateName in ["MyPrivateModel", "sk-test-secret123", "acme-internal-v2"] {
        let projected = SettingsProjection.model(provider: .openAI, id: privateName, list: nil)
        #expect(projected == "custom", "\(privateName) leaked as \(projected)")
        let choice = OnboardingTelemetry.Choice.cloudModel(.init(projectedBySettingsTelemetry: projected))
        #expect(choice.value == "custom" && choice.kind == .cloudModel)
      }
      #expect(SettingsProjection.model(provider: .openAI, id: "", list: nil) == "none")
    }

    @Test("download_finished carries a typed model, result, seconds and a coarse size bucket")
    func downloadFinishedPayload() {
      withHook { events in
        TelemetryService.shared.onboardingDownloadFinished(
          model: .speech(.parakeet), result: .ok, seconds: 61, bytes: 632_314_500)
        let e = events.named("onboarding.download_finished").last
        #expect(e?.stringProps == [
          "model_kind": "speech", "model_id": "parakeet", "result": "ok", "bytes_bucket": "500mb_1gb",
        ])
        #expect(e?.doubleProps == ["seconds": 61, "$value": 61])
      }
      #expect(OnboardingTelemetry.DownloadModel.polish("eg1.full").id == "eg1.full")
      #expect(OnboardingTelemetry.DownloadModel.polish("custom-weights").id == "other")
      #expect(OnboardingTelemetry.bytesBucket(nil) == "unknown")
      #expect(OnboardingTelemetry.bytesBucket(99_000_000) == "lt_100mb")
      #expect(OnboardingTelemetry.bytesBucket(1_000_000_000) == "gte_1gb")
    }

    @Test("film_finished allows only watched, skipped and replayed; blocked reasons are closed")
    func filmAndBlocked() {
      #expect(OnboardingTelemetry.FilmResult.allCases.map(\.rawValue) == ["watched", "skipped", "replayed"])
      withHook { events in
        TelemetryService.shared.onboardingFilmFinished(result: .replayed, lastScene: "pill")
        #expect(events.named("onboarding.film_finished").last?.stringProps == [
          "result": "replayed", "last_scene": "pill",
        ])
        for reason in OnboardingTelemetry.BlockedReason.allCases {
          TelemetryService.shared.onboardingStepBlocked(step: "downloads", reason: reason)
          #expect(events.named("onboarding.step_blocked").last?.stringProps["reason"] == reason.rawValue)
        }
      }
      #expect(OnboardingTelemetry.BlockedReason.allCases.map(\.rawValue) == [
        "key_check_failed", "disk_short", "download_failed",
        // C repair (M70): the new Setup reuses the old onboarding's warm-up failure reason.
        "warmup_failed",
        // D4a.2: Getting ready's failed local polish load.
        "polish_failed",
      ])
      // Syntax check only (caller-owned closed vocabularies).
      #expect(OnboardingTelemetry.boundedIdentifier("") == "invalid")
      #expect(OnboardingTelemetry.boundedIdentifier(String(repeating: "a", count: 65)) == "invalid")
      #expect(OnboardingTelemetry.boundedIdentifier("polishPick") == "polishPick")
    }

    /// A SettingsManager backed by a fresh ephemeral suite (never touches the real
    /// shared store).
    private func makeSettings() -> SettingsManager {
      SettingsManager(defaults: TestDefaults.suite("ewtest.\(UUID().uuidString)")!)
    }

    @Test("abandon fires once with screen/step/reason/source payload")
    func abandonPayload() {
      withHook { events in
        let box = makeBox()
        box.begin(source: "first_run")
        box.update(screen: "setting_up", step: "permissions")
        box.emitAbandonIfInFlight(
          reason: "window_closed", micStatus: "denied", accessibilityStatus: "denied")
        let a = events.named("onboarding.abandoned")
        #expect(a.count == 1)
        #expect(a.first?.stringProps["abandon_reason"] == "window_closed")
        #expect(a.first?.stringProps["screen"] == "setting_up")
        #expect(a.first?.stringProps["step"] == "permissions")
        #expect(a.first?.stringProps["source"] == "first_run")
        #expect(a.first?.stringProps["accessibility_status"] == "denied")
      }
    }

    @Test("second terminal is deduped — window-close then app-quit emits once")
    func terminalDedup() {
      withHook { events in
        let box = makeBox()
        box.begin(source: "first_run")
        box.emitAbandonIfInFlight(
          reason: "window_closed", micStatus: "authorized", accessibilityStatus: "granted")
        box.emitAbandonIfInFlight(
          reason: "app_quit", micStatus: "authorized", accessibilityStatus: "granted")
        #expect(events.named("onboarding.abandoned").count == 1)
        #expect(
          events.named("onboarding.abandoned").first?.stringProps["abandon_reason"]
            == "window_closed")
      }
    }

    @Test("markCompleted suppresses a later abandon (the complete/abandon race fix)")
    func completeSuppressesAbandon() {
      withHook { events in
        let box = makeBox()
        box.begin(source: "first_run")
        box.markCompleted()
        box.emitAbandonIfInFlight(
          reason: "window_closed", micStatus: "authorized", accessibilityStatus: "granted")
        #expect(events.named("onboarding.abandoned").isEmpty)
      }
    }

    @Test("not-in-flight (no begin) emits nothing")
    func notInFlightNoEmit() {
      withHook { events in
        let box = makeBox()
        box.emitAbandonIfInFlight(
          reason: "app_quit", micStatus: "authorized", accessibilityStatus: "granted")
        #expect(events.named("onboarding.abandoned").isEmpty)
      }
    }

    @Test("re-entry: a 2nd begin resets the terminal flag so a new abandon fires")
    func reEntryResetsTerminal() {
      withHook { events in
        let box = makeBox()
        box.begin(source: "first_run")
        box.emitAbandonIfInFlight(
          reason: "window_closed", micStatus: "denied", accessibilityStatus: "denied")
        box.begin(source: "first_run")  // fresh session — resets terminalEmitted
        box.emitAbandonIfInFlight(
          reason: "app_quit", micStatus: "denied", accessibilityStatus: "denied")
        let a = events.named("onboarding.abandoned")
        #expect(a.count == 2)
        // Never completed → both sessions are first_run (the source comes from the
        // durable everCompleted flag, NOT the in-session count — Codex code-diff #1).
        #expect(a.allSatisfy { $0.stringProps["source"] == "first_run" })
        #expect(a.last?.stringProps["abandon_reason"] == "app_quit")
      }
    }

    @Test("refocus: a 2nd begin while in-flight does NOT rewind the session")
    func refocusPreservesInFlightSession() {
      withHook { events in
        let box = makeBox()
        box.begin(source: "first_run")
        box.update(screen: "setting_up", step: "permissions")
        // The status-menu "Continue Setup…" re-enters openOnboardingAction on the
        // already-open window — begin must no-op, NOT reset screen/step to welcome.
        box.begin(source: "diagnostics_restart")
        box.emitAbandonIfInFlight(
          reason: "window_closed", micStatus: "denied", accessibilityStatus: "denied")
        let a = events.named("onboarding.abandoned")
        #expect(a.count == 1)
        // Preserved the real position + the original source, not the refocus values.
        #expect(a.first?.stringProps["screen"] == "setting_up")
        #expect(a.first?.stringProps["step"] == "permissions")
        #expect(a.first?.stringProps["source"] == "first_run")
      }
    }

    @Test("reopen after abandon reports the last observed position, not welcome")
    func reopenAfterAbandonKeepsLastPosition() {
      withHook { events in
        let box = makeBox()
        box.begin(source: "first_run")
        box.update(screen: "setting_up", step: "permissions")
        box.emitAbandonIfInFlight(
          reason: "window_closed", micStatus: "denied", accessibilityStatus: "denied")
        // Reopen the single-instance window: terminalEmitted was set, so begin starts
        // a fresh session — but the reused SwiftUI window keeps its viewModel and skips
        // onAppear, so syncProgressBox never re-fires. begin must NOT have reset the
        // position to "welcome"; the honest value is the last observed screen/step.
        box.begin(source: "first_run")
        box.emitAbandonIfInFlight(
          reason: "app_quit", micStatus: "denied", accessibilityStatus: "denied")
        let a = events.named("onboarding.abandoned")
        #expect(a.count == 2)
        #expect(a.last?.stringProps["screen"] == "setting_up")
        #expect(a.last?.stringProps["step"] == "permissions")
      }
    }

    @Test("the caller-supplied source is carried into the abandon event")
    func sourceCarriesThrough() {
      withHook { events in
        let box = makeBox()
        box.begin(source: "diagnostics_restart")
        box.emitAbandonIfInFlight(
          reason: "window_closed", micStatus: "authorized", accessibilityStatus: "granted")
        #expect(
          events.named("onboarding.abandoned").first?.stringProps["source"] == "diagnostics_restart"
        )
      }
    }

    @Test("SettingsManager.onboardingEverCompleted is set on completion and never reset")
    func everCompletedSetOnCompletionAndDurable() {
      let s = makeSettings()
      #expect(s.onboardingEverCompleted == false)
      s.onboardingState = .completed
      #expect(s.onboardingEverCompleted == true)
      // A Diagnostics restart resets onboardingState (and the legacy key) but NOT
      // the durable flag — so a restart is still labeled diagnostics_restart.
      s.onboardingState = .notStarted
      #expect(s.onboardingEverCompleted == true)
    }

    @Test("SettingsManager backfills everCompleted from the legacy key at init")
    func everCompletedBackfillsFromLegacyKey() {
      let d = TestDefaults.suite("ewtest.\(UUID().uuidString)")!
      d.set(true, forKey: "hasCompletedOnboarding")  // completed before the new key existed
      let s = SettingsManager(defaults: d)  // init backfills
      #expect(s.onboardingEverCompleted == true)
    }

    @Test("step_blocked payload")
    func stepBlockedPayload() {
      withHook { events in
        TelemetryService.shared.onboardingStepBlocked(
          step: "mic_permission", reason: "denied", permission: "microphone", durationSeconds: 1.5)
        let b = events.named("onboarding.step_blocked")
        #expect(b.count == 1)
        #expect(b.first?.stringProps["step"] == "mic_permission")
        #expect(b.first?.stringProps["reason"] == "denied")
        #expect(b.first?.stringProps["permission"] == "microphone")
      }
    }

    @Test("step_completed now carries duration_seconds")
    func stepCompletedDuration() {
      withHook { events in
        TelemetryService.shared.onboardingStepCompleted(
          step: "model_download", result: "completed", durationSeconds: 2.0)
        let c = events.named("onboarding.step_completed")
        #expect(c.count == 1)
        // #2980: Double, the same type as `$value`; never a formatted String.
        #expect(c.first?.doubleProps["duration_seconds"] == 2.0)
        #expect(c.first?.doubleProps["$value"] == 2.0)
        #expect(c.first?.stringProps["duration_seconds"] == nil)
      }
    }

    @Test("Practice step results carry a boolean for whether polish produced the delivered text")
    func practicePolishPayload() {
      withHook { events in
        TelemetryService.shared.onboardingStepCompleted(
          step: "practice_dictation", result: "completed", polishRan: false)
        let event = events.named("onboarding.step_completed").first
        #expect(event?.boolProps["polish_ran"] == false)
        #expect(event?.stringProps["polish_ran"] == nil)
      }
    }

    @Test("activeChecklistStep reports the real beat from the observable statuses")
    func activeChecklistStepDerivation() {
      // #1176 cloud Codex r4: the abandon must report the real checklist beat, not a
      // coarse "model_setup" — derived from the @Published checklistStatuses.
      let vm = OnboardingV2ViewModel()
      #expect(vm.activeChecklistStep == "model_download")  // all pending
      vm.checklistStatuses = [.completed, .inProgress, .pending]
      #expect(vm.activeChecklistStep == "ai_config")
      vm.checklistStatuses = [.completed, .completed, .inProgress]
      #expect(vm.activeChecklistStep == "hotkey_config")
      vm.checklistStatuses = [.completed, .completed, .completed]
      #expect(vm.activeChecklistStep == "hotkey_config")  // all done → last beat
    }

    @Test("step_completed duration is floored at the session start (reused-window staleness)")
    func stepDurationClampedToSession() {
      // #1176 cloud Codex r4: the permissions completeStep fires outside startSetup, so a
      // reused-window reopen leaves stepStartedAt stale; flooring at the session start
      // clamps the duration to time-in-this-session instead of inflating by the closed time.
      withHook { events in
        let vm = OnboardingV2ViewModel()
        vm.stepStartedAt = Date(timeIntervalSinceNow: -3600)  // stale: 1h ago (window was closed)
        let sessionStart = Date(timeIntervalSinceNow: -2)  // this session began ~2s ago
        vm.sessionStartFloor = { sessionStart }
        vm.completeStep("accessibility_permission", result: "granted")
        let dur =
          events.named("onboarding.step_completed").first?.doubleProps["duration_seconds"] ?? 0
        #expect(dur < 60)  // clamped to the session, not the stale ~3600
      }
    }

    @Test("step_completed uses the live step clock on the forward path (floor does not over-clamp)")
    func stepDurationForwardPathUnclamped() {
      withHook { events in
        let vm = OnboardingV2ViewModel()
        // Forward path: the step started AFTER the session began → use the step clock.
        vm.sessionStartFloor = { Date(timeIntervalSinceNow: -100) }  // session began long ago
        vm.stepStartedAt = Date(timeIntervalSinceNow: -3)  // this step started 3s ago
        vm.completeStep("model_download", result: "completed")
        let dur =
          events.named("onboarding.step_completed").first?.doubleProps["duration_seconds"] ?? 0
        #expect(dur >= 2 && dur < 20)  // ~3s (the step clock), NOT 100s (the floor)
      }
    }
  }

#endif
