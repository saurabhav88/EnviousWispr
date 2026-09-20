import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import EnviousWisprPostProcessing
import EnviousWisprServices
import EnviousWisprStorage
import Foundation
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// The composed learn-from-edits runtime (#996 chunk 5h): one holder, built
/// the way `WisprBootstrapper` builds it, with a scripted paste observer in
/// place of the accessibility API. What a paste, a toggle and a recording
/// start do once the pieces are wired; what production selects; what the
/// Settings environment receives.
@MainActor
@Suite("Learn from edits: composition (#996 chunk 5h)", .tags(.productOutcome), .serialized)
struct LearnFromEditsCompositionTests {
  typealias T = TelemetryService.LearnFromEditsTelemetry

  final class Armed {
    var work: OverlayScheduledWork?
  }

  struct Fixture {
    let settings: SettingsManager
    let customWords: CustomWordsCoordinator
    let packs: VocabularyPackManager
    let overlay: OverlayDirector
    let registry: PasteCompletionRegistry
    let observer: ObserverFake
    let clock: ObserverClock
    let judge: JudgeFake
    let telemetry: LearnTelemetrySpy
    let wiring: LearnFromEditsWiring
    let dir: URL
  }

  private func fixture(
    judgeServes: Bool = false, debugExportPath: String? = nil, osMajor: Int = 27
  ) -> Fixture {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-learn-composition-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let name = "ew.learn.composition.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    let settings = SettingsManager(defaults: defaults)
    let customWords = CustomWordsCoordinator(
      manager: CustomWordsManager(fileURL: dir.appendingPathComponent("custom-words.json")))
    _ = customWords.add(CustomWord(canonical: "Saira"))
    let packs = VocabularyPackManager(defaults: defaults)
    let armed = Armed()
    let overlay = OverlayDirector(
      host: WindowlessOverlayHost(),
      scheduler: .manual { armed.work = $0 },
      announce: { _ in },
      livePreview: .disabled,
      grantAccessibility: {}, openMicrophoneSettings: {}, advisoryHint: { _ in nil },
      selections: { .shipped },
      firstRenderSchedule: { $0() })
    let registry = PasteCompletionRegistry()
    let observer = ObserverFake()
    let clock = ObserverClock()
    let judge = JudgeFake()
    let telemetry = LearnTelemetrySpy()
    let frontmost: @MainActor () -> FrontmostApplication? = {
      FrontmostApplication(pid: 42, bundleID: "com.apple.Notes")
    }
    var selectJudgeForTests: (@MainActor () -> SelectedCorrectionJudge?)? = nil
    if judgeServes {
      selectJudgeForTests = { SelectedCorrectionJudge(arm: .rules, judge: judge) }
    }
    let wiring = LearnFromEditsWiring(
      settings: settings, customWords: customWords, packs: packs, overlay: overlay,
      pasteCompletionRegistry: registry, telemetry: telemetry,
      storeDirectory: dir, osMajor: osMajor,
      observer: observer, scheduler: clock,
      frontmost: frontmost,
      selectJudgeForTests: selectJudgeForTests,
      debugExportPath: debugExportPath)
    return Fixture(
      settings: settings, customWords: customWords, packs: packs, overlay: overlay,
      registry: registry, observer: observer, clock: clock, judge: judge, telemetry: telemetry,
      wiring: wiring, dir: dir)
  }

  private func paste() -> PasteCompletionEvent {
    PasteCompletionEvent(pastedText: "Ask sarah today", destinationBundleID: "com.apple.Notes", language: "en")
  }

  @Test("production selects no judge on every macOS major (the qualification table is empty), and the Settings row is disabled with its reason")
  func productionSelectsNothing() {
    for major in [14, 15, 26, 27] {
      let f = fixture(osMajor: major)
      #expect(f.wiring.selection == .unavailable(.noQualifiedArm), "macOS \(major)")
      #expect(f.wiring.selectJudge() == nil, "macOS \(major): model_unavailable")
      #expect(f.wiring.settingsPresentation == .unwired, "macOS \(major)")
      #expect(f.wiring.settingsPresentation.secondaryLine == "Not available on this version of macOS yet")
      #if DEBUG
        #expect(f.wiring.debugDoor == nil && f.wiring.debugOverride == nil, "no env var, no door")
      #endif
    }
  }

  @Test("the graph is retained and wired: the ledger is ready in the app-support directory, the presenter reaches the overlay, and a paste with no judge is counted as model_unavailable")
  func graphIsWired() async {
    let f = fixture()
    #expect(f.wiring.coordinator.ledgerState == .ready)
    #expect(FileManager.default.fileExists(atPath: f.dir.path))
    // The presenter is the coordinator's: a minted proposal reaches the overlay.
    guard
      case .minted(let id) = f.wiring.coordinator.propose(
        original: "sarah", corrected: "Saira",
        state: .existingWord(f.customWords.customWords.first { $0.canonical == "Saira" }!.id),
        language: "en", contextExcerpt: nil, sourceBundleID: "com.apple.Notes", advisorySafeAlias: nil)
    else {
      Issue.record("expected minted")
      return
    }
    guard case .correctionProposal(let model)? = f.overlay.renderModel.state.presentation?.content else {
      Issue.record("the card did not reach the overlay through the attached presenter")
      return
    }
    #expect(model.id == id && f.telemetry.events.contains(.cardShown))
    f.overlay.dismissCurrent(.silent)

    // The registry holds the watcher weakly; the wiring is what keeps it alive.
    #expect(f.settings.learnFromEdits, "on by default")
    f.registry.emit(paste())
    #expect(await waitUntil { f.telemetry.events.contains(.skipped(.modelUnavailable)) }, "the paste reached the watcher and found no judge: \(f.telemetry.events)")
  }

  @Test("with a serving judge a paste starts a watch; the toggle fan-out cancels it as toggle_off; a recording start cancels the next as next_dictation_started")
  func toggleAndRecordingReachTheWatcher() async {
    let f = fixture(judgeServes: true)
    f.observer.captureOutcomes = [
      .captured(ObserverFake.target(pasted: "Ask sarah today", pastedAtMs: 0)),
      .captured(ObserverFake.target(pasted: "Ask sarah today", pastedAtMs: 0)),
    ]
    f.registry.emit(paste())
    #expect(await waitUntil { f.observer.starts == 1 }, "a paste through the registry started a watch")

    f.settings.learnFromEdits = false
    f.wiring.settingChanged(.learnFromEdits, settings: f.settings)
    #expect(f.observer.stops == 1)
    #expect(f.telemetry.events.last == .skipped(.toggleOff))
    // An unrelated key reaches nothing.
    f.wiring.settingChanged(.appearance, settings: f.settings)
    #expect(f.observer.stops == 1)

    f.settings.learnFromEdits = true
    f.wiring.settingChanged(.learnFromEdits, settings: f.settings)
    f.registry.emit(paste())
    #expect(await waitUntil { f.observer.starts == 2 })
    f.wiring.recordingStarted()
    #expect(f.observer.stops == 2)
    #expect(f.telemetry.events.last == .observationEnded(.nextDictationStarted, 0, .native))
  }

  @Test("the Settings environment carries the coordinator, the selection's presentation and the app-name lookup, and the lookup never returns a raw bundle id")
  func settingsEnvironment() {
    let f = fixture()
    // The same three values the bootstrapper injects; read back through a view.
    struct Probe: View {
      @Environment(CorrectionProposalCoordinator.self) var coordinator: CorrectionProposalCoordinator?
      @Environment(\.learnFromEditsPresentation) var presentation
      @Environment(\.pendingSourceAppName) var name
      let report: @MainActor (CorrectionProposalCoordinator?, LearnFromEditsSettingsPresentation, String?) -> Void
      var body: some View {
        Color.clear.onAppear { report(coordinator, presentation, name("com.apple.finder")) }
      }
    }
    final class Seen {
      var coordinator: CorrectionProposalCoordinator?
      var presentation: LearnFromEditsSettingsPresentation?
      var finder: String??
    }
    let seen = Seen()
    let root = Probe { c, p, n in
      seen.coordinator = c
      seen.presentation = p
      seen.finder = n
    }
    .environment(f.wiring.coordinator)
    .environment(\.learnFromEditsPresentation, f.wiring.settingsPresentation)
    .environment(\.pendingSourceAppName, f.wiring.sourceAppName)
    let host = NSHostingView(rootView: AnyView(root.frame(width: 10, height: 10)))
    host.layoutSubtreeIfNeeded()
    _ = host.fittingSize
    #expect(seen.coordinator === f.wiring.coordinator)
    #expect(seen.presentation == f.wiring.settingsPresentation)
    #expect(seen.finder == "Finder")
    #expect(LearnFromEditsWiring.sourceAppName(bundleID: "com.apple.finder") == "Finder")
    #expect(LearnFromEditsWiring.sourceAppName(bundleID: "com.example.no-such-app.\(UUID().uuidString)") == nil)
  }

  #if DEBUG
    @Test("the Debug door: a relative path is rejected, a missing directory fails to load, and neither publishes an override")
    func debugDoorStates() async {
      let relative = fixture(debugExportPath: "relative/export")
      let rejected = try? #require(relative.wiring.debugDoor)
      #expect(rejected?.state == .rejected("not an absolute path"))
      #expect(relative.wiring.selectJudge() == nil)

      let missing = fixture(debugExportPath: "/nonexistent/ew-\(UUID().uuidString)/fp32")
      let door = missing.wiring.debugDoor
      #expect(door != nil && door?.state == .loading)
      #expect(
        await waitUntil(deadlineMs: 5000) {
          if case .failed = door?.state { return true }
          return false
        }, "a missing export directory fails the load: \(String(describing: door?.state))")
      #expect(missing.wiring.selectJudge() == nil && missing.wiring.debugOverride == nil)
    }
  #endif
}
