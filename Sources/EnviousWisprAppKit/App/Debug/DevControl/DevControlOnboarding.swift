#if DEBUG
  import AVFoundation
  import EnviousWisprCore
  import EnviousWisprServices
  import Foundation

  @MainActor
  final class DevControlOnboarding {
    /// DEBUG harnesses can suppress automatic Setup presentation before arranging their fixtures.
    static let holdAtLaunchEnvironmentKey = "EW_UAT_ONBOARDING_BACKEND"

    static var holdsAutomaticPresentation: Bool {
      ProcessInfo.processInfo.environment[holdAtLaunchEnvironmentKey] == "1"
    }

    let setupSession: SetupSession
    private let checkpointData: @MainActor () -> Data?
    private let legacyState: @MainActor () -> OnboardingState
    private let permissions: PermissionsService?
    var session: SetupSession.Components? { setupSession.components }
    /// The catalog's in-flight owner query, so repeated `status` reads start at most one.
    private var installedQuery: Task<Void, Never>?

    init(
      setupSession: SetupSession,
      checkpointData: @escaping @MainActor () -> Data?,
      legacyState: @escaping @MainActor () -> OnboardingState,
      permissions: PermissionsService? = nil
    ) {
      self.permissions = permissions
      self.setupSession = setupSession
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
      trackDebugSession()
      guard setupSession.begin() else {
        endDebugSession()
        return .ok(snapshot(extra: ["opened": false]))
      }
      return .ok(snapshot(extra: ["opened": true]))
    }

    /// Restart Onboarding through the runtime (owners' cancels, checkpoint deleted, Welcome).
    func reset() -> Result {
      trackDebugSession()
      setupSession.reset()
      return .ok(snapshot())
    }

    /// Shows (or refocuses) the new Setup's screens for this session's running flow (D0). A
    /// mutation: it opens a window over the existing flow.
    func present() -> Result {
      guard let session, session.coordinator.isActive else {
        return notRunning()
      }
      setupSession.present()
      return .ok(snapshot())
    }

    func stop() -> Result {
      trackDebugSession()
      setupSession.stop(reason: "window_closed")
      return .ok(snapshot())
    }

    private func trackDebugSession() {
      setupSession.onDebugEnd = { [weak self] in self?.endDebugSession() }
    }

    private func endDebugSession() {
      clearSimulation()
      setupSession.onDebugEnd = nil
    }

    // MARK: Simulation (DEBUG only; cleared by `--clear`, by `stop` and by relaunch)

    /// Fakes the Mac for advice only (`SetupAdvice.debugProfile`).
    func profile(_ args: [String: Any]) -> Result {
      if args["clear"] as? Bool == true {
        SetupAdvice.debugProfile = nil
        session?.runtime.tick()
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
        // `none`: a Mac whose language the app cannot read (D8's blank Language field).
        if lang as? String == "none" {
          fake.macLanguages = []
        } else {
          guard let code = lang as? String, LanguageTypes.isSupported(code) else {
            return .failure(.badArgs, "lang must be a supported language code or none")
          }
          fake.macLanguages = [code]
        }
      }
      guard fake != SetupAdvice.DebugProfile() else {
        return .failure(.badArgs, "give at least one of ram, os, afm, lang, or clear")
      }
      // Validated: claim Setup immediately before applying (M61).
      trackDebugSession()
      SetupAdvice.debugProfile = fake
      // Re-read now, as a real availability change does (owner observation), so a mounted AI
      // polish screen re-forms its cards without waiting for the poll (plan M77).
      session?.runtime.tick()
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
      trackDebugSession()
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
      trackDebugSession()
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

    /// Getting ready's warm-up Try again (plan M83): the coordinator's own action. Accepted is
    /// not proof that warming succeeded; the reply carries the state as it stands.
    func retryWarmup() -> Result {
      guard let session = activeSession() else { return notRunning() }
      session.coordinator.retryWarmup()
      session.runtime.tick()
      return .ok(snapshot())
    }

    /// Getting ready's polish Try again (plan M83): the coordinator's own action, through the
    /// selected model's activation door. Accepted is not proof the model loaded.
    func retryPolish() -> Result {
      guard let session = activeSession() else { return notRunning() }
      session.coordinator.retryPolish()
      session.runtime.tick()
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
      session.screenSources.practiceProgress?.reset()
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
      if before == .practice, coordinator.state.step != .practice {
        session.screenSources.practiceProgress?.reset()
      }
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
      "choosePolish", "chooseCloud", "skipPolish", "turnPolishOn", "continueWithoutPolish",
      "reviewPermissions", "practiceSucceeded", "skipPractice", "filmFinished", "skipFilm",
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
      case "continueWithoutPolish": return .success(.continueWithoutPolish)
      case "reviewPermissions": return .success(.reviewPermissions)
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

    private func activeSession() -> SetupSession.Components? {
      guard let session, session.coordinator.isActive else {
        return nil
      }
      return session
    }

    private func notRunning() -> Result {
      .failure(.rejected, "no onboarding session is running; send onboarding begin or reset first")
    }

    /// Owner, activation, flow, readiness and checkpoint facts. No keys, no dictated content.
    private func snapshot(extra: [String: Any] = [:]) -> [String: Any] {
      var out: [String: Any] = [
        "legacyState": legacyState().rawValue,
        "checkpoint": OnboardingCheckpoint.decode(checkpointData()).map { $0.step.rawValue }
          ?? NSNull(),
        "sessionBuilt": session != nil,
        "presented": setupSession.presenter.isVisible,
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
        out["countingDown"] = session?.runtime.isCountingDown ?? false
        out["warmFailed"] = coordinator.warmFailed
        out["queuedPolish"] = coordinator.queuedPolishID ?? NSNull()
        out["running"] = session?.runtime.isRunning ?? false
        out["recommended"] = [
          "speech": state.recommended.speech.rawValue, "polish": state.recommended.polish,
          "rulesVersion": state.recommended.rulesVersion,
        ]
        let phases = session?.downloadPhases
        out["downloads"] = phases.map { Self.phasePayload($0(state.choices)) as Any } ?? NSNull()
        let catalog = phases.map { phases in Self.catalog { Self.phasePayload(phases($0)) } }
        out["catalog"] = catalog ?? NSNull()
        resolveUnknownSpeech(catalog)
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
        "polishFailed": r.polishFailed,
        "microphone": r.microphoneGranted, "accessibility": r.accessibilityGranted,
      ]
    }

    /// A speech entry the owners have not answered yet ("unknown": Parakeet's upgrade-aware
    /// admission needs an async owner read) starts one read-only owner query; the next `status`
    /// shows its answer. Nothing is chosen, written or downloaded.
    private func resolveUnknownSpeech(_ catalog: [String: Any]?) {
      let speech = (catalog?["speech"] as? [String: Any]) ?? [:]
      guard installedQuery == nil, speech.values.contains(where: { $0 as? String == "unknown" }),
        let resolve = session?.resolveInstalled
      else { return }
      installedQuery = Task { [weak self] in
        await resolve()
        self?.installedQuery = nil
      }
    }

    /// Every Setup speech engine's and local polish model's owner phase, read without choosing
    /// anything: choosing a model starts its download, so the CLI harness finds what is already
    /// on this Mac here (I1, plan M69).
    static func catalog(_ phases: (OnboardingChoices) -> [String: Any]) -> [String: Any] {
      let engines: [ASRBackendType] = [.parakeet, .whisper]
      let polish = SetupRules.registeredPolish.keys.sorted()
        .filter { OnboardingDownloads.localModel(forPolish: $0) != nil }
      return [
        "speech": Dictionary(uniqueKeysWithValues: engines.map {
          ($0.rawValue, phases(OnboardingChoices(speech: $0))["speech"] ?? NSNull())
        }),
        "polish": Dictionary(uniqueKeysWithValues: polish.map {
          ($0, phases(OnboardingChoices(polish: $0))["polish"] ?? NSNull())
        }),
      ]
    }

    private static func phasePayload(
      _ phases: (speech: OnboardingDownloadPhase?, polish: OnboardingDownloadPhase?)
    ) -> [String: Any] {
      ["speech": phaseName(phases.speech), "polish": phaseName(phases.polish)]
    }

    /// A download phase's name for `status` (no failure text).
    static func phaseName(_ phase: OnboardingDownloadPhase?) -> Any {
      switch phase {
      case nil: NSNull()
      case .notStarted?: "notStarted"
      case .downloading?: "downloading"
      case .verifying?: "verifying"
      case .installed?: "installed"
      case .paused?: "paused"
      case .failed?: "failed"
      case .unavailable?: "unavailable"
      case .unknown?: "unknown"
      }
    }

    private static func block(_ b: OnboardingDownloadBlock) -> [String: Any] {
      switch b {
      case .insufficientDisk(let needed, let free):
        ["kind": "insufficientDisk", "neededBytes": needed, "freeBytes": free]
      case .speechRefused(let engine): ["kind": "speechRefused", "speech": engine.rawValue]
      case .polishRefused(let id): ["kind": "polishRefused", "polish": id]
      }
    }

    static func live(_ owners: OnboardingLiveOwners, setupSession: SetupSession) -> DevControlOnboarding {
      DevControlOnboarding(
        setupSession: setupSession, checkpointData: { owners.settings.onboardingCheckpointData },
        legacyState: { owners.settings.onboardingState }, permissions: owners.permissions)
    }
  }
#endif
