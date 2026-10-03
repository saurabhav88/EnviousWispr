import AppKit
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Observation
import SwiftUI
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit
@testable import EnviousWisprLLM
@testable import EnviousWisprLivePreview

/// #3385: renders production pages and the catalog-routed advisory ROOT.
/// This is an instrument, not Live UAT: no real app, AX, navigation or spoken
/// delivery is driven. Page widths follow the production shell; no standalone
/// Text stands in for a page. Settings, key storage, audio/engine admission and
/// language inventory are isolated fixtures. No model is loaded or downloaded.
///
/// TEST_RUNNER_EW_RENDER_SETTINGS_ADVISORY=1 <worktree>/scripts/xcode-test.sh \
///   --filter EnviousWisprTests/SettingsAdvisoryRenderHarness
@MainActor
@Suite("Settings advisory render harness", .tags(.harnessContract))
struct SettingsAdvisoryRenderHarness {
  init() { _ = NSApplication.shared }

  static let runDirectory = RepoRoot.sourceURL(
    "build/pr1-lane-b/renders/run-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))")

  /// A will-change signal from the SUBJECT, never a stub's completion. The
  /// caller resumes on MainActor after the synchronous state write lands.
  private static func nextState(_ coordinator: FileImportCoordinator) -> AsyncStream<Void> {
    AsyncStream { continuation in
      withObservationTracking { _ = coordinator.state } onChange: {
        continuation.yield(())
        continuation.finish()
      }
    }
  }

  private static func awaitSignal(_ stream: AsyncStream<Void>, seconds: Double = 5) async throws {
    // deadline-fallback: same 5s hang guard as PipelineStateWaiter; never a latency assertion.
    let signalled = try await withThrowingTimeout(seconds: seconds) {
      var iterator = stream.makeAsyncIterator()
      return await iterator.next() != nil
    }
    try #require(signalled, "state observation ended without a signal")
  }

  @Test("The render fixture's signal wait gives up when the subject never changes")
  func absentSignalHasDeadline() async {
    let stream = AsyncStream<Void> { _ in }
    await #expect(throws: TimeoutError.self) {
      try await Self.awaitSignal(stream, seconds: 0.01)
    }
  }

  private static func rejectedImport() async throws -> FileImportCoordinator {
    let coordinator = FileImportCoordinator(
      decode: { _ in
        AudioFileDecoder.Decoded(
          samples: [0.1], seconds: 60, byteCount: 1_024, codec: "AAC",
          sampleRate: 44_100, channelCount: 1)
      },
      transcribe: { _, _ in throw HarnessFailure.unexpectedWork },
      engineAdmission: .live(lease: EngineLease(), as: .fileImport),
      ensureEngineReady: { .notInstalled },
      beginRun: {
        .init(polishIsCloud: false, localPolishProvider: nil, polishProvider: .none,
          ollamaModel: nil, polishModel: "", backendType: .parakeet)
      },
      saveToHistory: { _ in throw HarnessFailure.unexpectedWork },
      updateHistoryRow: { _ in throw HarnessFailure.unexpectedWork },
      mergeSpeakerFields: { _, _, _ in throw HarnessFailure.unexpectedWork },
      historyRowExists: { _ in false },
      processPart: { _, _ in throw HarnessFailure.unexpectedWork })
    let ready = nextState(coordinator)
    coordinator.choose(url: URL(fileURLWithPath: "/fixture/Meeting.m4a"))
    try await awaitSignal(ready)
    try #require(coordinator.state == .ready(fileName: "Meeting.m4a", seconds: 60))
    coordinator.start()
    let refused = nextState(coordinator)
    try await awaitSignal(refused)
    try #require(coordinator.state == .rejected(.engineNotInstalled))
    try #require(coordinator.step == .review, "render the actual refusal destination")
    return coordinator
  }

  private enum HarnessFailure: Error { case unexpectedWork }

  /// Entire Transcribe a File page, with the real coordinator placed through
  /// its public choose/start path. Every provider environment home is present.
  private static func importPage(_ coordinator: FileImportCoordinator) throws -> AnyView {
    let defaults = try #require(TestDefaults.suite("ew.settingsAdvisory.\(UUID().uuidString)"))
    let settings = SettingsManager(defaults: defaults)
    settings.llmProvider = .none
    settings.fileImportLLMProvider = LLMProvider.none
    let keys = KeychainManager(
      backend: .legacyFiles,
      legacyStore: FileLegacyKeyStore(storageDirectory: runDirectory.appending(path: "fixture-keys")))
    let setup = SetupCoordinator(
      asrManager: RouterTestASRManager(),
      whisperKitSetup: WhisperKitSetupService(engineMutationScope: .alwaysAllowedForTesting),
      preloadAction: {}, ollamaStatusProbe: { _ in })
    let egOne = EGOneRuntime(
      manifest: nil, serverBinaryURL: nil, delivery: nil, defaults: defaults)
    let s1 = EGOneRuntime(
      manifest: nil, serverBinaryURL: nil, delivery: nil, defaults: defaults, provider: .s1Mini)
    return AnyView(TranscribeFileView()
      .environment(coordinator).environment(settings).environment(setup)
      .environment(AIAvailabilityCoordinator())
      .environment(LLMModelDiscoveryCoordinator(keychainManager: keys, cacheDefaults: defaults))
      .environment(egOne).environment(LocalPolishRuntimeSet(egOne: egOne, s1Mini: s1))
      .environment(\.keychainManager, keys))
  }

  private static func previewPage() async throws -> AnyView {
    let defaults = try #require(TestDefaults.suite("ew.settingsAdvisoryPreview.\(UUID().uuidString)"))
    let settings = SettingsManager(defaults: defaults)
    settings.livePreviewEnabled = true
    settings.livePreviewEngine = .apple
    settings.languageMode = .locked("en")
    let catalog = ApplePackCatalog(
      dependencies: .init(supportedTags: { ["en-US", "de-DE"] },
        installedTags: { ["en-US"] }, install: { _ in throw HarnessFailure.unexpectedWork }),
      claims: LocaleClaims(inventory: LocaleInventory(
        reserved: { [] }, reserve: { _ in throw HarnessFailure.unexpectedWork },
        release: { _ in false }, maximumReserved: { 5 })))
    let packs = LivePreviewPacksModel(catalog: catalog, resolveActive: { _ in
      .ready(tag: "en-US", name: "English")
    })
    packs.useMode { .locked("en") }
    await packs.load()
    return AnyView(LivePreviewSettingsView(packs: packs).environment(settings))
  }

  /// Caches actual production paint from an offscreen window. Page height is
  /// a 900pt review viewport, not a claim about the real app's window height.
  private static func render(
    _ label: String, width: CGFloat, height: CGFloat? = nil, dark: Bool, content: AnyView
  ) throws -> CGSize {
    let proposal = content.frame(width: width)
      .environment(\.colorScheme, dark ? .dark : .light)
    let host = NSHostingView(rootView: AnyView(proposal))
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let ideal = host.fittingSize
    let size = CGSize(width: width, height: height ?? ideal.height)
    try #require(size.width > 0 && size.height > 0 && size.height.isFinite)
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = host.appearance
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    let png = try #require(rep.representation(using: .png, properties: [:]))
    try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
    let url = runDirectory.appending(path: "\(label)-\(dark ? "dark" : "light").png")
    try #require(FileManager.default.fileExists(atPath: url.path) == false)
    try png.write(to: url)
    let decoded = try #require(NSBitmapImageRep(data: try Data(contentsOf: url)))
    #expect(decoded.pixelsWide > 0 && decoded.pixelsHigh > 0)
    print("RENDERED \(label) \(dark ? "dark" : "light"): frame=\(size) ideal=\(ideal) pixels=\(decoded.pixelsWide)x\(decoded.pixelsHigh) -> \(url.path)")
    window.contentView = nil
    return size
  }

  @Test("Render full refusal and Preview pages plus the actual 360pt advisory pill",
    .enabled(if: ProcessInfo.processInfo.environment["EW_RENDER_SETTINGS_ADVISORY"] == "1"))
  func productionPresentations() async throws {
    let coordinator = try await Self.rejectedImport()
    let importPage = try Self.importPage(coordinator)
    let previewPage = try await Self.previewPage()
    for windowWidth: CGFloat in [750, 820, 1300] {
      let pageWidth = AppearanceRenderHarness.pageWidth(window: windowWidth)
      for dark in [false, true] {
        _ = try Self.render("file-refusal-window-\(Int(windowWidth))",
          width: pageWidth, height: 900, dark: dark, content: importPage)
        _ = try Self.render("live-preview-window-\(Int(windowWidth))",
          width: pageWidth, height: 900, dark: dark, content: previewPage)
      }
    }
    for deviceName: String? in [nil, "Scarlett 2i2 USB", "Scarlett 18i20 USB Audio Interface"] {
      let hint = deviceName.map { MultiInputAdvisoryHint(deviceName: $0) }
      let definition = try #require(PillCatalog.entry(
        for: .advisory(reason: .zeroSignal, hint: hint), id: PresentationID()).definition)
      try #require(definition.requestedWidth == .fixed(360))
      try #require(definition.reservesFixedHeight == nil)
      let model = OverlayRenderModel()
      model.publish(definition)
      let root = AnyView(OverlayRootView(model: model, sendEvent: { _ in }))
      for dark in [false, true] {
        let label = deviceName == nil ? "advisory-plain" :
          (deviceName == "Scarlett 2i2 USB" ? "advisory-hinted" : "advisory-long-device")
        let size = try Self.render(label, width: 360, dark: dark, content: root)
        #expect(size.width == 360)
      }
    }
    print("RENDER MATRIX: 12 full-page PNGs + 6 catalog-routed pill PNGs at \(Self.runDirectory.path)")
  }
}
