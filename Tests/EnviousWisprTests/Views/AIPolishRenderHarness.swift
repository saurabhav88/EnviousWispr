import AppKit
import EnviousWisprCore
import EnviousWisprServices
import SwiftUI
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit
@testable import EnviousWisprLLM

/// Renders the production rail and provider detail with isolated settings and key storage.
/// No ProviderSetupLifecycle is mounted: no key read, probe, download or daemon watch runs.
/// This instrument checks paint, not live clicks, navigation or provider readiness.
/// TEST_RUNNER_EW_RENDER_AI_POLISH=1 scripts/xcode-test.sh --filter EnviousWisprTests/AIPolishRenderHarness
@MainActor
@Suite("AI Polish render harness", .tags(.harnessContract))
struct AIPolishRenderHarness {
  init() { _ = NSApplication.shared }

  static let runDirectory = RepoRoot.sourceURL("build/pr3-polish/renders/run-\(UUID().uuidString)")

  private static func render(_ name: String, width: CGFloat, dark: Bool, content: some View) throws {
    let host = NSHostingView(rootView: AnyView(content.frame(width: width)
      .environment(\.colorScheme, dark ? .dark : .light)))
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let ideal = host.fittingSize
    try #require(ideal.height.isFinite && ideal.height > 0)
    host.frame = NSRect(x: 0, y: 0, width: width, height: ideal.height)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = host.appearance
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
    let url = runDirectory.appending(path: "\(name)-\(dark ? "dark" : "light").png")
    try png.write(to: url)
    let decoded = try #require(NSBitmapImageRep(data: png))
    #expect(decoded.pixelsWide > 0 && decoded.pixelsHigh > 0)
    print("RENDERED AI Polish \(name): \(width)x\(ideal.height) -> \(url.path)")
    window.contentView = nil
  }

  private static func detailPage(provider: LLMProvider, pageWidth: CGFloat) throws -> AnyView {
    let defaults = try #require(TestDefaults.suite("ew.aiPolishRender.\(UUID().uuidString)"))
    let settings = SettingsManager(defaults: defaults)
    settings.llmProvider = provider
    settings.fileImportLLMProvider = provider
    let keys = KeychainManager(backend: .legacyFiles,
      legacyStore: FileLegacyKeyStore(storageDirectory: runDirectory.appending(path: "fixture-keys")))
    let setup = SetupCoordinator(asrManager: RouterTestASRManager(),
      whisperKitSetup: WhisperKitSetupService(engineMutationScope: .alwaysAllowedForTesting),
      preloadAction: {}, ollamaStatusProbe: { _ in })
    let egOne = EGOneRuntime(manifest: nil, serverBinaryURL: nil, delivery: nil, defaults: defaults)
    let s1 = EGOneRuntime(manifest: nil, serverBinaryURL: nil, delivery: nil,
      defaults: defaults, provider: .s1Mini)
    let runtimes = LocalPolishRuntimeSet(egOne: egOne, s1Mini: s1)
    let availability = AIAvailabilityCoordinator()
    let discovery = LLMModelDiscoveryCoordinator(keychainManager: keys, cacheDefaults: defaults)
    let model = ProviderSetupModel()
    // Known absent without reading any store. A draft is never readiness evidence.
    model.openAIKeySaved = false
    model.geminiKeySaved = false
    model.claudeKeySaved = false
    let snapshot = ProviderStatusSnapshot.capture(model: model, egOne: egOne, runtimes: runtimes,
      availability: availability, discovery: discovery, setup: setup)
    return AnyView(VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top, spacing: PolishRailMetrics.columnGap) {
        ProviderRail(selection: .constant(provider), snapshot: snapshot)
          .frame(width: PolishRailMetrics.railWidth)
        ProviderSetupSection(model: model, part: .detail, surface: .dictation)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(.horizontal, SettingsLayout.contentH)
    .padding(.vertical, 16)
    .frame(width: pageWidth)
    .background(Color.stPageBg)
    .environment(settings).environment(setup).environment(egOne).environment(runtimes)
    .environment(availability).environment(discovery).environment(\.keychainManager, keys))
  }

  @Test("Render each provider at 750, 820 and 1300pt, light and dark",
    .enabled(if: ProcessInfo.processInfo.environment["EW_RENDER_AI_POLISH"] == "1"))
  func productionDetails() throws {
    for windowWidth: CGFloat in [750, 820, 1300] {
      let pageWidth = AppearanceRenderHarness.pageWidth(window: windowWidth)
      for entry in PolishRailCatalog.all {
        for dark in [false, true] {
          try Self.render("\(entry.provider.rawValue)-\(Int(windowWidth))", width: pageWidth,
            dark: dark, content: Self.detailPage(provider: entry.provider, pageWidth: pageWidth))
        }
      }
    }
  }
}
