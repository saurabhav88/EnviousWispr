import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #4528 C1: the new Setup's pure flow (plan §3.3.1 transition table).
///
/// **Product Outcome.** When this fails, a person gets stuck on a Setup screen, skips Permissions,
/// reaches practice before the engine they picked is ready, downloads a model they did not pick,
/// or loses their place after a quit.
@Suite(.tags(.productOutcome))
struct OnboardingFlowTests {
  private static let allEvents: [OnboardingEvent] = [
    .next, .back, .chooseLanguage(.auto), .chooseLanguage(.locked("de")), .compareSpeech,
    .chooseSpeech(.parakeet), .chooseSpeech(.whisper), .seeAllPolish, .choosePolish("eg1.mini"),
    .choosePolish("appleIntelligence"), .choosePolish(OnboardingChoices.polishCloud),
    .chooseCloud(.openAI, model: "gpt-4o-mini"), .skipPolish,
    .turnPolishOn, .continueWithoutPolish, .reviewPermissions,
    .changeSpeech, .changePolish, .reviewCloudKey, .returnToGettingReady, .inspectDownloads,
    .readinessChanged(OnboardingReadiness()), .readinessChanged(granted()),
    .practiceSucceeded, .skipPractice, .filmFinished, .skipFilm,
  ]

  private static func granted() -> OnboardingReadiness {
    var r = OnboardingReadiness()
    r.microphoneGranted = true
    r.accessibilityGranted = true
    return r
  }

  private static func ready(speech: ASRBackendType, polish: String?) -> OnboardingReadiness {
    var r = granted()
    r.speech = speech
    r.speechInstalled = true
    r.engineWarm = true
    r.polish = polish
    r.polishReady = polish != nil
    if polish == OnboardingChoices.polishCloud {
      r.cloudProvider = .openAI
      r.cloudModel = "gpt-4o-mini"
    }
    return r
  }

  private static func at(_ step: OnboardingStep) -> OnboardingFlowState {
    var s = OnboardingFlowState()
    s.step = step
    return s
  }

  /// Applies events in order, requiring each to have the expected outcome kind.
  private static func run(
    _ start: OnboardingFlowState, _ events: [OnboardingEvent]
  ) -> (OnboardingFlowState, [OnboardingEffect]) {
    var state = start
    var effects: [OnboardingEffect] = []
    for event in events {
      let t = OnboardingFlow.reduce(state, event)
      state = t.state
      effects += t.effects
    }
    return (state, effects)
  }

  // MARK: - Whole-table properties

  @Test("every move saves the checkpoint first, and refusals and no-ops change nothing")
  func everyMovePersistsFirst() {
    for step in OnboardingStep.allCases {
      for event in Self.allEvents {
        let start = Self.at(step)
        let t = OnboardingFlow.reduce(start, event)
        switch t.outcome {
        case .moved:
          #expect(t.effects.first == .persistCheckpoint, "\(step) + \(event)")
          #expect(t.state.step != step || event == .back, "\(step) + \(event) moved nowhere")
        case .refused:
          #expect(t.state == start && t.effects.isEmpty, "\(step) + \(event)")
        case .noOp:
          #expect(t.state.step == step, "\(step) + \(event) changed step on a no-op")
        }
      }
    }
  }

  @Test("done ignores every event")
  func doneIsTerminal() {
    for event in Self.allEvents {
      let t = OnboardingFlow.reduce(Self.at(.done), event)
      #expect(t.outcome == .noOp && t.effects.isEmpty && t.state == Self.at(.done), "\(event)")
    }
  }

  @Test("every step can be reached from Welcome")
  func everyStepReachable() {
    struct Route: Hashable {
      let step: OnboardingStep
      let downloadsReturn: OnboardingStep?
      let recovering: Bool

      init(_ state: OnboardingFlowState) {
        step = state.step
        downloadsReturn = state.downloadsReturn
        recovering = state.recoveringReadiness
      }
    }
    let start = OnboardingFlowState()
    var seen: Set<OnboardingStep> = [start.step]
    var visited: Set<Route> = [Route(start)]
    var frontier = [start]
    // Every pick the event list can make, so practice opens whichever picks the walk reached.
    let picks: [String?] = ["eg1.mini", "appleIntelligence", OnboardingChoices.polishCloud, nil]
    let readiness: [OnboardingEvent] = [ASRBackendType.parakeet, .whisper].flatMap { speech in
      picks.map { .readinessChanged(Self.ready(speech: speech, polish: $0)) }
    }
    let events = Self.allEvents + readiness
    while let state = frontier.popLast() {
      for event in events {
        let next = OnboardingFlow.reduce(state, event).state
        seen.insert(next.step)
        if visited.insert(Route(next)).inserted { frontier.append(next) }
      }
    }
    #expect(seen == Set(OnboardingStep.allCases))
  }

  @Test("the legacy coarse state follows the step")
  func legacyProjection() {
    let expected: [OnboardingStep: OnboardingState] = [
      .welcome: .notStarted, .language: .notStarted,
      .speechPick: .settingUp, .speechCompare: .settingUp, .polishIntro: .settingUp,
      .polishPick: .settingUp, .polishSeeAll: .settingUp, .downloads: .settingUp,
      .permissions: .needsPermissions, .key: .needsPermissions, .gettingReady: .needsPermissions,
      .practice: .needsPermissions, .film: .needsPermissions, .done: .completed,
    ]
    #expect(Set(expected.keys) == Set(OnboardingStep.allCases))
    for (step, state) in expected { #expect(Self.at(step).legacyState == state, "\(step)") }
  }

  // MARK: - Paths

  @Test("continuing with the recommendations downloads them and finishes after the film")
  func recommendedPath() {
    var start = OnboardingFlowState()
    start.recommended.speech = .parakeet
    start.recommended.polish = "eg1.mini"
    let (afterPicks, picks) = Self.run(start, [.next, .next, .next, .next, .next, .next])
    #expect(afterPicks.step == .permissions)
    #expect(afterPicks.choices.speech == .parakeet && afterPicks.choices.polish == "eg1.mini")
    #expect(
      picks.filter { $0 != .persistCheckpoint } == [
        .startSpeechDownload(.parakeet), .startPolishDownload("eg1.mini"),
      ])

    let (end, rest) = Self.run(
      afterPicks,
      [
        .readinessChanged(Self.granted()), .next,
        .readinessChanged(Self.ready(speech: .parakeet, polish: "eg1.mini")),
        .practiceSucceeded, .filmFinished,
      ])
    #expect(end.step == .done && end.practiceOutcome == .succeeded)
    #expect(
      rest.filter { $0 != .persistCheckpoint } == [
        .recordPracticeOutcome(.succeeded), .markCompleted,
      ])
  }

  @Test("Permissions refuses Continue until both grants arrive, then opens the key screen")
  func permissionsGate() {
    let t = OnboardingFlow.reduce(Self.at(.permissions), .next)
    #expect(t.outcome == .refused("microphone and accessibility are not both granted"))
    var mic = OnboardingReadiness()
    mic.microphoneGranted = true
    #expect(
      OnboardingFlow.reduce(Self.at(.permissions), .readinessChanged(mic)).state.step
        == .permissions)
    #expect(
      OnboardingFlow.reduce(Self.at(.permissions), .readinessChanged(Self.granted())).state.step
        == .key)
  }

  @Test("readiness for a previous pick never opens practice")
  func readinessIsAttributedToTheCurrentPick() {
    var s = Self.at(.gettingReady)
    s.choices.speech = .whisper
    s.choices.polish = "eg1.mini"
    let stale = OnboardingFlow.reduce(
      s, .readinessChanged(Self.ready(speech: .parakeet, polish: "eg1.mini")))
    #expect(stale.state.step == .gettingReady)
    #expect(OnboardingFlow.reduce(stale.state, .next).outcome == .refused("not ready for practice"))
    let stalePolish = OnboardingFlow.reduce(
      s, .readinessChanged(Self.ready(speech: .whisper, polish: "eg1.full")))
    #expect(stalePolish.state.step == .gettingReady)
    let fresh = OnboardingFlow.reduce(
      s, .readinessChanged(Self.ready(speech: .whisper, polish: "eg1.mini")))
    #expect(fresh.state.step == .practice)
  }

  @Test("a new language or engine pick clears the old ready facts and keeps the grants")
  func changedPickClearsReadiness() {
    var s = Self.at(.speechPick)
    s.choices.speech = .parakeet
    s.choices.polish = "eg1.mini"
    s.readiness = Self.ready(speech: .parakeet, polish: "eg1.mini")
    let sameEngine = OnboardingFlow.reduce(s, .chooseSpeech(.parakeet)).state
    #expect(sameEngine.readiness == s.readiness)
    let newEngine = OnboardingFlow.reduce(s, .chooseSpeech(.whisper)).state.readiness
    #expect(newEngine.speech == nil && !newEngine.speechInstalled && !newEngine.engineWarm)
    #expect(newEngine.polishReady && newEngine.permissionsGranted)

    var lang = s
    lang.step = .language
    lang.choices.languageMode = .auto
    let newLanguage = OnboardingFlow.reduce(lang, .chooseLanguage(.locked("de"))).state.readiness
    #expect(newLanguage.speech == nil && newLanguage.permissionsGranted)

    var polish = s
    polish.step = .polishPick
    let newPolish = OnboardingFlow.reduce(polish, .choosePolish("eg1.full")).state.readiness
    #expect(newPolish.polish == nil && !newPolish.polishReady && newPolish.engineWarm)
    let skipped = OnboardingFlow.reduce(polish, .skipPolish).state.readiness
    #expect(skipped.polish == nil && !skipped.polishReady)
  }

  @Test("Skip AI polish downloads no polish model and practice needs only speech")
  func skipPolish() {
    var s = Self.at(.polishPick)
    s.choices.speech = .parakeet
    let t = OnboardingFlow.reduce(s, .skipPolish)
    #expect(t.state.step == .downloads && t.state.choices.polish == OnboardingChoices.polishOff)
    #expect(t.effects == [.persistCheckpoint])
    var ready = t.state
    ready.step = .key
    ready.readiness = Self.ready(speech: .parakeet, polish: nil)
    #expect(OnboardingFlow.reduce(ready, .next).state.step == .practice)
  }

  @Test("Apple Intelligence downloads nothing; a local model does")
  func onlyLocalModelsDownload() {
    for (id, downloads) in [("appleIntelligence", false), ("eg1.full", true), ("s1mini", true)] {
      let t = OnboardingFlow.reduce(Self.at(.polishSeeAll), .choosePolish(id))
      #expect(t.state.step == .downloads, "\(id)")
      #expect(t.effects.contains(.startPolishDownload(id)) == downloads, "\(id)")
    }
  }

  @Test("a cloud pick names its provider and model, downloads nothing, and needs a check for that pick")
  func cloudPick() {
    #expect(
      OnboardingFlow.reduce(Self.at(.polishSeeAll), .choosePolish(OnboardingChoices.polishCloud))
        .outcome == .refused("a cloud pick names its provider and model"))
    // Setup offers only key-based cloud providers: Ollama and the local providers are refused.
    for provider in [LLMProvider.ollama, .none, .egOne, .appleIntelligence] {
      #expect(
        OnboardingFlow.reduce(Self.at(.polishSeeAll), .chooseCloud(provider, model: "m")).outcome
          == .refused("Setup's cloud polish is OpenAI, Gemini or Claude"), "accepted \(provider)")
    }
    var start = Self.at(.polishSeeAll)
    start.choices.speech = .parakeet
    let t = OnboardingFlow.reduce(start, .chooseCloud(.openAI, model: "gpt-4o-mini"))
    #expect(t.state.step == .downloads && t.effects == [.persistCheckpoint])
    #expect(t.state.choices.polish == OnboardingChoices.polishCloud)
    #expect(t.state.choices.cloudProvider == .openAI && t.state.choices.cloudModel == "gpt-4o-mini")

    var waiting = t.state
    waiting.step = .gettingReady
    var other = Self.ready(speech: .parakeet, polish: OnboardingChoices.polishCloud)
    other.cloudModel = "gpt-4o"
    #expect(OnboardingFlow.reduce(waiting, .readinessChanged(other)).state.step == .gettingReady)
    other.cloudModel = "gpt-4o-mini"
    other.cloudProvider = .claude
    #expect(OnboardingFlow.reduce(waiting, .readinessChanged(other)).state.step == .gettingReady)
    let checked = Self.ready(speech: .parakeet, polish: OnboardingChoices.polishCloud)
    #expect(OnboardingFlow.reduce(waiting, .readinessChanged(checked)).state.step == .practice)

    // A different provider or model clears the old check; a local pick clears the cloud fields.
    var seeAll = waiting
    seeAll.step = .polishSeeAll
    seeAll.readiness = checked
    let switched = OnboardingFlow.reduce(seeAll, .chooseCloud(.openAI, model: "gpt-4o")).state
    #expect(switched.readiness.cloudModel == nil && !switched.readiness.polishReady)
    let same = OnboardingFlow.reduce(seeAll, .chooseCloud(.openAI, model: "gpt-4o-mini")).state
    #expect(same.readiness == checked)
    // Back from Downloads, then Continue on the polish picks, keeps the cloud pick and its check.
    var downloads = seeAll
    downloads.step = .downloads
    let back = OnboardingFlow.reduce(downloads, .back).state
    let resumed = OnboardingFlow.reduce(back, .next).state
    #expect(resumed.step == .downloads && resumed.choices == seeAll.choices)
    #expect(resumed.readiness == checked)
    let local = OnboardingFlow.reduce(seeAll, .choosePolish("eg1.mini")).state
    #expect(local.choices.cloudProvider == nil && local.choices.cloudModel == nil)
  }

  @Test("choosing a language stays on the language screen and saves it")
  func languageChoiceSaves() {
    let t = OnboardingFlow.reduce(Self.at(.language), .chooseLanguage(.locked("de")))
    #expect(t.state.step == .language && t.state.choices.languageMode == .locked("de"))
    #expect(t.effects == [.persistCheckpoint])
  }

  @Test("Turn on AI polish from the downloads screen returns to the polish picks")
  func turnPolishOnFromDownloads() {
    #expect(OnboardingFlow.reduce(Self.at(.downloads), .turnPolishOn).state.step == .polishPick)
  }

  @Test("a take on a resumed Practice counts only once the current picks are ready")
  func practiceNeedsCurrentReadiness() {
    var s = Self.at(.practice)
    s.choices.speech = .parakeet
    s.choices.polish = OnboardingChoices.polishOff
    #expect(OnboardingFlow.reduce(s, .practiceSucceeded).outcome == .refused("not ready for practice"))
    s.readiness = Self.ready(speech: .parakeet, polish: nil)
    #expect(OnboardingFlow.reduce(s, .practiceSucceeded).state.step == .film)
  }

  @Test("Skip practice records the skip and still plays the closing film, which ends Setup")
  func skipPractice() {
    // When this fails, a person who skips the practice take never sees the closing film.
    let t = OnboardingFlow.reduce(Self.at(.practice), .skipPractice)
    #expect(t.state.step == .film && t.state.practiceOutcome == .skipped)
    #expect(t.effects == [.persistCheckpoint, .recordPracticeOutcome(.skipped)])
    let end = OnboardingFlow.reduce(t.state, .skipFilm)
    #expect(end.state.step == .done && end.effects.contains(.markCompleted))
    #expect(
      OnboardingFlow.reduce(Self.at(.practice), .next).outcome
        == .refused("practice ends with a take or Skip practice"))
  }

  @Test("Back returns to the previous screen and does nothing on Welcome, the film and done")
  func backMap() {
    let expected: [OnboardingStep: OnboardingStep?] = [
      .welcome: nil, .language: .welcome, .speechPick: .language, .speechCompare: .speechPick,
      .polishIntro: .speechPick, .polishPick: .polishIntro, .polishSeeAll: .polishPick,
      .downloads: .polishPick, .permissions: .downloads, .key: .permissions, .gettingReady: .key,
      .practice: .key, .film: nil, .done: nil,
    ]
    #expect(Set(expected.keys) == Set(OnboardingStep.allCases))
    for (step, previous) in expected {
      let t = OnboardingFlow.reduce(Self.at(step), .back)
      if let previous {
        #expect(t.outcome == .moved && t.state.step == previous, "\(step)")
      } else {
        #expect(t.outcome == .noOp && t.state.step == step, "\(step)")
      }
    }
  }
}
