import EnviousWisprCore

/// Whether launch may warm the selected speech engine (#4528).
///
/// Warming Parakeet on a Mac without the model downloads it (ParakeetUpgradeCoordinator row C,
/// `foregroundUltra`). On a first launch the selected backend is only the default, so an
/// ungated warm fetched the full Parakeet model while Setup was still on Welcome, before the
/// person chose an engine; a person who then picked Whisper got a download they never asked
/// for (fresh-Mac UAT 2026-11-13). Until first-run Setup completes, Setup owns every speech
/// download and warm-up (`OnboardingDownloads.startSpeech`, the Getting ready warm), the same
/// rule the EG-1 upgrade, the word check and the Learn-from-edits judge already follow.
enum LaunchEngineWarm {
  static func allowed(selectedBackend: ASRBackendType, onboardingState: OnboardingState) -> Bool {
    selectedBackend == .parakeet && onboardingState == .completed
  }
}
