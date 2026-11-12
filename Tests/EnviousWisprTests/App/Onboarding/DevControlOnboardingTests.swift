#if DEBUG
  import AppKit
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
    // The window test reaches AppKit window code; NSApp is nil in a non-hosted run until this.
    init() { _ = NSApplication.shared }

    private final class Box {
      var built = 0
      /// The owner's read-only answer the catalog query records (nil: the query does nothing).
      var ownerAnswer: OnboardingDownloadPhase?
      var queries = 0
      var queried: (() -> Void)?
    }

    private static func make(
      _ world: OnboardingCoordinatorTests.World = .init(),
      workflow: OnboardingWorkflowOwner = .init(),
      box: Box = Box(),
      telemetry: OnboardingTelemetryObserver? = nil
    ) -> (DevControlOnboarding, OnboardingWorkflowOwner, OnboardingCoordinatorTests.World) {
      let door = DevControlOnboarding(
        workflow: workflow,
        makeSession: { _ in
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
          return .init(
            coordinator: coordinator, runtime: runtime, telemetry: telemetry,
            downloadPhases: { choices in
              ["speech": DevControlOnboarding.phaseName(choices.speech.map {
                world.speechPhase[$0] ?? .notStarted
              })]
            },
            resolveInstalled: {
              box.queries += 1
              if let answer = box.ownerAnswer { world.speechPhase[.parakeet] = answer }
              box.queried?()
            })
        },
        checkpointData: { world.checkpoint }, legacyState: { world.legacy })
      return (door, workflow, world)
    }

    @Test("the launch hold keeps the old onboarding closed until stop; status reads the flow's recommendation and download phases")
    func launchHoldAndStatusFields() {
      let (door, workflow, world) = Self.make()
      world.speechPhase[.parakeet] = .installed
      #expect(door.holdForUAT())
      #expect(!workflow.legacyMayOpen && workflow.current == .backend)
      _ = door.begin()
      _ = door.send(["event": "next"])
      _ = door.send(["event": "next"])
      _ = door.send(["event": "chooseSpeech", "value": "parakeet"])
      let status = Self.payload(door.status())
      let recommended = status?["recommended"] as? [String: Any]
      #expect(recommended?["speech"] as? String == "parakeet")
      #expect(recommended?["polish"] as? String == "eg1.mini")
      #expect(recommended?["rulesVersion"] as? String == "rules-a")  // the World's captured version
      #expect((status?["downloads"] as? [String: Any])?["speech"] as? String == "installed")
      // The catalog reads every engine's phase without choosing one: the pick stays Parakeet.
      let catalog = status?["catalog"] as? [String: Any]
      let speechCatalog = catalog?["speech"] as? [String: Any]
      #expect(speechCatalog?["parakeet"] as? String == "installed")
      #expect(speechCatalog?["whisper"] as? String == "notStarted")
      let polishIDs = Set(((catalog?["polish"] as? [String: Any]) ?? [:]).keys)
      #expect(polishIDs.contains("eg1.mini"))
      let after = Self.payload(door.status())
      #expect((after?["choices"] as? [String: Any])?["speech"] as? String == "parakeet")
      _ = door.stop()
      #expect(workflow.legacyMayOpen)
    }

    @Test("a cold Parakeet admission with no pick is answered by one read-only owner query, never a choice")
    func catalogResolvesColdAdmission() async {
      let box = Box()
      box.ownerAnswer = .installed  // upgrade-served Parakeet the base mirror does not show
      let (door, _, world) = Self.make(box: box)
      world.speechPhase[.parakeet] = .unknown  // empty admission cache
      let queried = AsyncStream<Void> { continuation in
        box.queried = { continuation.yield() }
      }
      _ = door.reset()  // its own status reply may already start the query
      let first = Self.payload(door.status())
      let firstSpeech = (first?["catalog"] as? [String: Any])?["speech"] as? [String: Any]
      #expect(firstSpeech?["parakeet"] as? String == "unknown")
      var signals = queried.makeAsyncIterator()
      _ = await signals.next()  // the owner query ran (its own signal, no timer)
      _ = Self.payload(door.status())  // a second read while answered starts nothing new
      let second = Self.payload(door.status())
      let speech = (second?["catalog"] as? [String: Any])?["speech"] as? [String: Any]
      #expect(speech?["parakeet"] as? String == "installed")
      #expect(box.queries == 1, "repeated status reads started \(box.queries) owner queries")
      let picks = second?["choices"] as? [String: Any]
      #expect(picks?["speech"] is NSNull, "the query chose an engine")
      _ = door.stop()
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

    @Test("present needs the running backend session, refocuses one window, and stop closes it (D0)")
    func presentLifecycle() {
      let (door, workflow, _) = Self.make()
      #expect(Self.code(door.present()) == "rejected", "presented with no session")
      _ = door.begin()
      let first = Self.payload(door.present())
      #expect(first?["presented"] as? Bool == true && first?["step"] as? String == "welcome")
      _ = door.send(["event": "next"])
      let again = Self.payload(door.present())  // refocus: same flow, not restarted
      #expect(again?["presented"] as? Bool == true && again?["step"] as? String == "language")
      #expect(NSApp.windows.filter { $0.title == "Setup" && $0.isVisible }.count == 1)
      _ = door.stop()
      #expect(Self.payload(door.status())?["presented"] as? Bool == false)
      #expect(NSApp.windows.filter { $0.title == "Setup" && $0.isVisible }.isEmpty)
      #expect(workflow.legacyMayOpen)
    }

    @Test("closing the Setup window keeps the flow; placeholders send no screen rows (D0, M67)")
    func closeKeepsFlowAndPlaceholdersSendNothing() throws {
      let recorder = OnboardingTelemetryObserverTests.Recorder()
      let observer = recorder.observer()
      let (door, _, _) = Self.make(telemetry: observer)
      _ = door.begin()
      _ = door.send(["event": "next"])
      _ = door.send(["event": "chooseLanguage", "value": "auto"])
      _ = door.send(["event": "next"])  // Speech pick: still a placeholder
      _ = door.present()
      _ = door.send(["event": "compareSpeech"])  // another placeholder
      let window = try #require(NSApp.windows.first { $0.title == "Setup" && $0.isVisible })
      window.close()
      let status = Self.payload(door.status())
      #expect(status?["presented"] as? Bool == false)
      #expect(status?["active"] as? Bool == true && status?["step"] as? String == "speechCompare")
      #expect(recorder.rows.isEmpty, "a placeholder or step change sent screen rows")
      _ = door.present()  // reattaches to the same flow
      #expect(Self.payload(door.status())?["step"] as? String == "speechCompare")
      _ = door.stop()
    }

    @Test("steps moved with no window shown send no screen rows (D1, M67)")
    func hiddenStepsReportNothing() {
      let recorder = OnboardingTelemetryObserverTests.Recorder()
      let observer = recorder.observer()
      let (door, _, _) = Self.make(telemetry: observer)
      _ = door.begin()
      _ = door.send(["event": "next"])  // Language, no window
      _ = door.send(["event": "back"])  // Welcome, still no window
      #expect(recorder.rows.isEmpty, "a hidden step sent a screen row")
      _ = door.stop()
    }

    @Test("hide, navigate and mount while off screen, then show: one row, for the shown screen (D1, M67)")
    func offScreenMountsReportOnlyWhenShown() throws {
      let recorder = OnboardingTelemetryObserverTests.Recorder()
      let observer = recorder.observer()
      let world = OnboardingCoordinatorTests.World()
      let coordinator = world.coordinator()
      coordinator.begin()
      let presenter = DevControlSetupPresenter()
      presenter.isOnScreen = { $0.isVisible }  // no window-server occlusion in a test process
      presenter.show(coordinator: coordinator, telemetry: observer)
      let model = try #require(presenter.screenModel)
      model.screenMounted(.welcome, epoch: model.routeEpoch)
      #expect(recorder.rows.map(\.0) == ["welcome"])
      let window = try #require(NSApp.windows.first { $0.title == "Setup" && $0.isVisible })
      let note = Notification(name: NSWindow.didChangeOcclusionStateNotification, object: window)
      window.orderOut(nil)  // hidden without closing
      presenter.windowDidChangeOcclusionState(note)
      coordinator.send(.next)
      model.screenMounted(.language, epoch: model.routeEpoch)
      #expect(recorder.rows.map(\.0) == ["welcome"], "a screen mounted off screen sent a row")
      presenter.show(coordinator: coordinator, telemetry: observer)  // refocus: back on screen
      #expect(recorder.rows.map(\.0) == ["welcome", "language"])
      presenter.show(coordinator: coordinator, telemetry: observer)  // refocus again: nothing new
      presenter.windowDidChangeOcclusionState(note)
      #expect(recorder.rows.map(\.0) == ["welcome", "language"])
      presenter.close()
      #expect(presenter.screenModel == nil && coordinator.onChange == nil)
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

    @Test("Restart Onboarding reaches the session that owns Setup, else the old onboarding")
    func restartRouting() {
      let workflow = OnboardingWorkflowOwner()
      let windows = AppWindowCoordinator(
        application: RecordingDesktopPresentationEffects(), showInDock: { true },
        canOpenOnboarding: { workflow.legacyMayOpen }, isOnboardingComplete: { false })
      windows.onboardingWorkflow = workflow
      var legacyRestarts = 0
      windows.restartOnboarding { legacyRestarts += 1 }
      #expect(legacyRestarts == 1)
      windows.closeOnboardingWindow()

      let world = OnboardingCoordinatorTests.World()
      let (door, _, _) = Self.make(world, workflow: workflow)
      _ = door.begin()
      _ = door.send(["event": "next"])
      windows.restartOnboarding { legacyRestarts += 1 }
      #expect(legacyRestarts == 1 && door.session?.coordinator.state.step == .welcome)
      #expect(world.log.contains("restart"))
    }

    @Test("a successful finish lands in the menu bar without reopening the main window")
    func finishToMenuBar() {
      let windows = AppWindowCoordinator(
        application: RecordingDesktopPresentationEffects(), showInDock: { true },
        canOpenOnboarding: { true }, isOnboardingComplete: { true })
      var dismissed = 0
      var mainOpened = 0
      var observed = 0
      windows.dismissOnboardingAction = { dismissed += 1 }
      windows.openMainWindowAction = { mainOpened += 1 }
      windows.onOnboardingDismissed = { observed += 1 }
      windows.finishOnboardingToMenuBar()
      #expect(dismissed == 1 && observed == 1 && mainOpened == 0)
      windows.closeOnboardingWindow()  // the old completion still restores the main window
      #expect(mainOpened == 1)
    }

    @Test("a session visit begins once, abandons at most once, and a completed visit never abandons")
    func visitTerminals() {
      let progress = OnboardingProgress()
      let workflow = OnboardingWorkflowOwner()
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
        checkpointData: { nil }, legacyState: { world.legacy }, progress: progress)
      _ = door.begin()
      #expect(progress.isInFlight)
      let started = progress.sessionStart
      _ = door.reset()  // a reset of a live visit never rewinds it
      #expect(progress.sessionStart == started)
      workflow.backendQuit?()  // app quit while the session owns Setup
      #expect(progress.isInFlight == false && workflow.backendSessionActive == false)
      _ = door.stop()  // close after quit: no second abandon, nothing in flight
      #expect(progress.isInFlight == false)

      _ = door.begin()
      #expect(progress.isInFlight)
      door.sessionCompleted()
      #expect(progress.isInFlight == false && workflow.backendSessionActive == false)
    }

    @Test("an idle stop never ends the old onboarding's live visit")
    func idleStopLeavesLegacyVisit() {
      let progress = OnboardingProgress()
      let workflow = OnboardingWorkflowOwner()
      workflow.legacyWindowVisible = { true }  // the old Setup window is open
      progress.begin(source: "first_run")  // its visit (the old onboarding's ActionWirer begins it)
      let door = DevControlOnboarding(
        workflow: workflow, makeSession: { _ in fatalError("stop must not build a session") },
        checkpointData: { nil }, legacyState: { .notStarted }, progress: progress)
      _ = door.stop()
      door.sessionCompleted()
      #expect(progress.isInFlight)
      #expect(workflow.current == .legacy)
    }

    @Test("a session's screen rows exist only while its own visit is in flight")
    func sessionScreenRowsFollowOwnership() {
      let progress = OnboardingProgress()
      var rows: [String] = []
      func door(_ world: OnboardingCoordinatorTests.World) -> DevControlOnboarding {
        DevControlOnboarding(
          workflow: OnboardingWorkflowOwner(),
          makeSession: { door in
            let c = world.coordinator()
            let recorder = OnboardingTelemetryObserverTests.Recorder()
            var inputs = recorder.observerInputs()
            inputs.visitStart = { progress.isInFlight ? progress.sessionStart : nil }
            inputs.visitOwned = { [weak door] in door?.ownsVisit ?? false }
            inputs.emitScreenViewed = { step, _, _ in rows.append(step) }
            let telemetry = OnboardingTelemetryObserver(inputs: inputs)
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
                  pollInterval: .seconds(3600))),
              telemetry: telemetry)
          },
          checkpointData: { nil }, legacyState: { world.legacy }, progress: progress)
      }
      let world = OnboardingCoordinatorTests.World()
      let d = door(world)
      _ = d.begin()
      d.session?.telemetry?.screenPresented(.welcome, resumed: false)
      _ = d.stop()
      d.session?.telemetry?.screenPresented(.language, resumed: false)
      #expect(rows == ["welcome"])

      let completed = OnboardingCoordinatorTests.World()
      completed.legacy = .completed
      let c = door(completed)
      _ = c.begin()  // a completed install opens nothing and begins no visit
      c.session?.telemetry?.screenPresented(.welcome, resumed: false)
      #expect(rows == ["welcome"] && progress.isInFlight == false)
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
