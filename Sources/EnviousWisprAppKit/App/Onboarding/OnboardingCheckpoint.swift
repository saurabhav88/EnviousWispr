import EnviousWisprCore
import Foundation

/// Where Setup resumes after a quit or crash (#4528 plan §3.3.1, "Resume").
///
/// Holds the step and the person's CHOICES only. It never holds keys, transcripts, permission
/// grants or readiness: those are re-measured live on resume, so a stale fact can never move the
/// flow. SettingsManager stores the encoded bytes opaquely (`onboardingCheckpointData`).
struct OnboardingCheckpoint: Codable, Equatable, Sendable {
  static let currentVersion = 1

  var version: Int = Self.currentVersion
  var step: OnboardingStep
  var choices: OnboardingChoices
  var practiceOutcome: OnboardingPracticeOutcome?
  var startedAt: Date
  var savedAt: Date

  init(state: OnboardingFlowState, startedAt: Date, savedAt: Date) {
    step = state.step
    choices = state.choices
    practiceOutcome = state.practiceOutcome
    self.startedAt = startedAt
    self.savedAt = savedAt
  }

  func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = .sortedKeys
    return try encoder.encode(self)
  }

  /// Nil for missing, unreadable or newer-version bytes. Never throws: a bad checkpoint means
  /// "start where the legacy state says", not a crash.
  static func decode(_ data: Data?) -> OnboardingCheckpoint? {
    guard let data else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    guard let checkpoint = try? decoder.decode(OnboardingCheckpoint.self, from: data),
      checkpoint.version == currentVersion
    else { return nil }
    return checkpoint
  }
}

/// What Setup does at launch.
enum OnboardingRestore: Equatable, Sendable {
  /// Setup never opens.
  case completed
  /// Start at Welcome with nothing chosen.
  case fresh
  /// Completion was interrupted after its checkpoint was written: finish it (state, telemetry)
  /// with the recorded practice outcome, and never show Setup again.
  case finishCompletion(OnboardingPracticeOutcome?)
  /// Open at the saved step with the saved choices; readiness starts empty and is re-measured.
  case resume(OnboardingFlowState, startedAt: Date?)
}

extension OnboardingRestore {
  /// The resume rules, in order (plan §3.3.1):
  /// 1. completed never opens Setup, whatever a leftover checkpoint says;
  /// 2. a readable `done` checkpoint means completion was interrupted, because SettingsManager
  ///    deletes the checkpoint on completion and in `restartOnboarding()` (plan M45);
  /// 3. any other readable checkpoint resumes at its step with its choices;
  /// 4. no readable checkpoint but a legacy `needsPermissions` state resumes at Permissions with
  ///    the SAVED picks (`saved`, read by C2 from settings, including a cloud provider and model),
  ///    falling back to the recommendations, so a person mid-way through the old Setup can still
  ///    reach practice;
  /// 5. otherwise Welcome.
  static func resolve(
    legacyState: OnboardingState, checkpointData: Data?,
    recommended: OnboardingRecommended, saved: OnboardingChoices
  ) -> OnboardingRestore {
    if legacyState == .completed { return .completed }
    var state = OnboardingFlowState()
    state.recommended = recommended
    if let checkpoint = OnboardingCheckpoint.decode(checkpointData) {
      if checkpoint.step == .done { return .finishCompletion(checkpoint.practiceOutcome) }
      state.step = checkpoint.step
      state.choices = checkpoint.choices
      state.practiceOutcome = checkpoint.practiceOutcome
      return .resume(state, startedAt: checkpoint.startedAt)
    }
    if legacyState == .needsPermissions {
      state.step = .permissions
      state.choices = saved
      state.choices.speech = saved.speech ?? recommended.speech
      state.choices.polish = saved.polish ?? recommended.polish
      return .resume(state, startedAt: nil)
    }
    return .fresh
  }
}
