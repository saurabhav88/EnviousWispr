#if DEBUG
  import EnviousWisprCore
  import EnviousWisprServices
  import Foundation

  /// The door's `onboarding.*` commands (#4528 chunk C2c.2a, plan §3.9): a DEBUG backend session
  /// of the new Setup coordinator for CLI UAT. The session is built once, on first use, and runs
  /// only while `OnboardingWorkflowOwner` grants it Setup (the old onboarding is quiet); while it
  /// runs, the old onboarding window may not open. `send` uses the same events Setup's buttons
  /// will; `goto` is positioning, never evidence that a prerequisite passed. `status` reads only.
  @MainActor
  final class DevControlOnboarding {
    struct Session {
      let coordinator: OnboardingCoordinator
      let runtime: OnboardingRuntime
    }

    private let workflow: OnboardingWorkflowOwner
    private let makeSession: @MainActor () -> Session
    private let checkpointData: @MainActor () -> Data?
    private let legacyState: @MainActor () -> OnboardingState
    private(set) var session: Session?

    init(
      workflow: OnboardingWorkflowOwner, makeSession: @escaping @MainActor () -> Session,
      checkpointData: @escaping @MainActor () -> Data?,
      legacyState: @escaping @MainActor () -> OnboardingState
    ) {
      self.workflow = workflow
      self.makeSession = makeSession
      self.checkpointData = checkpointData
      self.legacyState = legacyState
    }

    typealias Result = DevControlDispatcher.Result

    // MARK: Commands

    /// Read only: never begins, resets or refreshes anything.
    func status() -> Result {
      .ok(snapshot())
    }

    /// Starts or resumes the backend session from the checkpoint (resume UAT).
    func begin() -> Result {
      guard workflow.claimBackendSession() else { return legacyBusy() }
      let session = ensureSession()
      guard session.coordinator.begin() else {
        // Completed, or an interrupted completion just finished: Setup does not open.
        workflow.releaseBackendSession()
        return .ok(snapshot(extra: ["opened": false]))
      }
      session.runtime.start()
      return .ok(snapshot(extra: ["opened": true]))
    }

    /// Restart Onboarding through the runtime (owners' cancels, checkpoint deleted, Welcome).
    func reset() -> Result {
      guard workflow.claimBackendSession() else { return legacyBusy() }
      let session = ensureSession()
      if session.runtime.isRunning {
        session.runtime.reset()
      } else {
        session.coordinator.reset()
        session.runtime.start()
      }
      return .ok(snapshot())
    }

    /// Ends the backend session as an app quit would (checkpoint kept, downloads continue in
    /// their owners), and returns Setup to the old onboarding.
    func stop() -> Result {
      guard let session, workflow.backendSessionActive else {
        return .failure(.rejected, "no onboarding session is running")
      }
      session.runtime.quit()
      workflow.releaseBackendSession()
      return .ok(snapshot())
    }

    func goto(_ args: [String: Any]) -> Result {
      guard let session = activeSession() else { return notRunning() }
      guard let raw = args["step"] as? String, let step = OnboardingStep(rawValue: raw),
        step != .done
      else {
        let steps = OnboardingStep.allCases.filter { $0 != .done }.map(\.rawValue)
        return .failure(.badArgs, "step must be one of: " + steps.joined(separator: ", "))
      }
      session.coordinator.debugGoto(step)
      session.runtime.tick()
      return .ok(snapshot(extra: ["positioned": true]))
    }

    func send(_ args: [String: Any]) -> Result {
      guard let session = activeSession() else { return notRunning() }
      let event: OnboardingEvent
      switch Self.event(from: args) {
      case .success(let parsed): event = parsed
      case .failure(let message): return .failure(.badArgs, message)
      }
      let before = session.coordinator.state.step
      session.coordinator.send(event)
      session.runtime.tick()
      let coordinator = session.coordinator
      let outcome: String
      if let refusal = coordinator.lastRefusal {
        outcome = "refused"
        return .ok(
          snapshot(extra: ["outcome": outcome, "reason": refusal, "from": before.rawValue]))
      }
      outcome = coordinator.state.step == before ? "stayed" : "moved"
      return .ok(snapshot(extra: ["outcome": outcome, "from": before.rawValue]))
    }

    // MARK: Parsing

    enum Parsed {
      case success(OnboardingEvent)
      case failure(String)
    }

    /// The button events Setup's screens send. Readiness is never sendable: it is measured live.
    static let sendableEvents = [
      "next", "back", "chooseLanguage", "compareSpeech", "chooseSpeech", "seeAllPolish",
      "choosePolish", "chooseCloud", "skipPolish", "turnPolishOn", "practiceSucceeded",
      "skipPractice", "filmFinished", "skipFilm",
    ]

    static func event(from args: [String: Any]) -> Parsed {
      guard let name = args["event"] as? String else {
        return .failure("event must be one of: " + sendableEvents.joined(separator: ", "))
      }
      let value = args["value"] as? String
      switch name {
      case "next": return .success(.next)
      case "back": return .success(.back)
      case "compareSpeech": return .success(.compareSpeech)
      case "seeAllPolish": return .success(.seeAllPolish)
      case "skipPolish": return .success(.skipPolish)
      case "turnPolishOn": return .success(.turnPolishOn)
      case "practiceSucceeded": return .success(.practiceSucceeded)
      case "skipPractice": return .success(.skipPractice)
      case "filmFinished": return .success(.filmFinished)
      case "skipFilm": return .success(.skipFilm)
      case "chooseLanguage":
        guard let value, !value.isEmpty else {
          return .failure("chooseLanguage needs value auto or a code")
        }
        if value == "auto" { return .success(.chooseLanguage(.auto)) }
        // Only languages the Language screen can offer (the existing support check).
        guard LanguageTypes.isSupported(value) else { return .failure("unsupported language \(value)") }
        return .success(.chooseLanguage(.locked(value)))
      case "chooseSpeech":
        guard let value, let engine = ASRBackendType(rawValue: value) else {
          return .failure("chooseSpeech needs value parakeet or whisper")
        }
        return .success(.chooseSpeech(engine))
      case "choosePolish":
        // Only the cards Setup shows (registered pick ids); off and cloud have their own events.
        guard let value, SetupRules.registeredPolish[value] != nil else {
          let ids = SetupRules.registeredPolish.keys.sorted().joined(separator: ", ")
          return .failure("choosePolish needs one of: \(ids)")
        }
        return .success(.choosePolish(value))
      case "chooseCloud":
        guard let raw = args["provider"] as? String, let provider = LLMProvider(rawValue: raw),
          CloudModelMemory.cloudProviders.contains(provider),
          let model = args["model"] as? String, !model.isEmpty
        else { return .failure("chooseCloud needs provider openAI, gemini or claude and a model") }
        return .success(.chooseCloud(provider, model: model))
      default:
        return .failure("event must be one of: " + sendableEvents.joined(separator: ", "))
      }
    }

    // MARK: Private

    private func ensureSession() -> Session {
      if let session { return session }
      let made = makeSession()
      session = made
      return made
    }

    private func activeSession() -> Session? {
      guard workflow.backendSessionActive, let session, session.coordinator.isActive else {
        return nil
      }
      return session
    }

    private func legacyBusy() -> Result {
      .failure(
        .busy,
        "the current onboarding is open or still working; close it and wait for its setup to finish"
      )
    }

    private func notRunning() -> Result {
      .failure(.rejected, "no onboarding session is running; send onboarding begin or reset first")
    }

    /// Owner, activation, flow, readiness and checkpoint facts. No keys, no dictated content.
    private func snapshot(extra: [String: Any] = [:]) -> [String: Any] {
      var out: [String: Any] = [
        "owner": workflow.current.rawValue,
        "legacyTasks": workflow.legacyTasks,
        "legacyWindowVisible": workflow.legacyWindowVisible(),
        "legacyState": legacyState().rawValue,
        "checkpoint": OnboardingCheckpoint.decode(checkpointData()).map { $0.step.rawValue }
          ?? NSNull(),
        "sessionBuilt": session != nil,
      ]
      if let coordinator = session?.coordinator {
        let state = coordinator.state
        out["active"] = coordinator.isActive
        out["step"] = state.step.rawValue
        out["choices"] = Self.choices(state.choices)
        out["readiness"] = Self.readiness(state.readiness)
        out["readyForPractice"] = state.isReadyForPractice
        out["practiceUsable"] = coordinator.isPracticeUsable
        out["block"] = coordinator.block.map(Self.block) ?? NSNull()
        out["lastRefusal"] = coordinator.lastRefusal ?? NSNull()
        out["networkSlow"] = session?.runtime.isNetworkSlow ?? false
        out["running"] = session?.runtime.isRunning ?? false
      }
      for (key, value) in extra { out[key] = value }
      return out
    }

    private static func choices(_ c: OnboardingChoices) -> [String: Any] {
      let language: Any =
        switch c.languageMode {
        case nil: NSNull()
        case .auto?: "auto"
        case .locked(let code)?: code
        }
      return [
        "language": language, "speech": c.speech?.rawValue ?? NSNull(),
        "polish": c.polish ?? NSNull(), "cloudProvider": c.cloudProvider?.rawValue ?? NSNull(),
        "cloudModel": c.cloudModel ?? NSNull(),
      ]
    }

    private static func readiness(_ r: OnboardingReadiness) -> [String: Any] {
      [
        "speech": r.speech?.rawValue ?? NSNull(), "speechInstalled": r.speechInstalled,
        "engineWarm": r.engineWarm, "polish": r.polish ?? NSNull(), "polishReady": r.polishReady,
        "microphone": r.microphoneGranted, "accessibility": r.accessibilityGranted,
      ]
    }

    private static func block(_ b: OnboardingDownloadBlock) -> [String: Any] {
      switch b {
      case .insufficientDisk(let needed, let free):
        ["kind": "insufficientDisk", "neededBytes": needed, "freeBytes": free]
      case .speechRefused(let engine): ["kind": "speechRefused", "speech": engine.rawValue]
      case .polishRefused(let id): ["kind": "polishRefused", "polish": id]
      }
    }

    /// The production door handler: the session is assembled on first use from the live owners
    /// (C2c.1), so every owner is fully built by then. Completing Setup returns it to nobody.
    static func live(
      _ owners: OnboardingLiveOwners, workflow: OnboardingWorkflowOwner
    ) -> DevControlOnboarding {
      DevControlOnboarding(
        workflow: workflow,
        makeSession: { [weak workflow] in
          let facts = OnboardingLiveFacts()
          let coordinator = OnboardingCoordinator(
            dependencies: .live(
              owners, facts: facts, sleepAssertion: OnboardingSleepAssertion(),
              onPracticeOutcome: { _ in },
              onCompleted: { workflow?.releaseBackendSession() }))
          let runtime = OnboardingRuntime(
            coordinator: coordinator, facts: facts, inputs: .live(owners, coordinator: coordinator))
          return Session(coordinator: coordinator, runtime: runtime)
        },
        checkpointData: { owners.settings.onboardingCheckpointData },
        legacyState: { owners.settings.onboardingState })
    }
  }
#endif
