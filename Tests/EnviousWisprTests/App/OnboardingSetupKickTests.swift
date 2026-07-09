import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

#if DEBUG

  /// #1388 (UAT-found, latent on main) — the onboarding install workflow is
  /// owned by the view model (`kickSetupIfNeeded` / `setupTask`), not the
  /// view's `.task`. Before this, window churn mid-install cancelled the view
  /// task; the warm-up outcome was dropped and the replacement task's
  /// `.pending` guard refused re-entry — checklist frozen on step 1 forever.
  /// These tests lock the ownership contract: a live workflow makes re-kicks
  /// a no-op, and the workflow drives the checklist to completion regardless
  /// of what happened to its kicker.
  @MainActor
  @Suite("Onboarding setup kick", .serialized)
  struct OnboardingSetupKickTests {

    @MainActor
    private final class Counter {
      var value = 0
    }

    /// A SettingsManager backed by a fresh ephemeral suite (never touches the
    /// real shared store).
    private func makeSettings() -> SettingsManager {
      SettingsManager(defaults: UserDefaults(suiteName: "ewtest.\(UUID().uuidString)")!)
    }

    private func makeReadyViewModel() -> OnboardingV2ViewModel {
      let vm = OnboardingV2ViewModel()
      vm.currentScreen = .settingUp
      vm.setupPhase = .checklist
      return vm
    }

    @Test(
      "re-kick while the workflow is live is a no-op, and the owned workflow completes (churn-freeze regression)"
    )
    func kickIsSingleFlightAndSurvivesKicker() async throws {
      let vm = makeReadyViewModel()
      let settings = makeSettings()
      let warmUpCalls = Counter()
      // Signal-gated warm-up: suspends until the test releases the gate, so
      // the mid-install re-kick lands while the workflow is genuinely live.
      let (gate, gateCont) = AsyncStream.makeStream(of: Void.self)

      vm.kickSetupIfNeeded(
        warmUp: {
          warmUpCalls.value += 1
          var it = gate.makeAsyncIterator()
          _ = await it.next()
          return .ready
        },
        settings: settings)
      let workflow = vm.setupTask
      #expect(workflow != nil)
      // The owned Task is enqueued, not yet running — yield until the workflow
      // has genuinely entered the install (signal: statuses flip inProgress),
      // so the re-kick below lands mid-install, not before the start line.
      var spins = 0
      while !vm.checklistStatuses[0].isInProgress, spins < 10_000 {
        await Task.yield()
        spins += 1
      }
      #expect(vm.checklistStatuses[0].isInProgress)

      // The churn: the view re-appears and kicks again mid-install. Must be a
      // no-op — before the fix the equivalent path left the checklist frozen.
      vm.kickSetupIfNeeded(warmUp: { .ready }, settings: settings)
      #expect(warmUpCalls.value == 1)

      gateCont.yield(())
      await workflow?.value
      #expect(warmUpCalls.value == 1)
      #expect(vm.checklistStatuses == [.completed, .completed, .completed])
      #expect(vm.setupPhase == .permissions)
      #expect(settings.onboardingState == .needsPermissions)
      #expect(vm.setupTask == nil)
    }

    @Test("cancelled outcome pauses calmly; auto re-kick stays paused; retry re-arms")
    func cancelledPausesAndRetryRearms() async throws {
      let vm = makeReadyViewModel()
      let settings = makeSettings()

      vm.kickSetupIfNeeded(warmUp: { .cancelled }, settings: settings)
      // The instant "Cancelling…" acknowledgment a real press would set.
      vm.cancelRequested = true
      let first = vm.setupTask
      await first?.value
      #expect(vm.setupCancelled)
      #expect(!vm.cancelRequested)
      #expect(vm.checklistStatuses == [.pending, .pending, .pending])
      #expect(vm.downloadError == nil)
      #expect(vm.setupTask == nil)

      // A churn re-kick after the Cancel must NOT restart the install — only
      // the user's explicit "Try setup again" may.
      vm.kickSetupIfNeeded(warmUp: { .ready }, settings: settings)
      #expect(vm.setupTask == nil)

      vm.retryDownload()
      #expect(!vm.setupCancelled)
      vm.kickSetupIfNeeded(warmUp: { .ready }, settings: settings)
      let retried = vm.setupTask
      #expect(retried != nil)
      await retried?.value
      #expect(vm.checklistStatuses == [.completed, .completed, .completed])
      #expect(vm.setupTask == nil)
    }
  }

#endif
