import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation
import Observation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit
@testable import EnviousWisprModelDelivery
import EnviousWisprAppKitTestSupport

/// #4578: the speech-model owner's Whisper Remove, moved from `WhisperDeliveryWiring` unchanged.
/// When this fails, the user sees Remove leave the model on the Mac, download it again at the
/// next launch, or change the engine they picked.
@MainActor
@Suite(.tags(.productOutcome))
struct SpeechModelLibraryTests {
  private struct Fixture {
    let root: URL
    let library: SpeechModelLibrary
    let wired: WhisperDeliveryWiring.Wired
    let settings: SettingsManager
  }

  private func makeFixture(attach: Bool = true) throws -> Fixture {
    let root = TestTemporaryDirectory.url
      .appendingPathComponent("ew-4578-library-\(UUID().uuidString)", isDirectory: true)
    let home = ModelDeliveryHome(
      engineMutationScope: .alwaysAllowedForTesting,
      manifestBundle: try #require(
        Bundle(url: RepoRoot.url.appendingPathComponent("Sources/EnviousWispr/Resources"))),
      appSupportOverride: root,
      deliveryFlagDefaults: try #require(TestDefaults.suite("ew-4578-flags-\(UUID().uuidString)")))
    let settings = SettingsManager(
      defaults: try #require(TestDefaults.suite("ew-4578-settings-\(UUID().uuidString)")))
    settings.selectedBackend = .whisper
    settings.meetingTranscriptEngine = .whisper
    let library = SpeechModelLibrary(modelDelivery: home)
    let wired = WhisperDeliveryWiring.make(
      modelDelivery: home, settings: settings, engineMutationScope: .alwaysAllowedForTesting,
      removeModel: SpeechModelLibrary.whisperRemoveAction(library))
    if attach {
      library.attachWhisper(
        .init(setupService: wired.setupService, migration: wired.migration, removal: wired.removal))
    }
    return Fixture(root: root, library: library, wired: wired, settings: settings)
  }

  @Test("Remove records the decline, unloads before deleting, reopens after, and keeps both picks")
  func removeOrderAndOutcome() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    var steps: [String] = []
    f.wired.removal.unloadForRemoval = {
      steps.append("unload:\(f.wired.migration.state(of: .dictation).map { "\($0)" } ?? "none")")
    }
    f.wired.removal.finishRemoval = { steps.append("finish") }

    let notice = await f.library.removeWhisperModel()

    #expect(notice == nil)
    #expect(steps == ["unload:declined", "finish"])
    #expect(f.wired.migration.state(of: .dictation) == .declined)
    #expect(f.settings.selectedBackend == .whisper)
    #expect(f.settings.meetingTranscriptEngine == .whisper)
  }

  @Test("Remove pressed in Settings ends with no failure notice and keeps both picks")
  func removeThroughSettingsSucceeds() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let service = f.wired.setupService
    service.isDictationInFlight = { false }
    service.isMeetingActive = { false }

    service.removeModel()
    #expect(service.isRemoving)
    // The subject's own signal: `isRemoving` returns to false in the same main-actor turn
    // that publishes the notice.
    let done = BoundedWait.Signal()
    Task { @MainActor in
      while service.isRemoving {
        await withCheckedContinuation { continuation in
          withObservationTracking { _ = service.isRemoving } onChange: { continuation.resume() }
        }
      }
      done.fire()
    }
    try await BoundedWait.until(done)

    #expect(service.removeNotice == nil, "a completed removal must not show a failure")
    #expect(f.wired.migration.state(of: .dictation) == .declined)
    #expect(f.settings.selectedBackend == .whisper)
    #expect(f.settings.meetingTranscriptEngine == .whisper)
  }

  @Test("Remove before the Whisper parts exist fails and touches nothing")
  func removeWithoutPartsFails() async throws {
    let f = try makeFixture(attach: false)
    defer { try? FileManager.default.removeItem(at: f.root) }
    var steps: [String] = []
    f.wired.removal.unloadForRemoval = { steps.append("unload") }
    f.wired.removal.finishRemoval = { steps.append("finish") }

    let notice = await f.library.removeWhisperModel()

    #expect(notice == .failed)
    #expect(steps.isEmpty)
    #expect(f.wired.migration.state(of: .dictation) != .declined)
  }
}
