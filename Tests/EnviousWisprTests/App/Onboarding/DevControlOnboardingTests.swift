#if DEBUG
  import EnviousWisprCore
  import Foundation
  import Testing

  @testable import EnviousWisprAppKit
  @testable import EnviousWisprServices

  /// #4528 C2c.2a: the new Setup's DEBUG door session and Setup's single owner.
  ///
  /// **Harness Contract.** When this fails, CLI UAT drives the wrong workflow, runs the new
  /// coordinator while the old onboarding still writes Setup's settings, reports a refused step
  /// as moved, or a status read changes Setup.
  @MainActor
  @Suite(.tags(.harnessContract))
  struct DevControlOnboardingTests {
    private final class Box {
      var built = 0
    }

    private static func make(
      _ world: OnboardingCoordinatorTests.World = .init(),
      workflow: OnboardingWorkflowOwner = .init(),
      box: Box = Box()
    ) -> (DevControlOnboarding, OnboardingWorkflowOwner, OnboardingCoordinatorTests.World) {
      let door = DevControlOnboarding(
        workflow: workflow,
        makeSession: {
          box.built += 1
          let coordinator = world.coordinator()
          let runtime = OnboardingRuntime(
            coordinator: coordinator, facts: OnboardingLiveFacts(),
            inputs: .init(
              readObservedFacts: { AnyHashable(0) }, downloadProgress: { nil },
              downloadsFinished: { false }, sampleAppleIntelligence: { .available },
              recheckAppleIntelligence: {}, now: { Date(timeIntervalSince1970: 0) },
              // deadline-fallback: timers wait until stop() cancels them.
              sleep: { _ in try? await Task.sleep(for: .seconds(3600)) },
              pollInterval: .seconds(3600)))
          return .init(coordinator: coordinator, runtime: runtime)
        },
        checkpointData: { world.checkpoint }, legacyState: { world.legacy })
      return (door, workflow, world)
    }

    private static func payload(_ result: DevControlDispatcher.Result) -> [String: Any]? {
      if case .ok(let payload, _) = result { return payload }
      return nil
    }

    private static func code(_ result: DevControlDispatcher.Result) -> String? {
      if case .error(let code, _) = result { return code }
      return nil
    }

    @Test("status only reads: it builds no session and changes nothing")
    func statusReadsOnly() {
      let box = Box()
      let (door, workflow, world) = Self.make(box: box)
      let reply = Self.payload(door.status())
      #expect(reply?["owner"] as? String == "none" && reply?["sessionBuilt"] as? Bool == false)
      #expect(box.built == 0 && workflow.backendSessionActive == false && world.log.isEmpty)
    }

    @Test("a session refuses while the old onboarding is open or still working")
    func refusesWhileLegacyBusy() {
      let (door, workflow, _) = Self.make()
      workflow.beginLegacyWork()
      #expect(Self.code(door.begin()) == "busy")
      #expect(Self.code(door.reset()) == "busy")
      workflow.endLegacyWork()
      workflow.legacyWindowVisible = { true }
      #expect(Self.code(door.begin()) == "busy")
      #expect(workflow.backendSessionActive == false)
    }

    @Test("begin claims Setup and blocks the old window; stop gives it back")
    func beginAndStopOwnership() {
      let (door, workflow, _) = Self.make()
      let reply = Self.payload(door.begin())
      #expect(reply?["opened"] as? Bool == true && reply?["owner"] as? String == "backend")
      #expect(workflow.legacyMayOpen == false)
      _ = door.stop()
      #expect(workflow.backendSessionActive == false && workflow.legacyMayOpen)
    }

    @Test("a completed install opens no session and keeps Setup unowned")
    func completedOpensNothing() {
      let world = OnboardingCoordinatorTests.World()
      world.legacy = .completed
      let (door, workflow, _) = Self.make(world)
      #expect(Self.payload(door.begin())?["opened"] as? Bool == false)
      #expect(workflow.backendSessionActive == false)
    }

    @Test("send reports moved, stayed and refused honestly; readiness cannot be sent")
    func sendOutcomes() {
      let (door, _, _) = Self.make()
      #expect(Self.code(door.send(["event": "next"])) == "rejected")  // No session yet.
      _ = door.begin()
      #expect(Self.payload(door.send(["event": "next"]))?["outcome"] as? String == "moved")
      #expect(
        Self.payload(door.send(["event": "chooseLanguage", "value": "de"]))?["outcome"] as? String
          == "stayed")
      _ = door.goto(["step": "permissions"])
      let refused = Self.payload(door.send(["event": "next"]))
      #expect(refused?["outcome"] as? String == "refused")
      #expect(refused?["reason"] as? String == "microphone and accessibility are not both granted")
      #expect(Self.code(door.send(["event": "readinessChanged"])) == "badArgs")
      #expect(Self.code(door.send(["event": "chooseSpeech", "value": "dragon"])) == "badArgs")
    }

    @Test("goto positions and saves the step but proves nothing; done is refused")
    func gotoPositions() {
      let (door, _, world) = Self.make()
      _ = door.begin()
      let reply = Self.payload(door.goto(["step": "key"]))
      #expect(reply?["step"] as? String == "key")
      #expect(OnboardingCheckpoint.decode(world.checkpoint)?.step == .key)
      #expect((reply?["readiness"] as? [String: Any])?["microphone"] as? Bool == false)
      #expect(Self.code(door.goto(["step": "done"])) == "badArgs")
    }

    @Test("reset starts at Welcome through the runtime and the session is built once")
    func resetBuildsOnce() {
      let box = Box()
      let (door, _, world) = Self.make(box: box)
      _ = door.begin()
      _ = door.send(["event": "next"])
      let reply = Self.payload(door.reset())
      #expect(reply?["step"] as? String == "welcome" && world.log.contains("restart"))
      _ = door.reset()
      #expect(box.built == 1)
    }

    @Test("old work cannot start once a session owns Setup")
    func legacyRefusedAfterBackendClaim() {
      let workflow = OnboardingWorkflowOwner()
      #expect(workflow.claimBackendSession())
      let vm = OnboardingV2ViewModel()
      vm.workflowOwner = workflow
      vm.currentScreen = .warmingUp
      vm.kickWarmingIfNeeded(warmUp: { .ready }, displayFloor: 0)
      #expect(vm.warmingTask == nil && workflow.legacyTasks == 0)
    }

    @Test("an old window whose open is still pending blocks a session claim")
    func pendingLegacyOpenBlocksClaim() {
      let workflow = OnboardingWorkflowOwner()
      let windows = AppWindowCoordinator(
        application: RecordingDesktopPresentationEffects(), showInDock: { true },
        canOpenOnboarding: { workflow.legacyMayOpen }, isOnboardingComplete: { false })
      workflow.legacyWindowVisible = { windows.isOnboardingWindowVisible }
      windows.openOnboardingWindow()  // Not wired yet: queued, window not created.
      #expect(windows.isOnboardingWindowVisible)
      #expect(workflow.claimBackendSession() == false)
      windows.closeOnboardingWindow()
      #expect(workflow.claimBackendSession())
      windows.openOnboardingWindow()
      #expect(windows.isOnboardingWindowVisible == false)  // Refused while the session owns Setup.
    }

    @Test("the door refuses choices no Setup button offers")
    func refusesUnofferedValues() {
      for args: [String: Any] in [
        ["event": "chooseLanguage", "value": "zz"],
        ["event": "choosePolish", "value": "eg1.huge"],
        ["event": "choosePolish", "value": OnboardingChoices.polishOff],
        ["event": "chooseCloud", "provider": "none", "model": "x"],
        ["event": "chooseCloud", "provider": "ollama", "model": "llama3"],
      ] {
        guard case .failure = DevControlOnboarding.event(from: args) else {
          Issue.record("accepted \(args)")
          continue
        }
      }
      guard case .success(.chooseLanguage(.locked("de"))) = DevControlOnboarding.event(
        from: ["event": "chooseLanguage", "value": "de"])
      else {
        Issue.record("de refused")
        return
      }
    }

    @Test("the old onboarding reports each long-lived task while it runs")
    func legacyTasksReported() async {
      let workflow = OnboardingWorkflowOwner()
      let vm = OnboardingV2ViewModel()
      vm.workflowOwner = workflow
      vm.currentScreen = .warmingUp
      vm.kickWarmingIfNeeded(warmUp: { .ready }, displayFloor: 0)
      #expect(workflow.legacyTasks == 1 && workflow.current == .legacy)
      await vm.warmingTask?.value
      #expect(workflow.legacyTasks == 0 && workflow.current == .none)
    }
  }
#endif
