#if DEBUG
  import AVFoundation
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
    /// Builds the session; it receives this door so completion can end ownership here.
    private let makeSession: @MainActor (DevControlOnboarding) -> Session
    private let checkpointData: @MainActor () -> Data?
    private let legacyState: @MainActor () -> OnboardingState
    /// The app's permissions service, for M5 simulation (nil when not wired).
    private let permissions: PermissionsService?
    /// The visit box shared with the old onboarding (one owner at a time), for begin/abandon/complete.
    private let progress: OnboardingProgress?
    private let everCompleted: @MainActor () -> Bool
    /// Whether the visit in the shared box is this session's (M63): only then may this door
    /// abandon or complete it. The old onboarding's live visit is never touched from here.
    private(set) var ownsVisit = false
    private(set) var session: Session?

    init(
      workflow: OnboardingWorkflowOwner,
      makeSession: @escaping @MainActor (DevControlOnboarding) -> Session,
      checkpointData: @escaping @MainActor () -> Data?,
      legacyState: @escaping @MainActor () -> OnboardingState,
      permissions: PermissionsService? = nil, progress: OnboardingProgress? = nil,
      everCompleted: @escaping @MainActor () -> Bool = { false }
    ) {
      self.permissions = permissions
      self.progress = progress
      self.everCompleted = everCompleted
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
      guard claim() else { return legacyBusy() }
      let session = ensureSession()
      guard session.coordinator.begin() else {
        // Completed, or an interrupted completion just finished: Setup does not open, and
        // Setup goes back through the one release path (simulation cleared first, M61).
        endOwnership()
        return .ok(snapshot(extra: ["opened": false]))
      }
      session.runtime.start()
      beginVisit()
      return .ok(snapshot(extra: ["opened": true]))
    }

    /// Restart Onboarding through the runtime (owners' cancels, checkpoint deleted, Welcome).
    func reset() -> Result {
      guard claim() else { return legacyBusy() }
      let session = ensureSession()
      if session.runtime.isRunning {
        session.runtime.reset()
      } else {
        session.coordinator.reset()
        session.runtime.start()
      }
      beginVisit()
      return .ok(snapshot())
    }

    /// Ends the backend session as an app quit would (checkpoint kept, downloads continue in
    /// their owners), and returns Setup to the old onboarding.
    /// Ends any session as an app quit would and always clears simulation before Setup goes
    /// back to the old onboarding; with nothing running it only cleans up.
    func stop() -> Result {
      endVisit(abandonReason: "window_closed")
      return .ok(snapshot())
    }

    /// App quit while the session owns Setup (installed as `backendQuit`): abandon at most once.
    func quitSession() {
      endVisit(abandonReason: "app_quit")
    }

    /// The session's flow completed: the visit is complete (no abandon), then Setup goes back.
    func sessionCompleted() {
      if ownsVisit { progress?.markCompleted() }
      ownsVisit = false
      endOwnership()
    }

    /// Claims Setup and installs this session's Restart and quit handlers on the owner.
    private func claim() -> Bool {
      guard workflow.claimBackendSession() else { return false }
      workflow.backendRestart = { [weak self] in _ = self?.reset() }
      workflow.backendQuit = { [weak self] in self?.quitSession() }
      return true
    }

    /// A visit starts when the session opens Setup; a refocus or reset of a live visit is a
    /// no-op inside the box (it never rewinds).
    private func beginVisit() {
      guard let progress, !ownsVisit else { return }
      // Never adopt a visit the old onboarding still has in flight.
      guard !progress.isInFlight else { return }
      progress.begin(source: everCompleted() ? "diagnostics_restart" : "first_run")
      ownsVisit = true
    }

    /// Ends any running session as an app quit would, records the abandon at most once (a
    /// completed visit records none), then gives Setup back.
    private func endVisit(abandonReason: String) {
      if let session, session.runtime.isRunning || session.coordinator.isActive {
        session.runtime.quit()
      }
      if ownsVisit {
        progress?.emitAbandonIfInFlight(
          reason: abandonReason, micStatus: permissions?.microphoneStatusString ?? "unknown",
          accessibilityStatus: (permissions?.accessibilityGrantedLive ?? false) ? "granted" : "denied")
      }
      ownsVisit = false
      endOwnership()
    }

    /// The one way this door gives Setup back (stop, and completion through the session's
    /// observer): simulation is cleared first, so no override outlives the session (M60).
    func endOwnership() {
      clearSimulation()
      workflow.releaseBackendSession()
    }

    // MARK: Simulation (DEBUG only; cleared by `--clear`, by `stop` and by relaunch)

    /// Fakes the Mac for advice only (`SetupAdvice.debugProfile`).
    func profile(_ args: [String: Any]) -> Result {
      if args["clear"] as? Bool == true {
        SetupAdvice.debugProfile = nil
        return .ok(snapshot())
      }
      var fake = SetupAdvice.DebugProfile()
      if let ram = args["ram"] {
        guard let value = ram as? Int, value > 0 else { return .failure(.badArgs, "ram must be a positive integer (GiB)") }
        fake.memoryGiB = value
      }
      if let os = args["os"] {
        guard let value = os as? Int, value >= 14 else { return .failure(.badArgs, "os must be a macOS major version, 14 or later") }
        fake.macOSMajor = value
      }
      if let afm = args["afm"] {
        guard let raw = afm as? String, let state = AppleIntelligenceSetupState(rawValue: raw) else {
          let states = AppleIntelligenceSetupState.allCases.map(\.rawValue).joined(separator: ", ")
          return .failure(.badArgs, "afm must be one of: \(states)")
        }
        fake.appleIntelligence = state
      }
      if let lang = args["lang"] {
        guard let code = lang as? String, LanguageTypes.isSupported(code) else {
          return .failure(.badArgs, "lang must be a supported language code")
        }
        fake.macLanguages = [code]
      }
      guard fake != SetupAdvice.DebugProfile() else {
        return .failure(.badArgs, "give at least one of ram, os, afm, lang, or clear")
      }
      // Validated: claim Setup immediately before applying (M61).
      guard claim() else { return legacyBusy() }
      SetupAdvice.debugProfile = fake
      return .ok(snapshot())
    }

    /// Simulated permission grants (M5): no real prompt, pane or telemetry while set.
    func permissionsCommand(_ args: [String: Any]) -> Result {
      guard let permissions else { return .failure(.notWired, "permissions are not wired") }
      if args["clear"] as? Bool == true {
        permissions.simulated = nil
        return .ok(snapshot())
      }
      var fake = permissions.simulated ?? PermissionsService.SimulatedPermissions()
      if let mic = args["mic"] {
        switch mic as? String {
        case "granted": fake.microphone = .authorized
        case "denied": fake.microphone = .denied
        case "notDetermined": fake.microphone = .notDetermined
        default: return .failure(.badArgs, "mic must be granted, denied or notDetermined")
        }
      }
      if let ax = args["ax"] {
        switch ax as? String {
        case "granted": fake.accessibility = true
        case "denied": fake.accessibility = false
        default: return .failure(.badArgs, "ax must be granted or denied")
        }
      }
      guard args["mic"] != nil || args["ax"] != nil else {
        return .failure(.badArgs, "give mic, ax, or clear")
      }
      // Validated: claim Setup immediately before applying (M61).
      guard claim() else { return legacyBusy() }
      permissions.simulated = fake
      session?.runtime.tick()
      return .ok(snapshot())
    }

    /// Turns one approved fault on or off, or clears all.
    func fault(_ args: [String: Any]) -> Result {
      if args["clear"] as? Bool == true {
        OnboardingDebugFaults.active.removeAll()
        return .ok(snapshot())
      }
      guard let raw = args["name"] as? String, let fault = OnboardingFault(rawValue: raw) else {
        let names = OnboardingFault.allCases.map(\.rawValue).joined(separator: ", ")
        return .failure(.badArgs, "fault must be one of: \(names)")
      }
      guard claim() else { return legacyBusy() }
      if args["off"] as? Bool == true {
        OnboardingDebugFaults.active.remove(fault)
      } else {
        OnboardingDebugFaults.active.insert(fault)
      }
      session?.coordinator.invalidateReadiness()
      session?.runtime.tick()
      return .ok(snapshot())
    }

    private func clearSimulation() { Self.clearSimulation(permissions: permissions) }

    /// Clears every DEBUG override (advice profile, simulated grants, faults).
    static func clearSimulation(permissions: PermissionsService?) {
      SetupAdvice.debugProfile = nil
      permissions?.simulated = nil
      OnboardingDebugFaults.active.removeAll()
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
      let made = makeSession(self)
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
        "simulated": simulatedSnapshot(),
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

    /// Every synthetic input in force, so a reply never passes simulated evidence off as real.
    private func simulatedSnapshot() -> [String: Any] {
      var out: [String: Any] = [
        "faults": OnboardingDebugFaults.active.map(\.rawValue).sorted()
      ]
      if let fake = SetupAdvice.debugProfile {
        out["profile"] = [
          "ram": fake.memoryGiB.map { $0 as Any } ?? NSNull(),
          "os": fake.macOSMajor.map { $0 as Any } ?? NSNull(),
          "afm": fake.appleIntelligence?.rawValue ?? NSNull(),
          "lang": fake.macLanguages?.first ?? NSNull(),
        ]
      } else {
        out["profile"] = NSNull()
      }
      if let fake = permissions?.simulated {
        let mic: Any =
          switch fake.microphone {
          case .authorized?: "granted"
          case .denied?: "denied"
          case .notDetermined?: "notDetermined"
          case .restricted?: "restricted"
          case nil: NSNull()
          @unknown default: "unknown"
          }
        out["permissions"] = [
          "mic": mic, "ax": fake.accessibility.map { $0 ? "granted" : "denied" } ?? NSNull(),
        ]
      } else {
        out["permissions"] = NSNull()
      }
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
      _ owners: OnboardingLiveOwners, workflow: OnboardingWorkflowOwner, progress: OnboardingProgress
    ) -> DevControlOnboarding {
      DevControlOnboarding(
        workflow: workflow,
        makeSession: { [weak workflow] door in
          let facts = OnboardingLiveFacts()
          let coordinator = OnboardingCoordinator(
            dependencies: .live(
              owners, facts: facts, sleepAssertion: OnboardingSleepAssertion(),
              onPracticeOutcome: { _ in },
              // Completion gives Setup back through the door, which clears simulation first.
              onCompleted: { [weak door] in
                if let door {
                  door.sessionCompleted()
                } else {
                  DevControlOnboarding.clearSimulation(permissions: owners.permissions)
                  workflow?.releaseBackendSession()
                }
              }))
          let runtime = OnboardingRuntime(
            coordinator: coordinator, facts: facts, inputs: .live(owners, coordinator: coordinator))
          return Session(coordinator: coordinator, runtime: runtime)
        },
        checkpointData: { owners.settings.onboardingCheckpointData },
        legacyState: { owners.settings.onboardingState },
        permissions: owners.permissions, progress: progress,
        everCompleted: { owners.settings.onboardingEverCompleted })
    }
  }
#endif
