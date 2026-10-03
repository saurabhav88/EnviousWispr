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
@Suite("Dictation Settings render harness", .tags(.harnessContract))
struct DictationSettingsRenderHarness {
  init() { _ = NSApplication.shared }
  static let runDirectory = RepoRoot.sourceURL(
    "build/pr1-lane-a/renders/run-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))")

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
  /// home is absent, so no admission, download or install is possible here.
  static func page(tab: DictationTab, german: Bool) async throws -> AnyView {
    let defaults = try #require(TestDefaults.suite("ew.dictationRender.\(UUID().uuidString)"))
    let settings = SettingsManager(defaults: defaults)
    settings.selectedBackend = .parakeet
    settings.languageMode = .locked("en")
    settings.livePreviewEnabled = true
    settings.livePreviewEngine = .apple
    settings.otherAudioWhileDictating = .nothing
    let setup = SetupCoordinator(asrManager: RouterTestASRManager(),
      whisperKitSetup: WhisperKitSetupService(engineMutationScope: .alwaysAllowedForTesting),
      setupStateReader: { .notDownloaded }, preloadAction: {}, ollamaStatusProbe: { _ in })
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
    let catalog = ApplePackCatalog(dependencies: .init(
      supportedTags: { ["en-US", "de-DE"] }, installedTags: { ["en-US"] },
      install: { _ in throw HarnessFailure.unexpectedWork }),
      claims: LocaleClaims(inventory: LocaleInventory(reserved: { [] },
        reserve: { _ in throw HarnessFailure.unexpectedWork }, release: { _ in false }, maximumReserved: { 5 })))
    let packs = LivePreviewPacksModel(catalog: catalog, resolveActive: { _ in .ready(tag: "en-US", name: "English") })
    packs.useMode { .locked("en") }
    await packs.load()
    let root: AnyView
    if german {
      // Same selected production page, with an explicitly labelled draft strip.
      let content: AnyView = switch tab {
      case .engine: AnyView(SpeechEngineSettingsView())
      case .microphone: AnyView(AudioSettingsView())
      case .livePreview: AnyView(LivePreviewSettingsView(packs: packs))
      case .pill: AnyView(PillSettingsView())
      case .chimes: AnyView(RecordingSoundsSettingsView())
      case .clipboard: AnyView(ClipboardSettingsView())
      }
      root = AnyView(VStack(spacing: 0) {
        SettingsTabStrip(items: SettingsTabStripLayoutTests.items(german: true), selection: .constant(tab))
          .padding(.horizontal, SettingsLayout.contentH - 4)
          .padding(.top, SettingsLayout.contentTop - 6)
        content
      }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.stPageBg))
    } else {
      root = AnyView(DictationSettingsView(selection: .constant(tab), packs: packs))
    }
    return AnyView(root.environment(settings).environment(setup).environment(presenter)
      .environment(devices).environment(recording).environment(runtime).environment(pill)
      .environment(\.settingsNavigate, { _ in }))
  }

  enum HarnessFailure: Error { case unexpectedWork }

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
        let page = try await Self.page(tab: tab, german: german)
        for windowWidth: CGFloat in [750, 820, 1300] {
          let width = AppearanceRenderHarness.pageWidth(window: windowWidth)
          for dark in [false, true] {
            let content = page.frame(width: width, height: 900)
              .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: content)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = CGRect(x: 0, y: 0, width: width, height: 900)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = host.appearance
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            let label = "\(german ? "German-DRAFT-tabs-English-body" : "English")-\(tab)-window-\(Int(windowWidth))-\(dark ? "dark" : "light")"
            let url = Self.runDirectory.appending(path: "\(label).png")
            try #require(FileManager.default.fileExists(atPath: url.path) == false)
            try png.write(to: url)
            let decoded = try #require(NSBitmapImageRep(data: try Data(contentsOf: url)))
            #expect(decoded.pixelsWide > 0 && decoded.pixelsHigh > 0)
            let strip = try SettingsTabStripLayoutTests.measure(width: width - 2 * (SettingsLayout.contentH - 4), german: german)
            print("RENDERED \(label) host=\(host.bounds) measuredStripHeight=\(strip.height) -> \(url.path)")
            for tab in DictationTab.allCases {
              print("RENDER-TAB \(label) \(tab) measured=\(try #require(strip.frames[tab]))")
            }
            window.contentView = nil
            made.append(url)
          }
        }
      }
    }
    #expect(made.count == 72 && Set(made).count == 72)
    print("RENDER MATRIX: 72 PNGs; English production Dictation host, German-DRAFT tabs/English bodies. No live AX/focus or app interaction. \(Self.runDirectory.path)")
  }
}
