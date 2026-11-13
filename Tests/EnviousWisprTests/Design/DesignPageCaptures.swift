import AppKit
import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import SwiftUI
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit
@testable import EnviousWisprPipeline
@testable import EnviousWisprServices
@testable import EnviousWisprStorage

/// The full reference set for `DesignRenderHarness` (#4506 Phase 2, founder decision "full page
/// photos move to the first rebuild PR"): every Settings page and tab the app shows, photographed
/// top to bottom through the page's own scroll view, and the recording pill designs. Taken on unchanged product code before any part is rebuilt, so the rebuild has
/// reference pictures and a 0-pixel before/after over all of them.
///
/// Pages are built by `SettingsMapRenderingTests`, which already hosts every page in every state
/// with isolated stores (no Keychain, Application Support, model server or network); its
/// `captureHook` hands the ready page to this file at the harness's size and appearance. Nothing
/// here builds a second page fixture.
///
/// Scrolled captures: a page is hosted in a fixed `viewport` (the same height for every page, a
/// reference height, not a claim about any window), then its main scroll view is moved down one
/// viewport at a time, the last step clamped to the bottom. The manifest declares how many
/// positions each page has; the harness fails when the page needs a different number, so a page
/// that grows a section cannot fall out of the set unnoticed.
///
/// Not staged, with the reason (listed so nothing is silently skipped):
/// - History: its only rebuilt parts are the action buttons on the meeting page
///   (`HistoryMeetingAfterView`), which shows only with a saved meeting selected. Staging that needs
///   a meeting record plus the page's services (polish setup monitor, navigation, runtime, backend
///   metadata, history paste, previous-app tracker, window coordinator, meeting start flow, among
///   others); no test assembles them today, and building that fixture is outside this change.
///   Those buttons are NOT VERIFIED: the #4531 Live UAT could not select a meeting row through
///   accessibility, so they still need a live check.
/// - Onboarding: being rebuilt with more steps in a separate change (founder 2026-11-11), and its
///   rainbow mark animates, so its pictures are not repeatable; it is photographed after that
///   rebuild lands.
///
/// The EnviousMeet pages show `MeetingRainbowLogo`, whose sound waves animate on a clock
/// (`symbolEffect`), so two runs differ there (a 17x30 pixel box at the pinned heading). Every
/// page renders with `holdsAnimatedMarksStill` set (founder 2026-11-11), which draws the logo's
/// still Reduce Motion picture. No test-side setting could still it without that switch: Reduce
/// Motion is read-only to a view tree and `symbolEffectsRemoved` removes inherited effects only.
@MainActor
enum DesignPageCaptures {

  /// The reference viewport height of the page area, in points.
  static let viewport: CGFloat = 560

  /// The Settings page states photographed, by their `SettingsMapRenderingTests` label: every
  /// page and tab at rest, plus the AI Polish states whose setup shows buttons. App Settings is
  /// here too: the retained Appearance-harness captures use fixed 650/850pt hosts and never scroll.
  static let pageLabels: [String] =
    DictationTab.allCases.map { "dictation.\($0.rawValue)" } + [
      "aiPolish.off", "aiPolish.egOne", "aiPolish.openAI.savedKey",
      "dictionary.yourWords.withWords", "dictionary.vocabularyPacks", "dictionary.learnFrom",
      "dictionary.quickAdd",
      "snippets", "keybinds", "transcribeFile",
    ] + MeetingsTab.allCases.map { "meetings.\($0.rawValue)" }
    + AppSettingsTab.allCases.map { "appSettings.\($0.rawValue)" } + ["diagnostics"]

  // MARK: - Pages

  /// The page's own scroll view: the largest one in the host.
  static func pageScrollView(in view: NSView) -> NSScrollView? {
    var best: NSScrollView?
    func walk(_ node: NSView) {
      if let scroll = node as? NSScrollView,
        scroll.frame.width * scroll.frame.height
          > (best.map { $0.frame.width * $0.frame.height } ?? 0)
      {
        best = scroll
      }
      node.subviews.forEach(walk)
    }
    walk(view)
    return best
  }

  static func settle(_ host: NSView, _ window: NSWindow) {
    // Bounded: a few run-loop turns let SwiftUI answer the scroll change; no clock.
    for _ in 0..<5 { RunLoop.main.run(mode: .default, before: Date()) }
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
  }

  /// Photograph one page state at one width and appearance, one PNG per declared scroll position.
  static func capturePage(
    label: String, width: CGFloat, dark: Bool, names: [String], into directory: URL,
    viewport: CGFloat = DesignPageCaptures.viewport, offsets: ((CGFloat) -> Void)? = nil
  ) async throws -> [DesignRenderHarness.Capture] {
    var made: [DesignRenderHarness.Capture] = []
    let size = CGSize(width: width, height: viewport)
    let hook = SettingsMapRenderingTests.CaptureHook(
      size: size,
      appearance: NSAppearance(named: dark ? .darkAqua : .aqua)!,
      wrap: { view in
        AnyView(
          view.environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.holdsAnimatedMarksStill, true)
            .transaction { $0.disablesAnimations = true })
      },
      capture: { host, window in
        settle(host, window)
        try #require(host.bounds.size == size, "\(label): host is \(host.bounds.size), not \(size)")
        let scroll = pageScrollView(in: host)
        @MainActor func maxOffset() -> CGFloat {
          guard let scroll, let document = scroll.documentView else { return 0 }
          return max(0, document.frame.height - scroll.contentView.bounds.height)
        }
        /// Scroll to `offset` points below the top of the page and let it draw there.
        @MainActor func scrollTo(_ offset: CGFloat) throws {
          guard let scroll, let document = scroll.documentView else { return }
          let y = document.isFlipped ? offset : maxOffset() - offset
          scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
          scroll.reflectScrolledClipView(scroll.contentView)
          // Some pages answer a scroll with a layout change a few turns later (the Dictionary
          // pane decides whether its list header pins). Wait until the page length and position
          // read the same twice in a row; bounded, and a page that never settles fails below.
          var last = (document.frame.height, scroll.contentView.bounds.origin.y)
          var settled = false
          for _ in 0..<20 {
            settle(host, window)
            let now = (document.frame.height, scroll.contentView.bounds.origin.y)
            if now == last {
              settled = true
              break
            }
            last = now
          }
          if !settled { throw DesignRenderHarness.RenderError("\(label): the page did not settle") }
        }
        /// How far below the top the page is scrolled now.
        @MainActor func currentOffset() -> CGFloat {
          guard let scroll, let document = scroll.documentView else { return 0 }
          let y = scroll.contentView.bounds.origin.y
          return document.isFlipped ? y : maxOffset() - y
        }
        // A lazy list builds rows only near the screen, so its page can read longer at the bottom
        // than at the top. "The bottom" is where scrolling to the end stops moving (bounded); the
        // count uses the length read there, and the last capture is always taken there.
        @MainActor func scrollToBottom() throws -> CGFloat {
          var length = maxOffset()
          for _ in 0..<10 {
            try scrollTo(maxOffset())
            if maxOffset() == length && abs(currentOffset() - length) < 0.5 { return length }
            length = maxOffset()
          }
          throw DesignRenderHarness.RenderError("\(label): the page kept growing as it scrolled")
        }
        let length = try scrollToBottom()
        try scrollTo(0)
        let step = scroll?.contentView.bounds.height ?? viewport
        let needed = length <= 0.5 ? 1 : Int((length / step).rounded(.up)) + 1
        // Reported, not thrown, so one run lists every page whose length changed.
        guard needed == names.count else {
          print("SCROLL-POSITIONS \(label) \(Int(width)) needs=\(needed) declared=\(names.count)")
          Issue.record(
            "\(label) at \(Int(width)): the manifest declares \(names.count) scroll positions, the page needs \(needed)"
          )
          return
        }
        for (index, name) in names.enumerated() {
          if scroll != nil && index == names.count - 1 && index > 0 {
            _ = try scrollToBottom()
          } else if scroll != nil {
            let offset = CGFloat(index) * step
            try scrollTo(offset)
            try #require(
              abs(currentOffset() - offset) < 0.5,
              "\(name): the page did not scroll to \(offset) (at \(currentOffset()))")
          }
          // The screen atlas (#4506) joins a page's captures into one picture at these offsets.
          offsets?(currentOffset())
          made.append(
            try DesignRenderHarness.writePNG(of: host, size: size, name: name, into: directory))
        }
      })
    _ = try await SettingsMapRenderingTests.$captureHook.withValue(hook) {
      // Diagnostics is not one of that suite's states; it is hosted here through the same
      // `registrations` host so it gets the same size, appearance and ready handling.
      label == "diagnostics"
        ? try await SettingsMapRenderingTests.registrations(try diagnostics())
        : try await SettingsMapRenderingTests.render(label).list
    }
    #expect(made.count == names.count, "\(label): captured \(made.count) of \(names.count)")
    return made
  }

  // MARK: - Diagnostics

  /// The DEBUG Diagnostics page with idle doubles (existing fixtures: an `ActiveEngineOperation`
  /// built from closures as `RecoverySpoolReplayerTests` builds one, the idle runtime pieces of
  /// `DictationSettingsRenderHarness`, `RecordingDesktopPresentationEffects` for the window
  /// coordinator). Its engine is read only inside its benchmark buttons, which a render never
  /// presses; nothing loads, records or benchmarks.
  static func diagnostics() throws -> AnyView {
    #if DEBUG
    let defaults = try #require(TestDefaults.suite("ew.designDiagnostics.\(UUID().uuidString)"))
    let settings = SettingsManager(defaults: defaults)
    let audio = RouterTestAudioCapture()
    let asr = RouterTestASRManager()
    let store = TranscriptStore(
      directory: TestTemporaryDirectory.url.appending(path: "ew-design-diagnostics-\(UUID())"))
    let recording = LiveRecordingState(
      kernelDriver: DictationRuntimeFixtures.makeParakeetDriver(
        audioCapture: audio, asrManager: asr, store: store),
      whisperKernelDriver: DictationRuntimeFixtures.makeWhisperPipeline(
        audioCapture: audio, store: store), audioCapture: audio, asrManager: asr)
    let engine = ActiveEngineOperation(
      isLoaded: { false }, load: {}, transcribe: { _, _, _ in throw CancellationError() },
      hardCancel: {})
    let diagnostics = DiagnosticsCoordinator(
      benchmark: BenchmarkSuite(
        engineMutationScope: .alwaysAllowedForTesting, isEngineSwitching: { false }))
    let windows = AppWindowCoordinator(
      application: RecordingDesktopPresentationEffects(), showInDock: { true },
      canOpenOnboarding: { false }, isOnboardingComplete: { true })
    return AnyView(
      DiagnosticsSettingsView()
        .environment(settings).environment(diagnostics).environment(recording)
        .environment(windows).environment(AIAvailabilityCoordinator())
        .environment(\.asrManager, asr).environment(\.activeEngine, engine)
        // The page's two preview sections, with presenters that show nothing.
        .environment(
          PillPreviewController(
            presenter: DictationSettingsRenderHarness.NoOverlay(), isPipelineBusy: { false },
            overlayIsEmpty: { true })
        )
        .environment(
          CallPopupPreviewController(
            presenter: CallPopupPreviewTests.FakePanel(), realPopupIsShowing: { false },
            usesTimer: false)))
    #else
      throw DesignRenderHarness.RenderError("Diagnostics exists only in Debug builds")
    #endif
  }

  // MARK: - Recording pill designs

  /// A recording pill leaf as the overlay draws it, with constant level and elapsed time.
  /// The screen atlas (#4506) also photographs it with words (`preview`) and with the in-pill
  /// notice (`noticeText`); the defaults draw exactly what the Phase 2 captures drew.
  static func pill(
    _ design: RecordingPillDesign, locked: Bool, preview: LivePreviewDisplay = .off,
    noticeText: String? = nil
  ) -> AnyView {
    AnyView(
      RecordingOverlayView(
        audioLevelProvider: { 0.4 },
        recordingElapsedProvider: { 127 },
        livePreviewProvider: { preview },
        onContentHeightChange: { _ in },
        chrome: design.chrome,
        isLocked: locked,
        noticeText: noticeText,
        initialPreview: preview
      ).frame(width: design.width))
  }

  /// The words the atlas's with-words pills show.
  static let atlasWords =
    "Let's move the design review to Thursday afternoon and invite the whole team."

  // MARK: - Pill notices (screen atlas, #4506)

  /// Every distinct notice look the overlay draws, built from the app's own catalog so size and
  /// wording are what users see (`PillCatalog`, the sole authority on what a pill is). Other
  /// reasons reuse one of these looks with different words.
  static let notices: [(key: String, request: PillCatalogRequest)] = [
    ("processing-transcribing", .processing(phase: .transcribing)),
    ("processing-polishing", .processing(phase: .polishing)),
    ("clipboard-fallback", .clipboardFallback),
    ("accessibility-toast", .accessibilityToast),
    ("warning-polish-failed", .warning(reason: .polishFailed)),
    ("error-capture", .error(reason: .captureStalled)),
    ("advisory-zero-signal", .advisory(reason: .zeroSignal)),
    ("interruption-device-removed", .interruption(reason: .deviceRemoved)),
    ("caching-model", .cachingModel(engineLabel: "Parakeet")),
    ("engine-ready", .engineReady),
    ("recovering", .recoveringLastRecording),
    ("recovery-succeeded", .recoverySucceeded),
    ("bluetooth", .bluetoothAwareness),
    (
      "escape-recovery",
      .escapeRecovery(transcriptID: UUID(uuidString: "4506A71A-0000-0000-0000-000000000001")!)
    ),
    (
      "import-status",
      .importStatus(message: "Importing your words now. Check progress on the Dictionary page.")
    ),
    (
      "correction-learned",
      .correctionLearned(
        LearnedCorrectionPillModel(
          id: UUID(uuidString: "4506A71A-0000-0000-0000-000000000002")!,
          wordID: UUID(uuidString: "4506A71A-0000-0000-0000-000000000003")!,
          canonical: "Tuist", kind: .added, phase: .learned))
    ),
    (
      "language-chip",
      .passiveChip(
        payload: LanguageChipPayload(
          lang: "es", displayName: "Spanish", state: .askToLock, generation: 1))
    ),
    (
      "correction-save-error",
      .correctionLearnedSaveError(
        LearnedCorrectionSaveError(canonical: "Tuist", reason: .vocabularyWriteFailed))
    ),
    ("polish-setup-card", .polishSetupCard(PolishSetupCardModel(problem: .cloudNoModel(.claude)))),
    (
      "parakeet-upgrade",
      .parakeetUpgrade(ParakeetUpgradePillModel(phase: .downloading(fraction: 0.4)))
    ),
  ]

  /// Which atlas picture shows each kind of pill, so a new `PillCatalogRequest` case does not
  /// build until someone decides how the atlas shows it (#4506). Add its fixture to `notices`
  /// (and to `render-manifest.json` and `design/atlas/atlas.json`), or return nil with the reason.
  static func atlasPicture(for request: PillCatalogRequest) -> String? {
    switch request {
    case .recording: nil  // the pill-<design>-<state> pictures
    case .hidden: nil  // draws nothing
    case .processing(let phase):
      switch phase {
      // The 60-minute case draws the same look with longer words.
      case .transcribing, .transcribingMaxDurationReached: "processing-transcribing"
      case .polishing: "processing-polishing"
      }
    case .clipboardFallback: "clipboard-fallback"
    case .accessibilityToast: "accessibility-toast"
    case .warning: "warning-polish-failed"
    case .error: "error-capture"
    case .advisory: "advisory-zero-signal"
    case .interruption: "interruption-device-removed"
    case .passiveChip: "language-chip"
    case .cachingModel: "caching-model"
    case .engineReady: "engine-ready"
    case .recoveringLastRecording: "recovering"
    case .recoverySucceeded: "recovery-succeeded"
    case .bluetoothAwareness: "bluetooth"
    case .escapeRecovery: "escape-recovery"
    case .importStatus: "import-status"
    case .correctionLearned: "correction-learned"
    case .correctionLearnedSaveError: "correction-save-error"
    case .polishSetupCard: "polish-setup-card"
    case .parakeetUpgrade: "parakeet-upgrade"
    }
  }

  /// One notice as the overlay root draws it, proposed the width production proposes
  /// (`RenderedPillHarness.rootSize(for:)` repeats the same rule).
  static func notice(_ key: String) throws -> AnyView {
    let request = try #require(
      notices.first { $0.key == key }?.request, "unknown notice fixture \(key)")
    let definition = PillCatalog.entry(
      for: request, id: PresentationID(rawValue: UUID())
    ).definition
    let model = OverlayRenderModel()
    model.publish(definition)
    // The interruption pill pulses on a clock (red lips and edge glow), so two runs differ; it is
    // photographed in its Reduce Motion picture (same red look, steady), as `holdsAnimatedMarksStill`
    // stills the EnviousMeet mark. Every other notice is already still.
    let root = OverlayRootView(model: model, sendEvent: { _ in })
      .environment(\.overlayReduceMotionOverride, key.hasPrefix("interruption-") ? true : nil)
    if let definition, case .fixed(let width) = definition.requestedWidth, width > 0 {
      if let height = definition.reservesFixedHeight {
        return AnyView(root.frame(width: width, height: height))
      }
      return AnyView(root.frame(width: width))
    }
    // A measured width stays unproposed: production sizes the panel to `fittingSize`
    // (`OverlayWindowHost`), and so does the capture.
    return AnyView(root)
  }

  // MARK: - Logos (screen atlas, #4506)

  /// The brand marks as the app draws them, at a fixed size, still.
  static func logo(_ key: String) throws -> AnyView {
    switch key {
    case "lips": return AnyView(RainbowLipsIcon(size: 64, audioLevel: 0))
    case "lips-open": return AnyView(RainbowLipsIcon(size: 64, audioLevel: 0.4))
    case "logo-mark": return AnyView(WisprLogoMark().frame(width: 64, height: 64))
    case "envious-meet":
      return AnyView(
        MeetingRainbowLogo(size: 48).environment(\.holdsAnimatedMarksStill, true).padding(4))
    case "menu-bar-idle", "menu-bar-recording":
      let animator = MenuBarIconAnimator()
      let button = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
      animator.configure(button: button)
      if key == "menu-bar-recording" { animator.transition(to: .recording) }
      let image = try #require(button.image, "\(key): the animator set no image")
      // The idle lips are a template image: the menu bar tints them, so the capture does too.
      return AnyView(
        Image(nsImage: image).renderingMode(key == "menu-bar-idle" ? .template : .original)
          .foregroundStyle(Color.primary).frame(width: 22, height: 22))
    default:
      throw DesignRenderHarness.RenderError("unknown logo fixture \(key)")
    }
  }
}
