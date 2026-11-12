import SwiftUI

/// The onboarding window's root and every environment value its screens read (#4528 C2c.2c:
/// moved out of WisprBootstrapper so the bootstrapper does not grow; chunk D hosts the new screens
/// here).
struct OnboardingWindowRoot: View {
  let b: WisprBootstrapper

  var body: some View {
    OnboardingV2View(
      onComplete: { b.appWindowCoordinator.closeOnboardingWindow() },
      onboardingProgress: b.onboardingProgress
    )
    .environment(b.navigationCoordinator)
    .environment(b.languageSuggestionPresenter)
    .environment(b.dictationRuntime)
    // #4528 C2c.2: the old workflow reports its long-lived tasks to Setup's owner.
    .environment(b.onboardingWorkflow)
    // #3546: the warming screen's retry reaches the Parakeet upgrade policy.
    .environment(b.modelDelivery)
    // #2196 — the practice screen reads BOTH of these, and a type-based
    // `@Environment` with no default TRAPS AT RUNTIME rather than failing to
    // compile. Cloud review caught this as a P1: `liveRecordingState` was added
    // here when the screen started reading it, and `transcriptCoordinator` was
    // added to the SCREEN a round later without coming back to this list. The
    // Live UAT that would have caught it ran before that round.
    .environment(b.transcriptCoordinator)
    // The practice screen needs to know a take is in flight.
    // `LiveRecordingState.isDictationActive` is true while EITHER pipeline is
    // recording, transcribing or polishing, and it is already @Observable, so
    // the screen reads an existing signal rather than growing a new one. The
    // main window has had this injected all along; onboarding never needed it
    // until it hosted a dictation target.
    .environment(b.liveRecordingState)
    .environment(b.appWindowCoordinator)
    // The nine view-facing homes (epic #763).
    .environment(b.settings)
    .environment(b.permissions)
    .environment(b.customWordsCoordinator)
    .environment(b.setup)
    .environment(b.audioDeviceList)
    .environment(b.aiAvailability)
    .environment(b.llmDiscovery)
    // #4353 D6: the cloud model list the model menus and labels read.
    .environment(b.cloudModelList)
    .environment(b.polishSetup.savedKeyPresence)
    .environment(b.polishSetup.monitor)
    .environment(b.polishSetup.summary)
    .environment(\.asrManager, b.asrManager)
    .environment(\.activeEngine, b.activeEngine)
    .environment(\.keychainManager, b.keychainManager)
  }
}
