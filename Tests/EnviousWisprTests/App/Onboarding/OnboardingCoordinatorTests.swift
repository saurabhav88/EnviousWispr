import EnviousWisprCore
import EnviousWisprPipeline
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// #4528 C2b: the coordinator runs the new Setup from restore to completion.
///
/// **Product Outcome.** When this fails, Setup loses the person's place, shows a step before it
/// is saved, finishes twice or never, downloads a model the person replaced, fills a full disk,
/// keeps the Mac awake after Setup, starts polish before speech on a small Mac, or freezes
/// Cancel and Back while a download is decided.
@MainActor
@Suite(.tags(.productOutcome))
struct OnboardingCoordinatorTests {
  /// Holds a request until the test opens it; opening first lets the request pass at once.
  @MainActor
  final class Gate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var opened = false
    private(set) var enteredCount = 0
    private var enteredWaiters = CountWaiters("gate entered")

    func pass() async {
      enteredCount += 1
      enteredWaiters.notify(reached: enteredCount)
      if opened { return }
      await withCheckedContinuation { waiter = $0 }
    }

    /// Waits for the signal the gate itself fires when a request arrives (the existing
    /// `CountWaiters` pattern); a request that never arrives records a failure, never hangs.
    func untilEntered() async {
      guard enteredCount < 1 else { return }
      let id = UUID()
      let net = Task { @MainActor [weak self] in
        // deadline-fallback: hang guard only; the signal is `pass()`'s notify.
        try? await Task.sleep(for: .seconds(5))
        self?.enteredWaiters.resume(id: id)
      }
      await withCheckedContinuation { enteredWaiters.install(id: id, target: 1, $0) }
      net.cancel()
    }

    func open() {
      opened = true
      waiter?.resume()
      waiter = nil
    }
  }

  /// One recorded world: owner calls, settings writes and observer calls, in order.
  @MainActor
  final class World {
    var log: [String] = []
    var legacy: OnboardingState = .notStarted
    var checkpoint: Data?
    var speechPhase: [ASRBackendType: OnboardingDownloadPhase] = [:]
    var polishPhase: [LocalPolishModelID: OnboardingDownloadPhase] = [:]
    var speechAccepted = true
    /// Engines whose request is refused, read when the request returns.
    var refusedEngines: Set<ASRBackendType> = []
    var speechGate: Gate?
    /// One gate per speech request, in order (used before `speechGate`).
    var speechGateQueue: [Gate] = []
    /// Engines whose owner answers a request with the attempt's end (Parakeet in production).
    var reportsEnd: Set<ASRBackendType> = []
    /// The ends those owners answer with, in answer order (default ok).
    var speechEnds: [OnboardingTelemetry.DownloadResult] = []
    var admissionGate: Gate?
    var parallel = true
    var free: Int64? = 100_000
    var bytes: [OnboardingModel: Int64] = [:]
    var saved = OnboardingChoices()
    /// The recommendation now (a rules refresh replaces it; a visit keeps the one it captured).
    var recommended = OnboardingRecommended(
      speech: .parakeet, polish: "eg1.mini", rulesVersion: "rules-a")
    /// Per-language advice (M73); nil falls back to `recommended`. Every read is recorded.
    var advice: (LanguageMode?) -> OnboardingRecommended? = { _ in nil }
    var adviceReads: [LanguageMode?] = []
    var engine: (ASRBackendType, ASREngineReadiness) = (.parakeet, .ready)
    var local: [LocalPolishModelID: OnboardingLocalPolishState] = [:]
    var permissions = (microphone: true, accessibility: true)
    var selected: ASRBackendType = .parakeet
    /// An upgrade-served Parakeet (P1): the base mirror stays at `upgradeKey`, and only the owner's
    /// installed read records the upgrade-aware answer into this cache (as live does).
    var upgradeServed: OnboardingParakeetAdmission?
    var upgradeKey = OnboardingParakeetAdmission.Key(state: .notReady, revision: 1)
    /// What the upgrade-served owner answers for "is Parakeet usable" (false: still downloading).
    var upgradeUsable = true
    /// One gate per installed read, in order (used before `admissionGate`).
    var admissionGateQueue: [Gate] = []
    /// The engine owner's warm-up (P2); nil means the engine is not ready to warm.
    var warm: ((ASRBackendType) -> OnboardingWarmup?)?
    /// The coordinator's clock (`deps.now`).
    var clock = Date(timeIntervalSince1970: 1000)
    /// Runs when the speech owner receives a request (an owner moving its phase).
    var onRequest: ((ASRBackendType) -> Void)?

    func coordinator() -> OnboardingCoordinator {
      let owners = downloadOwners()
      return makeCoordinator(owners: owners)
    }

    /// The world's download owners, exactly as `coordinator()` hands them to Setup.
    func downloadOwners() -> OnboardingDownloadOwners {
      OnboardingDownloadOwners(
        speechDeliveryEnabled: { _ in true },
        speechInstalled: { engine in
          if !self.admissionGateQueue.isEmpty {
            await self.admissionGateQueue.removeFirst().pass()
          } else {
            await self.admissionGate?.pass()
          }
          if engine == .parakeet, let admission = self.upgradeServed {
            admission.record(self.upgradeUsable, at: self.upgradeKey)
            return self.upgradeUsable
          }
          return self.speechPhase[engine] == .installed
        },
        writeSelectedBackend: { engine in
          self.selected = engine
          self.log.append("select(\(engine))")
        },
        selectedBackend: { self.selected },
        requestSpeech: { engine in
          self.log.append("request(\(engine))")
          self.onRequest?(engine)
          if !self.speechGateQueue.isEmpty {
            await self.speechGateQueue.removeFirst().pass()
          } else {
            await self.speechGate?.pass()
          }
          guard self.speechAccepted, !self.refusedEngines.contains(engine) else { return .refused }
          guard self.reportsEnd.contains(engine) else { return .accepted }
          return .ended(self.speechEnds.isEmpty ? .ok : self.speechEnds.removeFirst())
        },
        cancelSpeech: { self.log.append("cancel(\($0))") },
        clearSpeechBlock: { _ in true },
        speechPhase: { engine in
          if engine == .parakeet, let admission = self.upgradeServed {
            return OnboardingDownloads.phase(
              parakeet: self.upgradeKey.state, needsExplicitRetry: false,
              usable: admission.usable(at: self.upgradeKey))
          }
          return self.speechPhase[engine] ?? .notStarted
        },
        writePolishSelection: { self.log.append("selectPolish(\(Self.name($0)))") },
        polishPhase: { self.polishPhase[$0] ?? .notStarted },
        requestPolish: { model in
          self.log.append("requestPolish(\(Self.name(model)))")
          self.polishPhase[model] = .downloading(fraction: 0)
          return true
        },
        cancelPolish: { self.log.append("cancelPolish(\(Self.name($0)))") },
        activatePolish: { self.log.append("activate(\(Self.name($0)))") },
        speechReportsEnd: { self.reportsEnd.contains($0) })
    }

    private func makeCoordinator(owners: OnboardingDownloadOwners) -> OnboardingCoordinator {
      let sources = OnboardingReadinessSources(
        speechAdmitted: { engine in
          if engine == .parakeet, let admission = self.upgradeServed {
            admission.record(self.upgradeUsable, at: self.upgradeKey)
            return self.upgradeUsable
          }
          return self.speechPhase[engine] == .installed
        },
        engine: { self.engine },
        localPolish: { self.local[$0] },
        appleIntelligence: { .available },
        cloudEvidence: { _ in nil },
        permissions: { self.permissions })
      return OnboardingCoordinator(
        dependencies: .init(
          downloads: OnboardingDownloads(owners: owners), readinessSources: sources,
          legacyState: { self.legacy }, checkpointData: { self.checkpoint },
          writeCheckpoint: { data in
            self.checkpoint = data
            self.log.append(
              "checkpoint(\(OnboardingCheckpoint.decode(data)?.step.rawValue ?? "?"))")
          },
          writeLegacyState: { state in
            self.legacy = state
            self.log.append("legacy(\(state.rawValue))")
          },
          markCompleted: {
            self.legacy = .completed
            self.checkpoint = nil
            self.log.append("completed")
          },
          restartOnboarding: {
            self.checkpoint = nil
            self.legacy = .notStarted
            self.log.append("restart")
          },
          writeLanguage: { self.log.append("language(\($0 == .auto ? "auto" : "locked"))") },
          writeNonLocalPolish: { self.log.append("writePolish(\($0.polish ?? "nil"))") },
          savedChoices: { self.saved },
          recommended: { language in
            self.adviceReads.append(language)
            return self.advice(language) ?? self.recommended
          },
          downloadsInParallel: { self.parallel },
          downloadBytes: { self.bytes[$0] }, freeDiskBytes: { self.free },
          acquireSleepAssertion: { self.log.append("awake") },
          releaseSleepAssertion: { self.log.append("sleepOK") },
          now: { self.clock },
          warmEngine: { self.warm?($0) ?? nil },
          onPracticeOutcome: { self.log.append("practice(\($0.rawValue))") },
          onCompleted: { self.log.append("onCompleted") }),
        trackTasksForTests: true)
    }

    static func name(_ model: LocalPolishModelID) -> String {
      model.size.map { "\(model.provider.rawValue).\($0.rawValue)" } ?? model.provider.rawValue
    }
  }

  /// Walks a fresh flow to the speech pick.
  private static func atSpeechPick(_ world: World) -> OnboardingCoordinator {
    let c = world.coordinator()
    c.begin()
    c.send(.next)
    c.send(.next)
    return c
  }

  // MARK: Order

  @Test("each move saves the checkpoint before the new step is shown, then the legacy state")
  func checkpointBeforePublication() {
    let world = World()
    let c = world.coordinator()
    var seenAtPublish: [String] = []
    c.onChange = { seenAtPublish.append(world.log.last ?? "") }
    #expect(c.begin())
    c.send(.next)
    c.send(.next)
    #expect(c.state.step == .speechPick)
    #expect(world.log == ["checkpoint(language)", "checkpoint(speechPick)", "legacy(\(OnboardingState.settingUp.rawValue))"])
    #expect(seenAtPublish.contains("checkpoint(language)"))
    // A language choice saves without moving.
    let saved = world.log.count
    c.send(.back)
    c.send(.chooseLanguage(.locked("de")))
    #expect(world.log[saved...].contains("checkpoint(language)"))
    #expect(OnboardingCheckpoint.decode(world.checkpoint)?.choices.languageMode == .locked("de"))
  }

  @Test("finishing records the practice outcome, writes completed, then tells the observer once")
  func completionOrder() async {
    let world = World()
    world.speechPhase[.parakeet] = .installed
    world.local[.egOne(.mini)] = OnboardingLocalPolishState(
      installed: true, serverReady: true, healthy: true)
    world.polishPhase[.egOne(.mini)] = .installed
    let c = Self.atSpeechPick(world)
    c.send(.next)  // Parakeet (installed)
    c.send(.next)  // polish intro
    c.send(.next)  // EG-1 mini (installed)
    c.send(.next)  // downloads → permissions
    c.refreshReadiness()
    await c.settle()
    #expect(c.state.step == .key)
    c.send(.next)
    #expect(c.state.step == .practice && c.isPracticeUsable)
    world.log.removeAll()
    c.send(.practiceSucceeded)
    c.send(.filmFinished)
    // The stay-awake hold was already released once the installed models were adopted.
    let order = world.log.filter { $0 != "awake" && $0 != "sleepOK" }
    #expect(
      order == ["checkpoint(film)", "practice(succeeded)", "checkpoint(done)", "completed", "onCompleted"])
    #expect(world.log.filter { $0 == "onCompleted" }.count == 1)
    #expect(!c.isActive && world.checkpoint == nil)
    c.send(.next)
    #expect(world.log.filter { $0 == "onCompleted" }.count == 1)
  }

  // MARK: Restore

  @Test("a completed install never opens; an interrupted completion finishes without Setup")
  func restoreCompletedAndInterrupted() throws {
    let world = World()
    world.legacy = .completed
    #expect(!world.coordinator().begin())

    let interrupted = World()
    interrupted.legacy = .needsPermissions
    var done = OnboardingFlowState()
    done.step = .done
    done.practiceOutcome = .skipped
    interrupted.checkpoint = try OnboardingCheckpoint(state: done, startedAt: .now, savedAt: .now)
      .encoded()
    let c = interrupted.coordinator()
    #expect(!c.begin() && !c.isActive)
    #expect(interrupted.log == ["practice(skipped)", "completed", "onCompleted"])
  }

  @Test("a resumed Practice waits for current readiness; restored grants never count")
  func resumedPracticeWaits() async throws {
    let world = World()
    world.legacy = .needsPermissions
    var s = OnboardingFlowState()
    s.step = .practice
    s.choices.speech = .parakeet
    s.choices.polish = OnboardingChoices.polishOff
    world.checkpoint = try OnboardingCheckpoint(state: s, startedAt: .now, savedAt: .now).encoded()
    world.permissions = (microphone: false, accessibility: true)
    world.speechPhase[.parakeet] = .installed
    let c = world.coordinator()
    #expect(c.begin() && c.state.step == .practice && !c.isPracticeUsable)
    c.send(.practiceSucceeded)
    #expect(c.state.step == .practice && c.lastRefusal == "not ready for practice")
    c.refreshReadiness()
    await c.settle()
    #expect(!c.isPracticeUsable)
    world.permissions = (microphone: true, accessibility: true)
    c.refreshReadiness()
    await c.settle()
    #expect(c.isPracticeUsable)
  }

  @Test("closing and reopening keeps the same flow; reset starts at Welcome and keeps models")
  func closeReopenReset() async {
    let world = World()
    world.speechGate = Gate()
    let c = Self.atSpeechPick(world)
    c.send(.chooseSpeech(.whisper))
    #expect(c.begin() && c.state.step == .polishIntro)
    c.reset()
    world.speechGate?.open()
    await c.settle()
    #expect(c.state.step == .welcome && c.state.choices == OnboardingChoices())
    // Reset came before the start ever reached the owner: nothing was requested, so nothing
    // is cancelled (C repair r1: the engine is owned only once its request will be sent).
    #expect(!world.log.contains("request(whisper)") && !world.log.contains("cancel(whisper)"))
    #expect(world.log.contains("restart"))
    #expect(c.block == nil && world.checkpoint == nil)

    // A request already with the owner IS cancelled by reset.
    let held = World()
    held.speechGate = Gate()
    let h = Self.atSpeechPick(held)
    h.send(.chooseSpeech(.whisper))
    await held.speechGate?.untilEntered()
    h.reset()
    held.speechGate?.open()
    await h.settle()
    #expect(held.log.contains("request(whisper)") && held.log.contains("cancel(whisper)"))
  }

  // MARK: Async safety

  @Test("Back and a new pick work while a download is decided; the old answer is dropped")
  func responsiveAndStaleDropped() async {
    let world = World()
    world.speechGate = Gate()
    world.refusedEngines = [.whisper]
    let c = Self.atSpeechPick(world)
    c.send(.chooseSpeech(.whisper))
    // The Whisper request is now in flight and held: its answer will arrive late.
    await world.speechGate?.untilEntered()
    #expect(world.log.contains("request(whisper)"))
    c.send(.back)
    #expect(c.state.step == .speechPick)
    c.send(.chooseSpeech(.parakeet))
    #expect(c.state.step == .polishIntro && c.state.choices.speech == .parakeet)
    world.speechGate?.open()
    await c.settle()
    // Whisper's late refusal belongs to a replaced pick: no block for the current one.
    #expect(c.block == nil && c.state.choices.speech == .parakeet)
  }

  @Test("quit ends the coordinator's work and the stay-awake hold but not the owners' downloads")
  func quitReleases() async {
    let world = World()
    world.speechGate = Gate()
    let c = Self.atSpeechPick(world)
    c.send(.chooseSpeech(.whisper))
    #expect(world.log.contains("awake"))
    c.quit()
    world.speechGate?.open()
    await c.settle()
    #expect(world.log.last == "sleepOK")
    #expect(!world.log.contains("cancel(whisper)"))
  }

  // MARK: Scheduling and preflight

  @Test(
    "below the memory threshold polish waits for speech; a changed pick never starts the old one")
  func sequentialQueue() async {
    let world = World()
    world.parallel = false
    let c = Self.atSpeechPick(world)
    c.send(.chooseSpeech(.whisper))
    await c.settle()
    c.send(.next)
    c.send(.choosePolish("eg1.full"))
    #expect(!world.log.contains("requestPolish(egOne.full)"))
    c.send(.back)
    c.send(.choosePolish("eg1.micro"))
    world.speechPhase[.whisper] = .installed
    c.refreshReadiness()
    await c.settle()
    #expect(world.log.contains("requestPolish(egOne.micro)"))
    #expect(!world.log.contains("requestPolish(egOne.full)"))
  }

  @Test("at or above the threshold polish starts beside speech")
  func parallelStart() async {
    let world = World()
    world.admissionGate = Gate()
    let c = Self.atSpeechPick(world)
    c.send(.chooseSpeech(.whisper))
    // Pick polish while the speech start is still reading admission.
    await world.admissionGate?.untilEntered()
    c.send(.next)
    c.send(.choosePolish("eg1.mini"))
    world.admissionGate?.open()
    await c.settle()
    #expect(world.log.contains("requestPolish(egOne.mini)"))
    #expect(world.log.contains("request(whisper)"))
  }

  @Test("the language pick is written to settings before any speech work")
  func languageWrittenFirst() async {
    let world = World()
    let c = world.coordinator()
    c.begin()
    c.send(.next)
    c.send(.chooseLanguage(.locked("de")))
    c.send(.next)
    c.send(.chooseSpeech(.whisper))
    await c.settle()
    let language = world.log.firstIndex(of: "language(locked)")
    let select = world.log.firstIndex(of: "select(whisper)")
    #expect(language != nil && select != nil && language! < select!)
  }

  @Test("reset cancels every unfinished transfer the flow started, including a replaced pick")
  func resetCancelsReplacedPicks() async {
    let world = World()
    let c = Self.atSpeechPick(world)
    c.send(.chooseSpeech(.whisper))
    await c.settle()
    world.speechPhase[.whisper] = .downloading(fraction: 0.2)
    c.send(.back)
    c.send(.chooseSpeech(.parakeet))
    await c.settle()
    world.speechPhase[.parakeet] = .installed
    c.reset()
    #expect(world.log.contains("cancel(whisper)"))
    #expect(world.log.contains("cancel(parakeet)") == false)
  }

  @Test("a queued polish behind a failed speech download does not keep the Mac awake")
  func failedQueueReleasesTheHold() async {
    let world = World()
    world.parallel = false
    world.refusedEngines = [.whisper]
    let c = Self.atSpeechPick(world)
    c.send(.chooseSpeech(.whisper))
    await c.settle()
    world.speechPhase[.whisper] = .failed(.whisper("x"))
    c.send(.next)
    c.send(.choosePolish("eg1.mini"))
    c.refreshReadiness()
    await c.settle()
    #expect(world.log.filter { $0 == "awake" }.count == world.log.filter { $0 == "sleepOK" }.count)
    #expect(world.log.contains("requestPolish(egOne.mini)") == false)
  }

  @Test(
    "a pair that does not fit blocks the start; Retry with room starts it; installed adds nothing")
  func diskPreflight() async {
    let world = World()
    world.free = 1000
    world.bytes = [.speech(.whisper): 900]
    let c = Self.atSpeechPick(world)
    c.send(.chooseSpeech(.whisper))
    #expect(c.block == .insufficientDisk(neededBytes: 1080, freeBytes: 1000))
    #expect(!world.log.contains("request(whisper)"))
    world.free = 2000
    c.retryDownloads()
    await c.settle()
    #expect(c.block == nil && world.log.contains("request(whisper)"))

    let installed = World()
    installed.free = 10
    installed.bytes = [.speech(.parakeet): 900]
    installed.speechPhase[.parakeet] = .installed
    let d = Self.atSpeechPick(installed)
    d.send(.chooseSpeech(.parakeet))
    await d.settle()
    #expect(d.block == nil)
  }

  @Test("a refused speech start shows a block for that engine")
  func refusedSpeechBlocks() async {
    let world = World()
    world.speechAccepted = false
    let c = Self.atSpeechPick(world)
    c.send(.chooseSpeech(.whisper))
    await c.settle()
    #expect(c.block == .speechRefused(.whisper))
  }

  // MARK: Non-download picks

  @Test("Apple Intelligence, cloud and off are written through settings and download nothing")
  func nonLocalPicks() async {
    let world = World()
    let c = Self.atSpeechPick(world)
    c.send(.next)
    c.send(.next)
    c.send(.choosePolish("appleIntelligence"))
    c.send(.back)
    c.send(.seeAllPolish)
    c.send(.chooseCloud(.openAI, model: "gpt-4o-mini"))
    c.send(.back)
    c.send(.skipPolish)
    await c.settle()
    #expect(
      world.log.filter { $0.hasPrefix("writePolish") } == [
        "writePolish(appleIntelligence)", "writePolish(cloud)", "writePolish(off)",
      ])
    #expect(!world.log.contains { $0.hasPrefix("requestPolish") })
  }

  @Test("the settings writer stores the provider, then the cloud model")
  func settingsWriter() {
    let name = "ew.onboarding.coordinator.\(UUID().uuidString)"
    let suite = TestDefaults.suite(name)!
    suite.removePersistentDomain(forName: name)
    let settings = SettingsManager(defaults: suite)
    var cloud = OnboardingChoices()
    cloud.polish = OnboardingChoices.polishCloud
    cloud.cloudProvider = .openAI
    cloud.cloudModel = "gpt-4o-mini"
    OnboardingCoordinator.writeNonLocalPolish(cloud, to: settings)
    #expect(settings.llmProvider == .openAI && settings.llmModel == "gpt-4o-mini")
    var afm = OnboardingChoices()
    afm.polish = "appleIntelligence"
    OnboardingCoordinator.writeNonLocalPolish(afm, to: settings)
    #expect(settings.llmProvider == .appleIntelligence)
    var off = OnboardingChoices()
    off.polish = OnboardingChoices.polishOff
    OnboardingCoordinator.writeNonLocalPolish(off, to: settings)
    #expect(settings.llmProvider == LLMProvider.none)
  }

  // MARK: M73 — the visit's advice follows the chosen language

  private static let micro = OnboardingRecommended(
    speech: .parakeet, polish: "eg1.micro", rulesVersion: "rules-a")
  private static let germanMini = OnboardingRecommended(
    speech: .parakeet, polish: "eg1.mini", rulesVersion: "rules-a")
  private static let japaneseWhisper = OnboardingRecommended(
    speech: .whisper, polish: "eg1.mini", rulesVersion: "rules-a")

  /// An 8 GB Mac: Micro for Auto/English, Mini for locked German, Whisper for Japanese.
  private static func eightGigWorld() -> World {
    let world = World()
    world.recommended = micro
    world.advice = { mode in
      switch mode {
      case .locked("de")?: germanMini
      case .locked("ja")?: japaneseWhisper
      default: nil
      }
    }
    return world
  }

  @Test("choosing German on 8 GB re-forms the advice to Mini before Next; untouched defaults use it")
  func germanRefreshesPolishAdvice() {
    let world = Self.eightGigWorld()
    let c = world.coordinator()
    c.begin()
    #expect(c.state.recommended == Self.micro)
    c.send(.next)
    var observed: [OnboardingRecommended] = []
    c.onObservation = {
      if case .choicesCommitted(_, _, let recommended) = $0 { observed.append(recommended) }
    }
    c.send(.chooseLanguage(.locked("de")))
    #expect(c.state.recommended == Self.germanMini)
    #expect(observed == [Self.germanMini], "the observation saw other advice than the flow")
    c.send(.next)  // language → speech pick
    c.send(.next)  // speech default: Parakeet
    c.send(.next)  // polish intro → pick
    c.send(.next)  // polish default
    #expect(c.state.choices.speech == .parakeet && c.state.choices.polish == "eg1.mini")
  }

  @Test("choosing Japanese re-forms the speech advice to Whisper")
  func japaneseRefreshesSpeechAdvice() {
    let world = Self.eightGigWorld()
    let c = world.coordinator()
    c.begin()
    c.send(.next)
    c.send(.chooseLanguage(.locked("ja")))
    c.send(.next)
    c.send(.next)  // speech default
    #expect(c.state.choices.speech == .whisper)
  }

  @Test("changing the language through Back keeps every committed pick, cloud and off included")
  func backLanguageChangeKeepsPicks() {
    for skip in [false, true] {
      let world = Self.eightGigWorld()
      let c = world.coordinator()
      c.begin()
      c.send(.next)
      c.send(.chooseLanguage(.auto))
      c.send(.next)
      c.send(.chooseSpeech(.parakeet))
      c.send(.next)
      if skip {
        c.send(.skipPolish)
      } else {
        c.send(.seeAllPolish)
        c.send(.chooseCloud(.openAI, model: "gpt-4o-mini"))
      }
      let picks = c.state.choices
      while c.state.step != .language { c.send(.back) }
      c.send(.chooseLanguage(.locked("de")))
      #expect(c.state.recommended == Self.germanMini)
      var expected = picks
      expected.languageMode = .locked("de")
      #expect(c.state.choices == expected, "advice replaced a committed pick (skip: \(skip))")
    }
  }

  @Test("the same language again, or a refused event, reads no new advice")
  func noRefreshWithoutALanguageChange() {
    let world = Self.eightGigWorld()
    let c = world.coordinator()
    c.begin()
    c.send(.next)
    c.send(.chooseLanguage(.locked("de")))
    let reads = world.adviceReads.count
    c.send(.chooseLanguage(.locked("de")))
    c.send(.choosePolish(OnboardingChoices.polishCloud))  // refused: wrong step and no provider
    #expect(world.adviceReads.count == reads)
    #expect(c.state.recommended == Self.germanMini)
  }

  @Test("restore forms the advice for the saved language and keeps the saved picks")
  func restoreUsesSavedLanguage() throws {
    let world = Self.eightGigWorld()
    var saved = OnboardingFlowState()
    saved.step = .polishPick
    saved.choices = OnboardingChoices(languageMode: .locked("de"), speech: .parakeet)
    world.checkpoint = try OnboardingCheckpoint(
      state: saved, startedAt: Date(timeIntervalSince1970: 1),
      savedAt: Date(timeIntervalSince1970: 2)
    ).encoded()
    let c = world.coordinator()
    c.begin()
    #expect(c.state.step == .polishPick && c.state.choices == saved.choices)
    #expect(c.state.recommended == Self.germanMini)
    c.send(.next)
    #expect(c.state.choices.polish == "eg1.mini")

    let legacy = Self.eightGigWorld()
    legacy.legacy = .needsPermissions
    legacy.saved = OnboardingChoices(languageMode: .locked("ja"))
    let d = legacy.coordinator()
    d.begin()
    #expect(d.state.recommended == Self.japaneseWhisper)
    #expect(d.state.choices.speech == .whisper && d.state.choices.polish == "eg1.mini")
  }
}
