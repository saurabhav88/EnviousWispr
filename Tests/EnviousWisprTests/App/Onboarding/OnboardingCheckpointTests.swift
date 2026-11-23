import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// #4528 C1: Setup resumes where the person left it, and never reopens once finished.
///
/// **Product Outcome.** When this fails, a person who quit mid-Setup starts over or repeats
/// downloads, a finished person sees Setup again, a Diagnostics restart cannot reopen Setup, or a
/// stale "ready" fact lets practice open before the engine works.
@MainActor
@Suite(.tags(.productOutcome))
struct OnboardingCheckpointTests {
  private static func freshSuite() -> UserDefaults {
    let name = "ew.onboarding.checkpoint.\(UUID().uuidString)"
    let defaults = TestDefaults.suite(name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  private static func midway() -> OnboardingFlowState {
    var s = OnboardingFlowState()
    s.step = .downloads
    s.choices.languageMode = .locked("de")
    s.choices.speech = .whisper
    s.choices.polish = "eg1.mini"
    s.readiness.speechInstalled = true
    s.readiness.microphoneGranted = true
    return s
  }

  private static func data(_ state: OnboardingFlowState) throws -> Data {
    try OnboardingCheckpoint(
      state: state, startedAt: Date(timeIntervalSince1970: 100),
      savedAt: Date(timeIntervalSince1970: 200)
    ).encoded()
  }

  private static func resolve(
    _ legacy: OnboardingState, _ data: Data?, saved: OnboardingChoices = OnboardingChoices()
  ) -> OnboardingRestore {
    OnboardingRestore.resolve(
      legacyState: legacy, checkpointData: data,
      recommend: { _ in
        OnboardingRecommended(speech: .parakeet, polish: "eg1.mini", rulesVersion: "r1")
      },
      saved: saved)
  }

  /// Grants, then speech and polish ready for exactly these picks.
  private static func walkToPractice(
    _ start: OnboardingFlowState, speech: ASRBackendType, polish: String
  ) -> OnboardingStep {
    var granted = OnboardingReadiness()
    granted.microphoneGranted = true
    granted.accessibilityGranted = true
    var state = OnboardingFlow.reduce(start, .readinessChanged(granted)).state
    state = OnboardingFlow.reduce(state, .next).state
    var ready = granted
    ready.speech = speech
    ready.speechInstalled = true
    ready.engineWarm = true
    ready.polish = polish
    ready.polishReady = true
    return OnboardingFlow.reduce(state, .readinessChanged(ready)).state.step
  }

  @Test("a restored Downloads inspection returns to the interrupted recovery screen")
  func restoresDownloadOrigin() throws {
    var source = Self.midway()
    source.step = .polishSeeAll
    source.recoveringReadiness = true
    let opened = OnboardingFlow.reduce(source, .inspectDownloads).state
    guard case .resume(let restored, _) = Self.resolve(.settingUp, try Self.data(opened)) else {
      Issue.record("expected restored Downloads")
      return
    }
    let returned = OnboardingFlow.reduce(restored, .next).state
    #expect(returned.step == .polishSeeAll && returned.recoveringReadiness)
    #expect(returned.downloadsReturn == nil && returned.choices == source.choices)
    #expect(!returned.isReadyForPractice)
  }

  @Test("a saved checkpoint resumes at its step with the choices and no readiness")
  func resumesWithChoicesOnly() throws {
    guard
      case .resume(let state, let startedAt) = Self.resolve(
        .settingUp, try Self.data(Self.midway()))
    else {
      Issue.record("expected resume")
      return
    }
    #expect(state.step == .downloads && state.choices == Self.midway().choices)
    #expect(state.readiness == OnboardingReadiness())
    #expect(startedAt == Date(timeIntervalSince1970: 100))
    #expect(
      state.recommended
        == OnboardingRecommended(speech: .parakeet, polish: "eg1.mini", rulesVersion: "r1"))
  }

  @Test("the saved bytes hold only step, choices, practice outcome and times")
  func storesNoReadinessOrSecrets() throws {
    let object =
      try JSONSerialization.jsonObject(with: try Self.data(Self.midway())) as? [String: Any]
    #expect(
      Set(object?.keys.map { $0 } ?? [])
        == ["version", "step", "choices", "startedAt", "savedAt"])
    let choices = object?["choices"] as? [String: Any]
    #expect(Set(choices?.keys.map { $0 } ?? []) == ["languageMode", "speech", "polish"])
  }

  @Test("completed never opens Setup, even with a leftover checkpoint")
  func completedWins() throws {
    #expect(Self.resolve(.completed, try Self.data(Self.midway())) == .completed)
    #expect(Self.resolve(.completed, nil) == .completed)
  }

  @Test("an interrupted completion finishes with its practice outcome instead of repeating Setup")
  func interruptedCompletionFinishes() throws {
    var done = Self.midway()
    done.step = .done
    done.practiceOutcome = .succeeded
    #expect(Self.resolve(.needsPermissions, try Self.data(done)) == .finishCompletion(.succeeded))
  }

  @Test("Restart Onboarding deletes the checkpoint, so Setup opens at Welcome")
  func restartDeletesTheCheckpoint() throws {
    var done = Self.midway()
    done.step = .done
    for checkpoint in [Self.midway(), done] {
      let settings = SettingsManager(defaults: Self.freshSuite())
      settings.onboardingState = .needsPermissions
      settings.onboardingCheckpointData = try Self.data(checkpoint)
      settings.restartOnboarding()
      #expect(settings.onboardingState == .notStarted && settings.onboardingCheckpointData == nil)
      #expect(Self.resolve(settings.onboardingState, settings.onboardingCheckpointData) == .fresh)
    }
    let legacy = SettingsManager(defaults: Self.freshSuite())
    legacy.onboardingCheckpointData = try Self.data(Self.midway())
    legacy.hasCompletedOnboarding = false
    #expect(legacy.onboardingCheckpointData == nil)
  }

  @Test("finishing Setup deletes the checkpoint")
  func completionDeletesTheCheckpoint() throws {
    let settings = SettingsManager(defaults: Self.freshSuite())
    settings.onboardingCheckpointData = try Self.data(Self.midway())
    settings.onboardingState = .completed
    #expect(settings.onboardingCheckpointData == nil)
  }

  @Test("a person mid-way through the old Setup reaches practice with the engines they saved")
  func legacyResumeReachesPractice() {
    var saved = OnboardingChoices()
    saved.speech = .whisper
    saved.polish = "appleIntelligence"
    guard case .resume(let state, _) = Self.resolve(.needsPermissions, nil, saved: saved) else {
      Issue.record("expected resume")
      return
    }
    #expect(state.choices.speech == .whisper && state.choices.polish == "appleIntelligence")
    #expect(Self.walkToPractice(state, speech: .whisper, polish: "appleIntelligence") == .practice)
    #expect(Self.walkToPractice(state, speech: .parakeet, polish: "appleIntelligence") != .practice)

    guard case .resume(let recommended, _) = Self.resolve(.needsPermissions, nil) else {
      Issue.record("expected resume")
      return
    }
    #expect(recommended.choices.speech == .parakeet && recommended.choices.polish == "eg1.mini")
    #expect(Self.walkToPractice(recommended, speech: .parakeet, polish: "eg1.mini") == .practice)
  }

  @Test("no checkpoint, unreadable bytes or a newer version start at Welcome")
  func unreadableStartsFresh() throws {
    #expect(Self.resolve(.notStarted, nil) == .fresh)
    #expect(Self.resolve(.settingUp, nil) == .fresh)
    #expect(Self.resolve(.settingUp, Data("not json".utf8)) == .fresh)
    var newer = OnboardingCheckpoint(state: Self.midway(), startedAt: .now, savedAt: .now)
    newer.version = OnboardingCheckpoint.currentVersion + 1
    #expect(Self.resolve(.settingUp, try newer.encoded()) == .fresh)
  }

  @Test("SettingsManager keeps the checkpoint in the shared settings store and clears it")
  func settingsStorage() throws {
    let suite = Self.freshSuite()
    let bytes = try Self.data(Self.midway())
    let settings = SettingsManager(defaults: suite)
    #expect(settings.onboardingCheckpointData == nil)
    settings.onboardingCheckpointData = bytes
    #expect(suite.data(forKey: "ew.onboarding.checkpoint.v1") == bytes)
    #expect(SettingsManager(defaults: suite).onboardingCheckpointData == bytes)
    settings.onboardingCheckpointData = nil
    #expect(suite.object(forKey: "ew.onboarding.checkpoint.v1") == nil)
    #expect(SettingsManager.unifiedDefaultsKeys.contains("ew.onboarding.checkpoint.v1"))
  }

  // MARK: - #4845 Skip ahead

  @Test("a saved Skip ahead resumes for the same pick and Practice still waits for speech")
  func skipAheadResumes() throws {
    // When this fails, a person who quit during practice must wait for the polish download again,
    // or practice opens before the speech engine works.
    var practice = OnboardingFlowState()
    practice.step = .practice
    practice.choices.speech = .parakeet
    practice.choices.polish = "eg1.mini"
    practice.deferredPolish = "eg1.mini"
    guard case .resume(let restored, _) = Self.resolve(.needsPermissions, try Self.data(practice))
    else {
      Issue.record("expected a resume")
      return
    }
    #expect(restored.step == .practice && restored.deferredPolish == "eg1.mini")
    #expect(restored.readiness == OnboardingReadiness())
    #expect(OnboardingFlow.reduce(restored, .practiceSucceeded).outcome
      == .refused("not ready for practice"))
    var speechReady = OnboardingReadiness()
    speechReady.microphoneGranted = true
    speechReady.accessibilityGranted = true
    speechReady.speech = .parakeet
    speechReady.speechInstalled = true
    speechReady.engineWarm = true
    let measured = OnboardingFlow.reduce(restored, .readinessChanged(speechReady)).state
    #expect(OnboardingFlow.reduce(measured, .practiceSucceeded).state.step == .film)
  }

  @Test("a checkpoint written before Skip ahead existed reads as no Skip ahead")
  func legacyCheckpointHasNoSkipAhead() {
    // When this fails, an update makes Setup unreadable or opens Practice without polish.
    let legacy = Data(
      #"{"choices":{"polish":"eg1.mini","speech":"parakeet"},"savedAt":200,"startedAt":100,"step":"practice","version":1}"#
        .utf8)
    guard case .resume(let restored, _) = Self.resolve(.needsPermissions, legacy) else {
      Issue.record("expected a resume")
      return
    }
    #expect(restored.step == .practice && restored.deferredPolish == nil)
  }

  @Test("a saved Skip ahead for another or a non-downloading pick grants nothing")
  func mismatchedSkipAheadIsDropped() {
    // When this fails, a hand-edited or stale checkpoint skips a model the person did not skip.
    for (deferred, polish) in [("eg1.full", "eg1.mini"), ("appleIntelligence", "appleIntelligence")] {
      let bytes = Data(
        """
        {"choices":{"polish":"\(polish)","speech":"parakeet"},"deferredPolish":"\(deferred)",\
        "savedAt":200,"startedAt":100,"step":"practice","version":1}
        """.utf8)
      guard case .resume(let restored, _) = Self.resolve(.needsPermissions, bytes) else {
        Issue.record("expected a resume for \(deferred)")
        continue
      }
      #expect(restored.deferredPolish == nil, "\(deferred) / \(polish)")
    }
  }
}
