import AppKit
import CoreAudio
import EnviousWisprCore
import EnviousWisprPipeline
@testable import EnviousWisprServices
import SwiftUI
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit
@testable import EnviousWisprLivePreview
@testable import EnviousWisprStorage

/// #3385 lane A: real six-page Dictation host, isolated preferences and idle
/// capture/ASR doubles. Never orders a window in or drives the real app.
/// German-DRAFT renders substitute only the six supplied tab labels; their
/// page bodies remain English. Locale alone is not translation evidence.
/// TEST_RUNNER_EW_RENDER_DICTATION=1 <worktree>/scripts/xcode-test.sh
///   --filter EnviousWisprTests/DictationSettingsRenderHarness
@MainActor
@Suite("Dictation Settings render harness", .serialized, .tags(.harnessContract))
struct DictationSettingsRenderHarness {
  init() { _ = NSApplication.shared }
  static let runDirectory = RepoRoot.sourceURL(
    "build/pr1-lane-e/review-r1/renders/run-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))")

  final class NoOverlay: OverlayPresenting {
    var featureSlotIsAvailable: Bool { false }
    func present(_ request: PillRequest) -> PillReceipt? { nil }
    func present(_ request: PillRequest, onResult: @escaping (PillPresentationResult) -> Void) -> PillReceipt? {
      onResult(.notPresented); return nil
    }
    func update(_ update: PillUpdate) {}
    func dismissCurrent(_ mode: PillDismissal) {}
    func dismissIfCurrent(_ receipt: PillReceipt) {}
    func isCurrent(_ receipt: PillReceipt) -> Bool { false }
  }

  /// The real Microphone page requires a runtime even for a read-only media
  /// availability check. Assemble its existing graph with desktop doubles;
  /// never use WisprBootstrapper, register a hotkey, or load an engine.
  static func idleRuntime(
    settings: SettingsManager, audio: RouterTestAudioCapture, asr: RouterTestASRManager,
    recording: LiveRecordingState, store: TranscriptStore
  ) -> DictationRuntime {
    let overlay = OverlayTestDouble.headlessDirector()
    let hotkey = HotkeyService(effects: RecordingDesktopHotkeyEffects())
    let hold = OtherAudioHold(dependencies: .init(
      effects: OtherAudioEffects(volume: NoVolume(), media: NoMedia()),
      defaultOutputDeviceID: { nil },
      store: OtherAudioHoldStore(directory: runDirectory.appending(path: "fixture-holds")),
      telemetry: NoTelemetry(), log: { _ in }, nowMicros: { 0 }, sleep: { _ in },
      pid: 0, isProcessAlive: { _ in false }))
    let sync = PipelineSettingsSync(kernelDriver: recording.kernelDriver,
      whisperKitKernelDriver: recording.whisperKitKernelDriver, audioCapture: audio,
      asrManager: asr, hotkeyService: hotkey, ollamaRemotenessLookup: { _ in nil })
    let last = LastRecordingResult()
    let locked = DictationLifecycleCoordinator.RecordingLockedAccess(get: { false }, set: { _ in })
    let lease = EngineLease()
    let lifecycle = DictationLifecycleCoordinator(application: RecordingDesktopPresentationEffects(),
      kernelDriver: recording.kernelDriver, whisperKitKernelDriver: recording.whisperKitKernelDriver,
      recordingOverlay: overlay, hotkeyService: hotkey, settingsSync: sync,
      audioCapture: audio, transcriptCoordinator: TranscriptCoordinator(store: store),
      settings: settings, lastRecordingResult: last, languageSuggestionPresenter: nil,
      recordingLockedAccess: locked, releaseEngineClaim: { lease.release($0) }, otherAudioHold: hold)
    let spoolDirectory = runDirectory.appending(path: "fixture-spools")
    let recovery = RecoveryCoordinator(
      keyStore: RecoveryKeyStore(backend: .file, fileDirectory: runDirectory.appending(path: "fixture-recovery-keys")),
      makeSpoolStore: { RecoverySpoolStore(directory: spoolDirectory) },
      replayer: NoReplay(), existingRecoveryIDs: { [] }, isDictationActive: { false },
      recoveryEngineClaim: .alwaysAllowedForTesting,
      engineAdmission: .live(lease: lease, as: .crashRecovery))
    return DictationRuntime(audioCapture: audio, asrManager: asr,
      kernelDriver: recording.kernelDriver, whisperKitKernelDriver: recording.whisperKitKernelDriver,
      settings: settings, permissions: PermissionsService(accessibilityReader: { true },
        microphoneReader: { .authorized }, openMicrophoneSettings: { _ in }),
      recordingOverlay: overlay, hotkeyService: hotkey, lastRecordingResult: last,
      languageSuggestionPresenter: nil, dictationLifecycleCoordinator: lifecycle,
      otherAudioHold: hold, recoveryCoordinator: recovery, recordingLockedAccess: locked,
      engineAdmission: .live(lease: lease, as: .dictation),
      resolveActiveCaptureBackend: { nil }, resolveActiveTelemetryTarget: { nil }, isCurrentSession: { _ in false })
  }

  final class NoVolume: OutputVolumeControlling {
    func identity(of device: AudioDeviceID) -> OutputDeviceIdentity? { nil }
    func device(forUID uid: String) -> AudioDeviceID? { nil }
    func readVolume(of device: AudioDeviceID) -> OutputPropertyRead<Float> { .unsupported }
    func readMute(of device: AudioDeviceID) -> OutputPropertyRead<Bool> { .unsupported }
    func setVolume(_ volume: Float, of device: AudioDeviceID) -> Bool { Issue.record("unexpected volume write"); return false }
    func setMute(_ muted: Bool, of device: AudioDeviceID) -> Bool { Issue.record("unexpected mute write"); return false }
  }
  final class NoMedia: MediaPlaybackControlling {
    func pause(holdID: UUID, completion: @escaping @MainActor (MediaPauseOutcome) -> Void) { Issue.record("unexpected media pause"); completion(.failed) }
    func resume(holdID: UUID, completion: @escaping @MainActor (MediaResumeOutcome) -> Void) { Issue.record("unexpected media resume"); completion(.failed) }
    func resumeOrphan(holdID: UUID, targets: [String], completion: @escaping @MainActor (MediaResumeOutcome) -> Void) { Issue.record("unexpected orphan resume"); completion(.failed) }
    func preflightConsent(completion: @escaping @MainActor (Bool) -> Void) { Issue.record("unexpected consent probe"); completion(false) }
  }
  final class NoTelemetry: OtherAudioTelemetrySink {
    func recordTakeSummary(_ summary: OtherAudioTakeSummary) {}
    func recordMediaSettled(_ media: OtherAudioMediaDisposition, holdID: UUID, failure: String?, route: String?, adapterFailure: String?) {}
    func breadcrumb(_ message: String, data: [String: String]) {}
    func captureDefect(_ message: String, data: [String: String]) {}
  }
  final class NoReplay: RecoverySpoolReplaying {
    func replay(recoverySessionID: String, isAborted: @MainActor () -> Bool) async -> RecoveryReplayOutcome { .aborted }
  }

  /// All page environments are present. AudioDeviceList reads hardware and
  /// registers a listener, as its only initializer requires; the published
  /// list is replaced with an empty fixture. No capture is started. Delivery
  /// home is absent on full pages; no model fetch can start. Only staged fake
  /// install/removal/warm callbacks are supplied for the explicit state fixtures.
  /// Fresh Fast admission snapshots use their own sparse temporary files.
  struct Scenario {
    var label = "ordinary"
    var backend: ASRBackendType = .parakeet
    var setupState: WhisperKitSetupState = .notDownloaded
    var expanded = false
    var removing = false
    var preparing = false
    var previewOn = true
    var mode: LanguageMode = .locked("en")
    var active: LivePreviewPacksModel.ActiveLanguage = .ready(tag: "en-US", name: "English")
    var supported = ["en-US", "de-DE"]
    var installed = ["en-US"]
    var stagedInstall = false
    var staleLanguage = false
  }

  static func page(tab: DictationTab, german: Bool, scenario: Scenario = Scenario(),
    onFastReadFinished: @escaping @MainActor @Sendable (Bool?) -> Void = { _ in }) async throws -> AnyView {
    let defaults = try #require(TestDefaults.suite("ew.dictationRender.\(UUID().uuidString)"))
    let settings = SettingsManager(defaults: defaults)
    settings.selectedBackend = scenario.backend
    settings.languageMode = scenario.mode
    settings.livePreviewEnabled = scenario.previewOn
    settings.livePreviewEngine = .apple
    settings.otherAudioWhileDictating = .nothing
    let removalGate = InstallGate()
    let warmGate = InstallGate()
    if scenario.removing { Self.installGates.append(removalGate) }
    if scenario.preparing { Self.installGates.append(warmGate) }
    let service = WhisperKitSetupService(engineMutationScope: .alwaysAllowedForTesting,
      readAvailability: { scenario.setupState },
      startDownload: { Issue.record("render tried downloading"); return false },
      cancelActiveDownload: { Issue.record("render tried cancelling"); return false },
      removeModelAction: {
        if scenario.removing { await removalGate.wait(); return .failed }
        Issue.record("render tried removing"); return .failed
      })
    service.applyDeliveryState(scenario.setupState)
    if scenario.removing {
      service.isDictationInFlight = { false }
      service.removeModel()  // staged fake removal, no filesystem deletion capability
      try #require(service.isRemoving)
    }
    let setup = SetupCoordinator(asrManager: RouterTestASRManager(), whisperKitSetup: service,
      setupStateReader: { .notDownloaded }, preloadAction: { Issue.record("render tried preloading") },
      ollamaStatusProbe: { _ in })
    let presenter = LanguageSuggestionPresenter(overlay: NoOverlay(), onLanguageAccepted: { _ in }, defaults: defaults)
    let devices = AudioDeviceList()
    devices.availableInputDevices = []
    let audio = RouterTestAudioCapture()
    let asr = RouterTestASRManager()
    let store = TranscriptStore(directory: runDirectory.appending(path: "fixture-history"))
    let recording = LiveRecordingState(
      kernelDriver: DictationRuntimeFixtures.makeParakeetDriver(audioCapture: audio, asrManager: asr, store: store),
      whisperKitKernelDriver: DictationRuntimeFixtures.makeWhisperKitPipeline(audioCapture: audio, store: store),
      audioCapture: audio, asrManager: asr)
    let runtime = idleRuntime(settings: settings, audio: audio, asr: asr, recording: recording, store: store)
    let pill = PillAppearanceModel(settings: settings, capability: { .available })
    let supported = scenario.supported
    let installed = scenario.installed
    let stagedInstall = scenario.stagedInstall
    let active = scenario.active
    let installGate = InstallGate()
    if scenario.stagedInstall { Self.installGates.append(installGate) }
    let catalog = ApplePackCatalog(dependencies: .init(
      supportedTags: { supported }, installedTags: { installed },
      install: { _ in
        // A fake in-flight install fixture, never a macOS download. Parking is
        // supplied below before the render; ordinary rendering must not call it.
        if stagedInstall { await installGate.wait(); throw HarnessFailure.unexpectedWork }
        Issue.record("render tried installing a pack"); throw HarnessFailure.unexpectedWork
      }),
      claims: LocaleClaims(inventory: LocaleInventory(reserved: { [] },
        reserve: { _ in throw HarnessFailure.unexpectedWork }, release: { _ in false }, maximumReserved: { 5 })))
    let packs = LivePreviewPacksModel(catalog: catalog, resolveActive: { _ in active })
    packs.useMode { scenario.mode }
    await packs.load()
    if scenario.stagedInstall { packs.install(tag: "de-DE") }
    if scenario.staleLanguage { settings.languageMode = .locked("fr") }
    let root: AnyView
    if german || scenario.label != "ordinary" {
      // Same selected production page, with an explicitly labelled draft strip.
      let content: AnyView = switch tab {
      case .engine: AnyView(SpeechEngineSettingsView(choicesExpanded: scenario.expanded))
      case .microphone: AnyView(AudioSettingsView())
      case .livePreview: AnyView(LivePreviewSettingsView(packs: packs, choicesExpanded: scenario.expanded))
      case .pill: AnyView(PillSettingsView())
      case .chimes: AnyView(RecordingSoundsSettingsView())
      case .clipboard: AnyView(ClipboardSettingsView())
      }
      root = AnyView(GeometryReader { pane in
        VStack(spacing: 0) {
          SettingsTabStrip(items: SettingsTabStripLayoutTests.items(german: german), selection: .constant(tab))
            .frame(width: max(0, pane.size.width - 2 * (SettingsLayout.contentH - 4)))
            .padding(.horizontal, SettingsLayout.contentH - 4)
            .padding(.top, SettingsLayout.contentTop - 6)
          content.frame(width: pane.size.width)
        }.frame(width: pane.size.width, height: pane.size.height)
      }.background(Color.stPageBg).environment(\.settingsPR1Density, true))
    } else {
      root = AnyView(DictationSettingsView(selection: .constant(tab), packs: packs))
    }
    var hostedRoot = root
    if scenario.preparing {
      let fake = FakeEngineDeps(selected: .parakeet, active: .parakeet)
      fake.onWarmAwait = { await warmGate.wait() }
      let coordinator = fake.makeStartedCoordinator()
      fake.selected = .whisperKit
      coordinator.poke(.settingsChanged)
      let arrived = await enginePoll { coordinator.status.warmInFlight == .whisperKit }
      try #require(arrived, "the fake coordinator never reached its preparing state")
      hostedRoot = AnyView(hostedRoot.environment(coordinator))
    }
    if tab == .engine && scenario.backend == .parakeet {
      // The normal page now renders real async controller admission, rather
      // than omitting its home. Only sparse, isolated files are provided.
      let fixture = try ModelDeliveryHomeTests.fastRenderFixture()
      hostedRoot = AnyView(hostedRoot.environment(fixture.home))
      #if DEBUG
      hostedRoot = AnyView(hostedRoot.environment(\.fastAdmissionTestHooks,
        FastAdmissionTestHooks(read: { await fixture.home.currentParakeetAdmission() },
          onFinished: onFastReadFinished)))
      #endif
    }
    return AnyView(hostedRoot.environment(settings).environment(setup).environment(presenter)
      .environment(devices).environment(recording).environment(runtime).environment(pill)
      .environment(\.settingsNavigate, { _ in }))
  }

  // Fixture timer is unnecessary: a stored MainActor continuation parks the fake
  // installer until the matrix finishes. Real install/capture capabilities are absent.
  @MainActor final class InstallGate {
    var continuation: CheckedContinuation<Void, Never>?
    var released = false
    func wait() async {
      if released { return }
      await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
  }
  static var installGates: [InstallGate] = []

  enum HarnessFailure: Error { case unexpectedWork }

  static func render(_ page: AnyView, label: String, windowWidth: CGFloat, dark: Bool,
    waitForFastRead: FastAdmissionReadSignals? = nil) async throws -> URL {
    let width = AppearanceRenderHarness.pageWidth(window: windowWidth)
    let host = NSHostingView(rootView: page.frame(width: width, height: 1250)
      .environment(\.colorScheme, dark ? .dark : .light))
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.frame = CGRect(x: 0, y: 0, width: width, height: 1250)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = host.appearance; window.contentView = host
    let baseline = waitForFastRead?.count ?? 0
    host.layoutSubtreeIfNeeded()
    if let signal = waitForFastRead {
      try #require(await signal.wait(after: baseline), "render never received Fast admission reconciliation")
    }
    host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    let png = try #require(rep.representation(using: .png, properties: [:]))
    try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
    let url = runDirectory.appending(path: "state-\(label)-window-\(Int(windowWidth))-\(dark ? "dark" : "light").png")
    try png.write(to: url)
    print("STATE-RENDER \(label) pageFrame=\(host.bounds) visible=true scrollViewport=1250 -> \(url.path)")
    window.contentView = nil
    return url
  }

  @Test("render Engine setup states and Preview readiness/inventory using isolated owners",
    .enabled(if: ProcessInfo.processInfo.environment["EW_RENDER_DICTATION"] == "1"))
  func statePages() async throws {
    let engineStates: [(String, WhisperKitSetupState)] = [
      ("setup", .notDownloaded), ("checking", .checking), ("downloading", .downloading(progress: 0.42, status: "420 MB of 1000 MB")),
      ("paused", .paused), ("ready", .ready), ("error", .error("Model files could not be verified. Try again.")),
    ]
    var scenarios: [(DictationTab, Scenario)] = engineStates.map { label, state in
      (.engine, Scenario(label: "engine-\(label)", backend: .whisperKit, setupState: state))
    }
    scenarios.append((.engine, Scenario(label: "engine-expanded", backend: .whisperKit, setupState: .ready, expanded: true)))
    scenarios.append((.engine, Scenario(label: "engine-removing", backend: .whisperKit, setupState: .ready, removing: true)))
    scenarios.append((.engine, Scenario(label: "engine-preparing", backend: .whisperKit, setupState: .ready, preparing: true)))
    scenarios += [
      (.livePreview, Scenario(label: "preview-off", previewOn: false)),
      (.livePreview, Scenario(label: "preview-auto", mode: .auto)),
      (.livePreview, Scenario(label: "preview-missing-language", active: .needsDownload(name: "German"))),
      (.livePreview, Scenario(label: "preview-unsupported-language", active: .unsupportedLanguage)),
      (.livePreview, Scenario(label: "preview-expanded", expanded: true)),
      (.livePreview, Scenario(label: "preview-inventory-zero", active: .needsDownload(name: "English"), installed: [])),
      (.livePreview, Scenario(label: "preview-inventory-full", installed: ["en-US", "de-DE"])),
      (.livePreview, Scenario(label: "preview-stale-installing", stagedInstall: true, staleLanguage: true)),
    ]
    // Snapshots of the shared Fast summary from FRESH controller admission. The
    // full page's asynchronous re-check/focus is a live-UAT boundary, not inferred
    // from a synchronous offscreen bitmap. No fetch capability is called here.
    let fast = try ModelDeliveryHomeTests.fastRenderFixture()
    for admitted in [true, false] {
      if admitted == false { try FileManager.default.removeItem(at: fast.directory) }
      let actual = await fast.home.currentParakeetAdmission()
      try #require(actual == admitted)
      for german in [false, true] {
        for width: CGFloat in [750, 820, 1300] {
          for dark in [false, true] {
            let summary = SettingsContentView {
              SettingsSummaryCard(isExpanded: .constant(false),
                changeAccessibilityLabel: DictationSettingsCopy.Engine.changeEngine,
                keepCurrentTitle: DictationSettingsCopy.Engine.keepCurrent) {
                EngineSummaryContent(icon: "bolt.fill", name: "Fast", model: "Parakeet v3",
                  short: "For everyday English and European dictation")
              } status: {
                HStack {
                  ProviderStatusChip(status: EngineSummaryPresentation.fastModelStatus(admitted: actual), isHeadline: true)
                  Button {} label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel(Text(EngineSummaryCopy.recheckFast))
                }
              } choices: { EmptyView() }
              .statusAlongsideChange()
            }
            _ = try await Self.render(AnyView(summary), label: "\(german ? "German-DRAFT-English-body" : "English")-fast-admission-\(admitted ? "ready" : "missing")-snapshot", windowWidth: width, dark: dark)
          }
        }
      }
    }

    var made = 0
    // Staged-install LAST, so the one fake operation is held only for its own renders.
    for (tab, scenario) in scenarios {
      for german in [false, true] {
        let signal = FastAdmissionReadSignals()
        let page = try await Self.page(tab: tab, german: german, scenario: scenario,
          onFastReadFinished: { signal.record($0) })
        for width: CGFloat in [750, 820, 1300] {
          for dark in [false, true] {
            _ = try await Self.render(page, label: "\(german ? "German-DRAFT-tabs-English-body" : "English")-\(scenario.label)", windowWidth: width, dark: dark, waitForFastRead: tab == .engine && scenario.backend == .parakeet ? signal : nil)
            made += 1
          }
        }
        // No real download: the only staged fixture requests the catalog's parked fake.
        for gate in Self.installGates { gate.release() }
        Self.installGates.removeAll()
      }
    }
    #expect(made == scenarios.count * 12)
    print("STATE MATRIX: \(made) PNGs. No real Speech install/capture, no dev app. Expanded, ready/off, setup/error, missing/stale/installing, loaded zero/partial/full. German tabs are drafts.")
  }

  @Test("the strip keeps real button selection, focus and decorative exclusions")
  func stripContract() throws {
    let source = try String(contentsOf: RepoRoot.sourceURL(
      "Sources/EnviousWisprAppKit/Views/Settings/SettingsComponents.swift"), encoding: .utf8)
    let start = try #require(source.range(of: "struct SettingsTabStrip"))
    let end = try #require(source.range(of: "// MARK: - Summary card", range: start.lowerBound..<source.endIndex))
    let strip = String(source[start.lowerBound..<end.lowerBound])
    #expect(strip.contains(".focused($focusedTab, equals: item.id)"))
    #expect(strip.contains("selection = item.id"))
    #expect(strip.contains(".contentShape(Rectangle())"))
    #expect(strip.contains(".accessibilityValue(isSelected ? SettingsCopy.selectedValue : SettingsCopy.notSelectedValue)"))
    #expect(strip.contains(".accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)"))
    #expect(strip.contains("ScrollView") == false)
    #expect(strip.components(separatedBy: ".allowsHitTesting(false)").count - 1 == 4)
  }

  @Test("render all six selected pages at three window widths, light/dark, English/German drafts",
    .enabled(if: ProcessInfo.processInfo.environment["EW_RENDER_DICTATION"] == "1"))
  func sixPages() async throws {
    try FileManager.default.createDirectory(at: Self.runDirectory, withIntermediateDirectories: true)
    var made: [URL] = []
    for german in [false, true] {
      for tab in DictationTab.allCases {
        let signal = FastAdmissionReadSignals()
        let page = try await Self.page(tab: tab, german: german,
          onFastReadFinished: { signal.record($0) })
        for windowWidth: CGFloat in [750, 820, 1300] {
          let width = AppearanceRenderHarness.pageWidth(window: windowWidth)
          for dark in [false, true] {
            let label = "\(german ? "German-DRAFT-tabs-English-body" : "English")-\(tab)"
            let url = try await Self.render(page, label: label, windowWidth: windowWidth, dark: dark,
              waitForFastRead: tab == .engine ? signal : nil)
            let decoded = try #require(NSBitmapImageRep(data: try Data(contentsOf: url)))
            #expect(decoded.pixelsWide > 0 && decoded.pixelsHigh > 0)
            let strip = try SettingsTabStripLayoutTests.measure(width: width - 2 * (SettingsLayout.contentH - 4), german: german)
            print("RENDERED \(label) pageWidth=\(width) measuredStripHeight=\(strip.height) -> \(url.path)")
            for tab in DictationTab.allCases {
              print("RENDER-TAB \(label) \(tab) measured=\(try #require(strip.frames[tab]))")
            }
            made.append(url)
          }
        }
      }
    }
    #expect(made.count == 72 && Set(made).count == 72)
    print("RENDER MATRIX: 72 PNGs; English production Dictation host, German-DRAFT tabs/English bodies. No live AX/focus or app interaction. \(Self.runDirectory.path)")
  }
}
