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

    private func withHook(_ body: (Events) -> Void) {
      let events = Events()
      TelemetryService.shared.testEventHook = { @Sendable e in events.add(e) }
      defer { TelemetryService.shared.testEventHook = nil }
      body(events)
    }

    private func makeBox() -> OnboardingProgress { OnboardingProgress() }

    /// A SettingsManager backed by a fresh ephemeral suite (never touches the real
    /// shared store).
    private func makeSettings() -> SettingsManager {
      SettingsManager(defaults: UserDefaults(suiteName: "ewtest.\(UUID().uuidString)")!)
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
      let d = UserDefaults(suiteName: "ewtest.\(UUID().uuidString)")!
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
        #expect(c.first?.stringProps["duration_seconds"] == "2.000")
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
          Double(
            events.named("onboarding.step_completed").first?
              .stringProps["duration_seconds"] ?? "0") ?? 0
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
          Double(
            events.named("onboarding.step_completed").first?
              .stringProps["duration_seconds"] ?? "0") ?? 0
        #expect(dur >= 2 && dur < 20)  // ~3s (the step clock), NOT 100s (the floor)
      }
    }
  }

#endif
