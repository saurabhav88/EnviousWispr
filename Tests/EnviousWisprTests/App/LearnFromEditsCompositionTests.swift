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
      legacyLedgerDirectory: dir, osMajor: osMajor,
      observer: observer, scheduler: clock,
      frontmost: frontmost,
      selectJudgeForTests: selectJudgeForTests,
      debugExportPath: debugExportPath)
    return Fixture(
      settings: settings, customWords: customWords, packs: packs, overlay: overlay,
      registry: registry, observer: observer, clock: clock, judge: judge, telemetry: telemetry,
      wiring: wiring, dir: dir)
  }

  /// A delivered paste; `edits` stands in for its arrival session, which answers #996's capture
  /// request (#3106 PR A).
  private func paste(_ edits: EditCaptureFake? = nil) -> PasteCompletionEvent {
    PasteCompletionEvent(
      pastedText: "Ask sarah today", destinationBundleID: "com.apple.Notes", language: "en",
      editCapture: edits)
  }

  @Test("production selects no judge on every macOS major (the qualification table is empty), and the Settings row is disabled with its reason")
  func productionSelectsNothing() {
    for major in [14, 15, 26, 27] {
      let f = fixture(osMajor: major)
      #expect(f.wiring.selection == .unavailable(.noQualifiedArm), "macOS \(major)")
      #expect(f.wiring.selectJudge() == nil, "macOS \(major): model_unavailable")
      #expect(f.wiring.availability.presentation == .unwired, "macOS \(major)")
      #expect(f.wiring.availability.presentation.secondaryLine == "Not available on this version of macOS yet")
      #if DEBUG
        #expect(f.wiring.debugDoor == nil && f.wiring.debugOverride == nil, "no env var, no door")
      #endif
    }
  }

  @Test("the graph is retained and wired: a paste with no judge is counted as model_unavailable, and a judged fix is saved at once and offered with Undo")
  func graphIsWired() async throws {
    let f = fixture(judgeServes: true)
    #expect(f.wiring.coordinator.undoRecord == nil)
    // The registry holds the watcher weakly; the wiring is what keeps it alive.
    #expect(f.settings.learnFromEdits, "on by default")
    let edits = EditCaptureFake()
    edits.outcomes = [
      .captured(ObserverFake.target(pasted: "Ask sarah today", pastedAtMs: 0))
    ]
    f.registry.emit(paste(edits))
    #expect(await waitUntil { f.observer.starts == 1 }, "a paste through the registry started a watch")
    f.observer.fire(.settled(region: "Ask Saira today"))
    #expect(await waitUntil { f.telemetry.events.contains(.undoShown) }, "\(f.telemetry.events)")
    guard case .correctionLearned(let pill)? = f.overlay.renderModel.state.presentation?.content else {
      Issue.record("the Undo pill did not reach the overlay through the attached presenter")
      return
    }
    #expect(pill.canonical == "Saira" && pill.kind == .updated && pill.phase == .learned)
    let saira = try #require(f.customWords.customWords.first { $0.canonical == "Saira" })
    #expect(saira.aliases == ["sarah"] && saira.learnedAliases == ["sarah"], "durably saved and marked")
    #expect(f.telemetry.events.contains(.added(.existingWord)))
    #expect(f.wiring.coordinator.undoRecord?.pillID == pill.id)
    f.overlay.dismissCurrent(.silent)

    let g = fixture()
    g.registry.emit(paste())
    #expect(await waitUntil { g.telemetry.events.contains(.skipped(.modelUnavailable)) }, "the paste reached the watcher and found no judge: \(g.telemetry.events)")
  }

  @Test("with a serving judge a paste starts a watch; the toggle fan-out cancels it as toggle_off; a recording start finishes the next as next_dictation_started")
  func toggleAndRecordingReachTheWatcher() async {
    let f = fixture(judgeServes: true)
    let edits = EditCaptureFake()
    edits.outcomes = [
      .captured(ObserverFake.target(pasted: "Ask sarah today", pastedAtMs: 0)),
      .captured(ObserverFake.target(pasted: "Ask sarah today", pastedAtMs: 0)),
    ]
    f.registry.emit(paste(edits))
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
    f.registry.emit(paste(edits))
    #expect(await waitUntil { f.observer.starts == 2 })
    f.wiring.recordingStarted()
    // A live watch is finished, not cancelled: the observer reads the box once
    // more and flushes a pending fix before ending (#3090).
    #expect(f.observer.stops == 1 && f.observer.finishes == [.nextDictationStarted])
    #expect(f.telemetry.events.last == .observationEnded(.nextDictationStarted, 0, .native))
  }

  @Test("the Settings environment carries the selection's presentation")
  func settingsEnvironment() {
    let f = fixture()
    struct Probe: View {
      @Environment(LearnFromEditsAvailability.self) var availability: LearnFromEditsAvailability?
      let report: @MainActor (LearnFromEditsSettingsPresentation?) -> Void
      var body: some View {
        Color.clear.onAppear { report(availability?.presentation) }
      }
    }
    final class Seen {
      var presentation: LearnFromEditsSettingsPresentation?
    }
    let seen = Seen()
    let root = Probe { p in seen.presentation = p }
      // Only what the bootstrapper injects now.
      .environment(f.wiring.availability)
    let host = NSHostingView(rootView: AnyView(root.frame(width: 10, height: 10)))
    host.layoutSubtreeIfNeeded()
    _ = host.fittingSize
    #expect(seen.presentation == f.wiring.availability.presentation)
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
