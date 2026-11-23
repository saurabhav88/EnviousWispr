import EnviousWisprCore
import EnviousWisprPipeline
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #4528 C2a: Setup reads readiness for the CURRENT pick from live facts.
///
/// **Product Outcome.** When this fails, practice opens before the chosen engine is warm or the
/// chosen polish model is loaded, a downloaded-but-not-loaded model counts as ready, or a key
/// checked for another provider, model or saved key counts as a passed check.
@MainActor
@Suite(.tags(.productOutcome))
struct OnboardingReadinessReaderTests {
  @MainActor
  final class Facts {
    var admitted: Set<ASRBackendType> = [.parakeet, .whisper]
    var engine: (selected: ASRBackendType, readiness: ASREngineReadiness) = (.parakeet, .ready)
    var local: [LocalPolishModelID: OnboardingLocalPolishState] = [:]
    var afm: AppleIntelligenceSetupState = .available
    var cloud: OnboardingCloudEvidence?
    var permissions = (microphone: true, accessibility: true)
    var duringAdmission: () -> Void = {}

    func sources() -> OnboardingReadinessSources {
      OnboardingReadinessSources(
        speechAdmitted: { engine in
          self.duringAdmission()
          return self.admitted.contains(engine)
        },
        engine: { self.engine },
        localPolish: { self.local[$0] },
        appleIntelligence: { self.afm },
        cloudEvidence: { provider in self.cloud?.provider == provider ? self.cloud : nil },
        permissions: { self.permissions })
    }
  }

  private static func choices(
    _ speech: ASRBackendType?, _ polish: String?, cloud: (LLMProvider, String)? = nil
  ) -> OnboardingChoices {
    var c = OnboardingChoices()
    c.speech = speech
    c.polish = polish
    c.cloudProvider = cloud?.0
    c.cloudModel = cloud?.1
    return c
  }

  private static func ready(_ choices: OnboardingChoices, _ facts: Facts) async -> Bool {
    var state = OnboardingFlowState()
    state.choices = choices
    state.readiness = await OnboardingReadinessReader.measure(choices, from: facts.sources())
    return state.isReadyForPractice
  }

  @Test("an admitted engine that is not warm, or another engine warm, is not ready")
  func admittedIsNotWarm() async {
    let facts = Facts()
    facts.engine = (.parakeet, .warming)
    let warming = await OnboardingReadinessReader.measure(
      Self.choices(.parakeet, nil), from: facts.sources())
    #expect(warming.speech == .parakeet && warming.speechInstalled && !warming.engineWarm)
    facts.engine = (.whisper, .ready)
    #expect(!(await Self.ready(Self.choices(.parakeet, OnboardingChoices.polishOff), facts)))
    facts.engine = (.parakeet, .ready)
    #expect(await Self.ready(Self.choices(.parakeet, OnboardingChoices.polishOff), facts))
  }

  @Test("a downloaded local model that is not loaded, or failing its probe, is not ready")
  func downloadedIsNotLoaded() async {
    let facts = Facts()
    let pick = Self.choices(.parakeet, "eg1.mini")
    facts.local[.egOne(.mini)] = OnboardingLocalPolishState(
      installed: true, serverReady: false, healthy: true)
    #expect(!(await Self.ready(pick, facts)))
    facts.local[.egOne(.mini)] = OnboardingLocalPolishState(
      installed: true, serverReady: true, healthy: false)
    #expect(!(await Self.ready(pick, facts)))
    facts.local[.egOne(.mini)] = OnboardingLocalPolishState(
      installed: true, serverReady: true, healthy: true)
    #expect(await Self.ready(pick, facts))
    // Another size loaded does not count for this pick.
    #expect(!(await Self.ready(Self.choices(.parakeet, "eg1.full"), facts)))
  }

  @Test("Apple Intelligence is ready only when available")
  func appleIntelligence() async {
    let facts = Facts()
    let pick = Self.choices(.parakeet, "appleIntelligence")
    #expect(await Self.ready(pick, facts))
    facts.afm = .gettingReady
    #expect(!(await Self.ready(pick, facts)))
  }

  @Test("a cloud pick is ready only with a current passed check for that provider and model")
  func cloudEvidenceIdentity() async {
    let facts = Facts()
    let pick = Self.choices(
      .parakeet, OnboardingChoices.polishCloud, cloud: (.openAI, "gpt-4o-mini"))
    func evidence(
      provider: LLMProvider = .openAI, model: String = "gpt-4o-mini", checked: UInt64 = 3,
      current: UInt64? = 3, accepted: Bool = true
    ) -> OnboardingCloudEvidence {
      OnboardingCloudEvidence(
        provider: provider, model: model, checkedRevision: checked, currentRevision: current,
        accepted: accepted)
    }
    #expect(!(await Self.ready(pick, facts)))
    facts.cloud = evidence(model: "gpt-4o")
    #expect(!(await Self.ready(pick, facts)))
    facts.cloud = evidence(provider: .claude)
    #expect(!(await Self.ready(pick, facts)))
    facts.cloud = evidence(current: 4)
    #expect(!(await Self.ready(pick, facts)))
    facts.cloud = evidence(accepted: false)
    #expect(!(await Self.ready(pick, facts)))
    facts.cloud = evidence()
    #expect(await Self.ready(pick, facts))
  }

  @Test("a grant revoked during the admission read is not reported as granted")
  func permissionsReadAfterTheAwait() async {
    let facts = Facts()
    facts.duringAdmission = { facts.permissions = (microphone: false, accessibility: true) }
    let pick = Self.choices(.parakeet, OnboardingChoices.polishOff)
    #expect(!(await Self.ready(pick, facts)))
  }

  @Test("grants are read as given, and the speech fact names the engine it measured")
  func permissionsAndIdentity() async {
    let facts = Facts()
    facts.permissions = (microphone: true, accessibility: false)
    let r = await OnboardingReadinessReader.measure(
      Self.choices(.whisper, nil), from: facts.sources())
    #expect(r.microphoneGranted && !r.accessibilityGranted && r.speech == .whisper)
    #expect(!(await Self.ready(Self.choices(.parakeet, OnboardingChoices.polishOff), facts)))
  }
}
