import EnviousWisprCore
import EnviousWisprServices

extension SetupSession {
  static func live(_ owners: OnboardingLiveOwners, progress: OnboardingProgress) -> SetupSession {
    SetupSession(
      progress: progress, permissions: owners.permissions,
      everCompleted: { owners.settings.onboardingEverCompleted }
    ) { session in
      let facts = OnboardingLiveFacts()
      let coordinator = OnboardingCoordinator(
        dependencies: .live(
          owners, facts: facts, sleepAssertion: OnboardingSleepAssertion(),
          onPracticeOutcome: { _ in },
          onCompleted: { [weak session] in session?.complete() }))
      let telemetry = OnboardingTelemetryObserver(
        inputs: .live(
          progress: progress, owners: owners, facts: facts,
          visitOwned: { [weak session] in session?.ownsVisit ?? false }))
      var inputs = OnboardingRuntime.Inputs.live(owners, facts: facts, coordinator: coordinator)
      inputs.observeTelemetry = telemetry.attach(to: coordinator)
      let runtime = OnboardingRuntime(coordinator: coordinator, facts: facts, inputs: inputs)
      return Components(
        coordinator: coordinator, runtime: runtime, telemetry: telemetry,
        downloadPhases: { choices in
          let downloads = OnboardingDownloads(
            owners: OnboardingLiveMapping.downloadOwners(owners, facts: facts))
          return (
            choices.speech.map { downloads.speechPhase($0) },
            choices.polish.flatMap { downloads.polishPhase($0) })
        },
        screenSources: SetupScreenSources(
          parakeetModelName: { owners.modelDelivery.parakeetModelLabel },
          egOneSizeCatalog: owners.egOneSizeCatalog,
          shortcut: SetupShortcutSources(
            binding: { owners.settings.shortcutBindings.record },
            change: { ShortcutSettings.assign($0, to: .record, in: owners.settings) },
            downloadsComplete: { [weak coordinator] in
              guard let coordinator else { return false }
              return OnboardingLiveMapping.downloadsFinished(
                coordinator.state.choices,
                downloads: OnboardingDownloads(
                  owners: OnboardingLiveMapping.downloadOwners(owners, facts: facts)))
            },
            monitor: owners.setupShortcutMonitor,
            suspendHotkeys: { owners.dictationRuntime.suspendHotkeys() },
            resumeHotkeys: { owners.dictationRuntime.resumeHotkeys() }),
          permissions: SetupPermissionsSources(
            microphone: { owners.permissions.microphoneStatusLive },
            accessibilityAllowed: { owners.permissions.accessibilityGrantedLive },
            dictationKey: {
              // The same spoken name the key screen reads for this binding.
              let record = owners.settings.shortcutBindings.record
              switch record {
              case .keyboard(let code, _):
                return KeySymbols.accessibilityDescription(
                  keyCode: code, modifiers: record.requiredModifiers)
              }
            },
            actions: .live(owners.permissions)),
          makeCloudPanel: { [weak telemetry, weak coordinator] provider in
            SetupCloudPanelModel.live(
              settings: owners.settings, writer: owners.credentials,
              list: owners.cloudModelList, provider: provider,
              report: { event in
                telemetry?.keyReported(
                  event, rulesVersion: coordinator?.state.recommended.rulesVersion ?? "")
              })
          },
          filmPlayback: SetupFilmPlayback(),
          practice: SetupPracticeSources(
            settings: owners.settings, devices: owners.audioDevices, live: owners.liveRecording,
            report: { [weak telemetry] result, seconds in
              telemetry?.practiceReported(result, duration: seconds)
            }),
          practiceProgress: SetupPracticeProgress(),
          reportStarted: { [weak telemetry] in telemetry?.setupStarted() }),
        activateApp: { owners.application.activate(.standard) },
        downloadsPresentation: { [weak coordinator, weak runtime] in
          guard let coordinator, let runtime else {
            return OnboardingDownloadsPresentation.make(
              state: OnboardingFlowState(), block: nil, warmFailed: false, queuedPolish: nil,
              isNetworkSlow: false, isCountingDown: false, speechPhase: { _ in .unknown },
              polishPhase: { _ in nil }, downloadsFinished: false)
          }
          let downloads = OnboardingDownloads(
            owners: OnboardingLiveMapping.downloadOwners(owners, facts: facts))
          return OnboardingDownloadsPresentation.make(
            state: coordinator.state, block: coordinator.block,
            warmFailed: coordinator.warmFailed, queuedPolish: coordinator.queuedPolishID,
            isNetworkSlow: runtime.isNetworkSlow, isCountingDown: runtime.isCountingDown,
            speechPhase: { downloads.speechPhase($0) }, polishPhase: { downloads.polishPhase($0) },
            downloadsFinished: OnboardingLiveMapping.downloadsFinished(
              coordinator.state.choices, downloads: downloads),
            speechStartPending: coordinator.speechStartsInFlight > 0,
            polishStartRequested: { coordinator.polishStartRequested($0) })
        },
        resolveInstalled: {
          let read = OnboardingLiveMapping.downloadOwners(owners, facts: facts)
          for engine in [ASRBackendType.parakeet, .whisper] {
            _ = await read.speechInstalled(engine)
          }
        })
    }
  }
}
