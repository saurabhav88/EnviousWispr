#if DEBUG
  import AVFoundation
  import EnviousWisprCore
  import EnviousWisprModelDelivery
  import Foundation
  import Testing

  @testable import EnviousWisprAppKit
  @testable import EnviousWisprServices

  /// #4528 C2c.2b: DEBUG simulation for CLI UAT (advice profile, M5 permissions, faults).
  ///
  /// **Harness Contract.** When this fails, a UAT run shows a real macOS permission prompt or
  /// opens System Settings, sends fake permission telemetry, a faked Mac changes something other
  /// than advice, or a fault reaches a real download or reads as real evidence.
  @MainActor
  @Suite(.tags(.harnessContract))
  struct OnboardingSimulationTests {
    @MainActor
    final class Calls {
      var requests = 0
      var opened: [URL] = []
    }

    private static func service(_ calls: Calls) -> PermissionsService {
      PermissionsService(
        accessibilityReader: { false }, microphoneReader: { .denied },
        microphoneRequester: {
          await MainActor.run { calls.requests += 1 }
          return false
        },
        openMicrophoneSettings: { calls.opened.append($0) }, calendarReader: { .notAsked })
    }

    @Test("simulated grants answer every read and the real values return when cleared")
    func simulatedReads() {
      let service = Self.service(Calls())
      service.simulated = .init(microphone: .authorized, accessibility: true)
      #expect(service.microphoneStatus == .authorized && service.accessibilityGranted)
      #expect(service.microphoneStatusLive == .authorized && service.accessibilityGrantedLive)
      #expect(service.microphonePermissionIsDenied == false)
      service.simulated = .init(accessibility: true)  // microphone stays real
      #expect(service.microphoneStatusLive == .denied && service.accessibilityGrantedLive)
      service.simulated = nil
      #expect(service.microphoneStatus == .denied && service.accessibilityGranted == false)
    }

    @Test("simulated requests show no prompt, open no pane and send no permission telemetry")
    func noPromptsNoTelemetry() async {
      let calls = Calls()
      let service = Self.service(calls)
      service.simulated = .init(microphone: .denied, accessibility: false)
      #expect(await service.requestMicrophoneAccess() == false)
      await service.requestMicrophoneAccessOrOpenSettings()
      #expect(calls.requests == 0 && calls.opened.isEmpty)

      // Synchronous install-fire-restore: no await while the hook is installed.
      let events = Calls()
      TelemetryService.shared.testEventHook = { @Sendable event in
        MainActor.assumeIsolated {
          if event.name == "permission.status" { events.requests += 1 }
        }
      }
      let granted = service.requestAccessibilityAccess()
      service.simulated = .init(microphone: .denied, accessibility: true)
      service.refreshAccessibilityStatus()  // false → true flip, simulated
      TelemetryService.shared.testEventHook = nil
      #expect(granted == false && service.accessibilityGranted)
      #expect(events.requests == 0)
    }

    @Test("a faked Mac changes advice only, field by field")
    func profileOverride() {
      let real = MacProfile(
        memoryGiB: 32, chipName: "M5 Max", macOSMajor: 26, appleIntelligence: .available,
        macLanguages: ["en-US"], freeDiskBytes: 1_000)
      #expect(SetupAdvice.applying(nil, to: real) == real)
      let fake = SetupAdvice.applying(
        .init(memoryGiB: 8, appleIntelligence: .unavailable, macLanguages: ["de"]), to: real)
      #expect(
        fake.memoryGiB == 8 && fake.appleIntelligence == .unavailable && fake.macLanguages == ["de"]
      )
      #expect(fake.macOSMajor == 26 && fake.chipName == "M5 Max" && fake.freeDiskBytes == 1_000)
      let rules = SetupAdvice.activeRules
      let advice = SetupRecommender.recommend(
        profile: fake, rules: rules, languageMode: .auto, capabilities: .polishOnly)
      #expect(advice.polishPrimary == "eg1.micro" && advice.parallelDownloads == false)
    }

    @Test("faults answer at Setup's boundary and never reach the owner")
    func faultsStayAtTheBoundary() async {
      defer { OnboardingDebugFaults.active.removeAll() }
      var requested: [String] = []
      let real = OnboardingDownloadOwners(
        speechDeliveryEnabled: { _ in true }, speechInstalled: { _ in false },
        writeSelectedBackend: { _ in }, selectedBackend: { .whisper },
        requestSpeech: { engine in
          requested.append("speech:\(engine)")
          return true
        },
        cancelSpeech: { _ in }, clearSpeechBlock: { _ in true }, speechPhase: { _ in .notStarted },
        writePolishSelection: { _ in }, polishPhase: { _ in .notStarted },
        requestPolish: { model in
          requested.append("polish:\(model.provider.rawValue)")
          return true
        },
        cancelPolish: { _ in }, activatePolish: { _ in })
      let faulted = OnboardingDebugFaults.apply(to: real)
      OnboardingDebugFaults.active = [.downloadFail, .polishFail]
      #expect(await faulted.requestSpeech(.whisper))
      #expect(requested.isEmpty)
      #expect(
        faulted.speechPhase(.whisper)
          == .failed(.delivery(OnboardingDebugFaults.simulatedDeliveryFailure)))
      // polish-fail is a load failure at readiness (M60), so the polish download is untouched.
      #expect(faulted.requestPolish(.egOne(.mini)) && requested == ["polish:egOne"])
      #expect(faulted.polishPhase(.egOne(.mini)) == .notStarted)
      OnboardingDebugFaults.active = []
      #expect(await faulted.requestSpeech(.whisper))
      #expect(requested == ["polish:egOne", "speech:whisper"])
      #expect(faulted.speechPhase(.whisper) == .notStarted)

      let sources = OnboardingDebugFaults.apply(
        to: OnboardingReadinessSources(
          speechAdmitted: { _ in true }, engine: { (.whisper, .ready) }, localPolish: { _ in nil },
          appleIntelligence: { .available },
          cloudEvidence: { provider in
            OnboardingCloudEvidence(
              provider: provider, model: "m", checkedRevision: 1, currentRevision: 1, accepted: true
            )
          },
          permissions: { (true, true) }))
      OnboardingDebugFaults.active = [.warmFail, .keyInvalid]
      #expect(sources.engine().readiness == .notReady)
      #expect(sources.cloudEvidence(.openAI)?.isCurrentPass == false)
    }

    @Test("a mic request already waiting when simulation starts answers the simulated value")
    func heldRequestRechecksSimulation() async {
      let (gate, open) = AsyncStream.makeStream(of: Void.self)
      let (entered, enter) = AsyncStream.makeStream(of: Void.self)
      let service = PermissionsService(
        accessibilityReader: { false }, microphoneReader: { .denied },
        microphoneRequester: {
          enter.yield(())  // the request is now held inside the real requester
          var it = gate.makeAsyncIterator()
          _ = await it.next()
          return false  // the real answer
        },
        openMicrophoneSettings: { _ in }, calendarReader: { .notAsked })
      let request = Task { await service.requestMicrophoneAccess() }
      let net = Task {
        // deadline-fallback: hang guard only; the signal is the requester's entry yield.
        try? await Task.sleep(for: .seconds(5))
        enter.finish()
      }
      var arrivals = entered.makeAsyncIterator()
      let arrived = await arrivals.next()
      net.cancel()
      #expect(arrived != nil, "the request never reached the real requester")
      service.simulated = .init(microphone: .authorized)
      open.yield(())
      // The post-request branch answers the simulated grant (and so sends no telemetry); the old
      // code returned the real `false` and emitted `permission.status`.
      #expect(await request.value == true)
      #expect(service.microphoneStatus == .authorized)
    }

    @Test("polish-fail makes an installed, otherwise ready model not ready, and clearing recovers")
    func polishFailAtReadiness() async {
      defer { OnboardingDebugFaults.active.removeAll() }
      let sources = OnboardingDebugFaults.apply(
        to: OnboardingReadinessSources(
          speechAdmitted: { _ in true }, engine: { (.parakeet, .ready) },
          localPolish: { _ in OnboardingLocalPolishState(installed: true, serverReady: true, healthy: true) },
          appleIntelligence: { .available }, cloudEvidence: { _ in nil }, permissions: { (true, true) }))
      var choices = OnboardingChoices()
      choices.speech = .parakeet
      choices.polish = "eg1.mini"
      func ready() async -> Bool {
        var state = OnboardingFlowState()
        state.choices = choices
        state.readiness = await OnboardingReadinessReader.measure(choices, from: sources)
        return state.isReadyForPractice
      }
      #expect(await ready())
      OnboardingDebugFaults.active = [.polishFail]
      #expect(await ready() == false)
      OnboardingDebugFaults.active = []
      #expect(await ready())
    }

    @Test("simulation stays inside Setup's ownership and is cleared whenever Setup is given back")
    func simulationOwnership() {
      defer { OnboardingDebugFaults.active.removeAll() }
      let workflow = OnboardingWorkflowOwner()
      let service = Self.service(Calls())
      let world = OnboardingCoordinatorTests.World()
      let door = DevControlOnboarding(
        workflow: workflow,
        makeSession: { _ in
          let c = world.coordinator()
          return .init(
            coordinator: c,
            runtime: OnboardingRuntime(
              coordinator: c, facts: OnboardingLiveFacts(),
              inputs: .init(
                readObservedFacts: { AnyHashable(0) }, downloadProgress: { nil },
                downloadsFinished: { false }, sampleAppleIntelligence: { .available },
                recheckAppleIntelligence: {}, now: { .now },
                // deadline-fallback: timers wait until stop() cancels them.
                sleep: { _ in try? await Task.sleep(for: .seconds(3600)) },
                pollInterval: .seconds(3600))))
        },
        checkpointData: { nil }, legacyState: { .notStarted }, permissions: service)
      func code(_ r: DevControlDispatcher.Result) -> String? {
        if case .error(let code, _) = r { return code }
        return nil
      }
      // Refused while the old onboarding is working: nothing shared changes.
      workflow.beginLegacyWork()
      #expect(code(door.permissionsCommand(["mic": "granted"])) == "busy")
      #expect(code(door.fault(["name": "warm-fail"])) == "busy")
      #expect(service.simulated == nil && OnboardingDebugFaults.active.isEmpty)
      workflow.endLegacyWork()

      // Configuring before begin claims Setup; stop with no session running still cleans up.
      _ = door.permissionsCommand(["mic": "granted"])
      _ = door.fault(["name": "disk-short"])
      #expect(workflow.backendSessionActive && workflow.legacyMayOpen == false)
      _ = door.stop()
      #expect(service.simulated == nil && OnboardingDebugFaults.active.isEmpty)
      #expect(workflow.backendSessionActive == false)

      // Completion gives Setup back through the same path, which clears simulation first.
      _ = door.begin()
      _ = door.fault(["name": "key-invalid"])
      door.endOwnership()
      #expect(OnboardingDebugFaults.active.isEmpty && workflow.backendSessionActive == false)
    }

    @Test("a completed begin clears simulation; rejected arguments claim nothing and change nothing")
    func completedBeginAndRejectedArguments() {
      defer { OnboardingDebugFaults.active.removeAll() }
      let workflow = OnboardingWorkflowOwner()
      let service = Self.service(Calls())
      let world = OnboardingCoordinatorTests.World()
      world.legacy = .completed
      let door = DevControlOnboarding(
        workflow: workflow,
        makeSession: { _ in
          let c = world.coordinator()
          return .init(
            coordinator: c,
            runtime: OnboardingRuntime(
              coordinator: c, facts: OnboardingLiveFacts(),
              inputs: .init(
                readObservedFacts: { AnyHashable(0) }, downloadProgress: { nil },
                downloadsFinished: { false }, sampleAppleIntelligence: { .available },
                recheckAppleIntelligence: {}, now: { .now },
                // deadline-fallback: timers wait until stop() cancels them.
                sleep: { _ in try? await Task.sleep(for: .seconds(3600)) },
                pollInterval: .seconds(3600))))
        },
        checkpointData: { nil }, legacyState: { world.legacy }, permissions: service)
      func code(_ r: DevControlDispatcher.Result) -> String? {
        if case .error(let code, _) = r { return code }
        return nil
      }
      // Rejected arguments: no claim, no shared change.
      #expect(code(door.profile(["ram": 0])) == "badArgs")
      #expect(code(door.permissionsCommand(["mic": "maybe"])) == "badArgs")
      #expect(code(door.permissionsCommand([:])) == "badArgs")
      #expect(workflow.backendSessionActive == false)
      #expect(service.simulated == nil && SetupAdvice.debugProfile == nil)

      // The real completed-begin path: Setup does not open and goes back clean.
      _ = door.permissionsCommand(["mic": "granted"])
      #expect(workflow.backendSessionActive && service.simulated != nil)
      guard case .ok(let reply, _) = door.begin() else {
        Issue.record("begin refused")
        return
      }
      #expect(reply["opened"] as? Bool == false)
      #expect(workflow.backendSessionActive == false && service.simulated == nil)
    }

    @Test("door simulation commands check their values and report what is simulated")
    func doorSimulationCommands() {
      defer { OnboardingDebugFaults.active.removeAll() }
      let world = OnboardingCoordinatorTests.World()
      let service = Self.service(Calls())
      let door = DevControlOnboarding(
        workflow: OnboardingWorkflowOwner(),
        makeSession: { _ in
          let c = world.coordinator()
          return .init(
            coordinator: c,
            runtime: OnboardingRuntime(
              coordinator: c, facts: OnboardingLiveFacts(),
              inputs: .init(
                readObservedFacts: { AnyHashable(0) }, downloadProgress: { nil },
                downloadsFinished: { false }, sampleAppleIntelligence: { .available },
                recheckAppleIntelligence: {}, now: { .now },
                // deadline-fallback: timers wait until stop() cancels them.
                sleep: { _ in try? await Task.sleep(for: .seconds(3600)) },
                pollInterval: .seconds(3600))))
        },
        checkpointData: { nil }, legacyState: { .notStarted }, permissions: service)
      func code(_ r: DevControlDispatcher.Result) -> String? {
        if case .error(let code, _) = r { return code }
        return nil
      }
      #expect(code(door.permissionsCommand(["mic": "maybe"])) == "badArgs")
      #expect(code(door.fault(["name": "meltdown"])) == "badArgs")
      #expect(code(door.profile(["ram": 0])) == "badArgs")
      #expect(code(door.profile([:])) == "badArgs")
      guard case .ok(let reply, _) = door.permissionsCommand(["mic": "granted", "ax": "denied"])
      else {
        Issue.record("permissions refused")
        return
      }
      let simulated = reply["simulated"] as? [String: Any]
      #expect((simulated?["permissions"] as? [String: Any])?["mic"] as? String == "granted")
      #expect(service.microphoneStatusLive == .authorized)
      _ = door.fault(["name": "disk-short"])
      #expect(OnboardingDebugFaults.active == [.diskShort])
      _ = door.fault(["clear": true])
      _ = door.permissionsCommand(["clear": true])
      #expect(OnboardingDebugFaults.active.isEmpty && service.simulated == nil)
    }
  }
#endif
