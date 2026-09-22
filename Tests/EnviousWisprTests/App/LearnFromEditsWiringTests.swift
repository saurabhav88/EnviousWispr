import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import EnviousWisprPostProcessing
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// The ask-first ledger's files are removed once at launch (2026-09-21 plan
/// §3.1 step 12), by name, and a failure never stops the feature composing.
@MainActor
@Suite("Learn from edits: legacy ledger cleanup at launch (#996 auto-learn)", .tags(.productOutcome))
struct LearnFromEditsWiringTests {

  /// Retains what the wiring holds weakly (settings, the words coordinator,
  /// the packs), as the bootstrapper does.
  struct Fixture {
    let wiring: LearnFromEditsWiring
    let settings: SettingsManager
    let packs: VocabularyPackManager
    let customWords: CustomWordsCoordinator
    let registry: PasteCompletionRegistry
    let observer: ObserverFake
    let telemetry: LearnTelemetrySpy
  }

  /// Composes the real wiring over fakes; `cleanup` is the seam under test.
  private func compose(dir: URL, cleanup: LegacyProposalLedgerCleanup) -> Fixture {
    let name = "ew.learn.wiring.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    let settings = SettingsManager(defaults: defaults)
    let customWords = CustomWordsCoordinator(
      manager: CustomWordsManager(fileURL: dir.appendingPathComponent("custom-words.json")))
    let packs = VocabularyPackManager(defaults: defaults)
    let overlay = OverlayDirector(
      host: WindowlessOverlayHost(),
      scheduler: .manual { _ in },
      announce: { _ in },
      livePreview: .disabled,
      grantAccessibility: {}, openMicrophoneSettings: {}, advisoryHint: { _ in nil },
      selections: { .shipped },
      firstRenderSchedule: { $0() })
    let registry = PasteCompletionRegistry()
    let observer = ObserverFake()
    let telemetry = LearnTelemetrySpy()
    let wiring = LearnFromEditsWiring(
      settings: settings, customWords: customWords, packs: packs, overlay: overlay,
      pasteCompletionRegistry: registry, telemetry: telemetry,
      legacyLedgerDirectory: dir, legacyCleanup: cleanup, osMajor: 27,
      observer: observer, scheduler: ObserverClock(),
      frontmost: { FrontmostApplication(pid: 42, bundleID: "com.apple.Notes") },
      selectJudgeForTests: nil, debugExportPath: nil)
    return Fixture(
      wiring: wiring, settings: settings, packs: packs, customWords: customWords,
      registry: registry, observer: observer, telemetry: telemetry)
  }

  private func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-learn-wiring-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  @Test("the live cleanup removes the primary ledger and every archived sibling by name, leaves unrelated files, and a second launch finds nothing to do")
  func liveCleanupRemovesByName() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let fm = FileManager.default
    let primary = dir.appendingPathComponent("correction-proposals.json")
    let archiveA = dir.appendingPathComponent("correction-proposals.untrusted-2026-09-21T01.json")
    let archiveB = dir.appendingPathComponent("correction-proposals.untrusted-2026-09-21T02.json")
    let unrelated = dir.appendingPathComponent("notes.json")
    let lookalike = dir.appendingPathComponent("correction-proposals.untrusted-notes.txt")
    for url in [primary, archiveA, archiveB, unrelated, lookalike] {
      try Data("{}".utf8).write(to: url)
    }
    var logs: [String] = []
    let cleanup = LegacyProposalLedgerCleanup(
      remove: LegacyProposalLedgerCleanup.live.remove, log: { logs.append($0) })

    let f = compose(dir: dir, cleanup: cleanup)
    #expect(!fm.fileExists(atPath: primary.path) && !fm.fileExists(atPath: archiveA.path))
    #expect(!fm.fileExists(atPath: archiveB.path))
    #expect(fm.fileExists(atPath: unrelated.path), "an unrelated file is never touched")
    #expect(fm.fileExists(atPath: lookalike.path), "only .json archives with the prefix")
    #expect(logs == ["learn_legacy_ledger_removed files=3"])
    #expect(f.wiring.coordinator.undoRecord == nil, "the feature composed")

    // A second launch: nothing to remove, nothing logged, nothing recreated.
    logs = []
    _ = compose(dir: dir, cleanup: cleanup)
    #expect(logs.isEmpty)
    #expect(!fm.fileExists(atPath: primary.path))
    #expect(try fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("correction-proposals") } == ["correction-proposals.untrusted-notes.txt"])
  }

  @Test("a cleanup that throws is logged once and blocks nothing: the coordinator, presenter, observer and watcher are composed and a paste still reaches the watcher")
  func failureIsLoggedAndNeverBlocks() async {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    var logs: [String] = []
    var calls = 0
    let cleanup = LegacyProposalLedgerCleanup(
      remove: { _ in
        calls += 1
        throw CocoaError(.fileWriteNoPermission)
      },
      log: { logs.append($0) })
    let f = compose(dir: dir, cleanup: cleanup)
    #expect(calls == 1 && logs == ["learn_legacy_ledger_removal_failed"])
    #expect(f.wiring.selection == .unavailable(.noQualifiedArm))
    f.registry.emit(
      PasteCompletionEvent(pastedText: "Ask sarah today", destinationBundleID: "com.apple.Notes", language: "en"))
    let reached = await waitUntil { f.telemetry.events.contains(.skipped(.modelUnavailable)) }
    #expect(reached, "the watcher is subscribed and answering: \(f.telemetry.events)")
  }

  @Test("the cleanup runs exactly once per composition, after the words coordinator exists")
  func runsOncePerComposition() {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    var seen: [URL] = []
    let cleanup = LegacyProposalLedgerCleanup(
      remove: { url in
        seen.append(url)
        return 0
      }, log: { _ in })
    let f = compose(dir: dir, cleanup: cleanup)
    #expect(seen == [dir])
    #expect(f.customWords.customWords.isEmpty == false, "the words coordinator has loaded its built-ins")
    f.wiring.recordingStarted()
    f.wiring.onboardingDidComplete()
    #expect(seen.count == 1, "no later event re-runs it")
  }

  @Test("the cleanup never reads or decodes what it removes: a file of garbage bytes is removed the same as a real ledger")
  func removesWithoutReading() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let primary = dir.appendingPathComponent("correction-proposals.json")
    try Data([0xFF, 0x00, 0x13]).write(to: primary)
    #expect(try LegacyProposalLedgerCleanup.live.remove(dir) == 1)
    #expect(!FileManager.default.fileExists(atPath: primary.path))
    #expect(try LegacyProposalLedgerCleanup.live.remove(dir) == 0, "absence is success")
  }
}
