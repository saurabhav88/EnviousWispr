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

  /// #4578 §3.1: an unknown fact is read, never guessed. When this fails, a press in the first
  /// instants after launch is refused as "not downloaded" (or let through) before any read.
  @Test("both facts start unknown and a fresh read settles them; nothing installed reads false")
  func freshReadSettlesUnknown() async throws {
    let f = try makeFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    #expect(f.library.installedSnapshot(.whisper) == nil, "Whisper is still checking")
    #expect(await f.library.freshInstalled(.whisper) == false)
    #expect(f.library.installedSnapshot(.whisper) == false)
    #expect(await f.library.freshInstalled(.parakeet) == false)
    #expect(f.library.installedSnapshot(.parakeet) == false)
    #expect(await f.library.freshInstalledEngines().isEmpty)
  }

  /// Held Parakeet reads, answered by the test in order.
  @MainActor private final class HeldReads {
    private(set) var pending: [CheckedContinuation<Bool, Never>] = []
    var onPark: (() -> Void)?
    func read() async -> Bool {
      await withCheckedContinuation { pending.append($0); onPark?() }
    }
    func answer(_ index: Int, _ value: Bool) { pending[index].resume(returning: value) }
  }

  private func heldLibrary(_ reads: HeldReads) throws -> (SpeechModelLibrary, URL) {
    let (library, _, root) = try heldLibraryAndHome(reads)
    return (library, root)
  }

  private func heldLibraryAndHome(_ reads: HeldReads) throws
    -> (SpeechModelLibrary, ModelDeliveryHome, URL)
  {
    let root = TestTemporaryDirectory.url
      .appendingPathComponent("ew-4578-held-\(UUID().uuidString)", isDirectory: true)
    let home = ModelDeliveryHome(
      engineMutationScope: .alwaysAllowedForTesting,
      manifestBundle: try #require(
        Bundle(url: RepoRoot.url.appendingPathComponent("Sources/EnviousWispr/Resources"))),
      appSupportOverride: root,
      deliveryFlagDefaults: try #require(TestDefaults.suite("ew-4578-held-\(UUID().uuidString)")))
    return (
      SpeechModelLibrary(modelDelivery: home, readParakeetForTesting: { await reads.read() }),
      home, root
    )
  }

  private func parked(_ reads: HeldReads, count: Int) async throws {
    guard reads.pending.count < count else { return }
    let signal = BoundedWait.Signal()
    reads.onPark = { if reads.pending.count >= count { signal.fire() } }
    try await BoundedWait.until(signal)
    reads.onPark = nil
  }

  /// #4578 §3.1 (C2 r1 P1): a reader that joined a read an invalidation then replaced waits for
  /// the replacement. When this fails, a press during a delivery change reads an installed
  /// engine as missing and shows "not downloaded".
  @Test("overlapping readers across an invalidation all get the newest answer, never false")
  func overlappingReadersGetTheNewestAnswer() async throws {
    let reads = HeldReads()
    let (library, root) = try heldLibrary(reads)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = Task { await library.freshInstalled(.parakeet) }
    try await parked(reads, count: 1)
    library.invalidateParakeet()
    try await parked(reads, count: 2)
    let second = Task { await library.freshInstalled(.parakeet) }
    reads.answer(0, false)  // the superseded read: publishes nothing
    #expect(library.installedSnapshot(.parakeet) == nil)
    reads.answer(1, true)
    #expect(await first.value == true)
    #expect(await second.value == true)
    #expect(library.installedSnapshot(.parakeet) == true)
    #expect(reads.pending.count == 2, "joined, never a competing read")
  }

  /// #4578 (C2 r2 P1): an answer belongs to the delivery facts it was read against. When this
  /// fails, a press right after a download or failure acts on the old answer.
  @Test("a delivery change makes the answer unknown in the same turn; a read across one publishes nothing")
  func answersAreBoundToDeliveryFacts() async throws {
    let reads = HeldReads()
    let (library, home, root) = try heldLibraryAndHome(reads)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = Task { await library.freshInstalled(.parakeet) }
    try await parked(reads, count: 1)
    reads.answer(0, true)
    #expect(await first.value == true)
    #expect(library.installedSnapshot(.parakeet) == true)

    home.applyParakeetStateForTesting(.preparing(validatingExistingCache: false))
    #expect(library.installedSnapshot(.parakeet) == nil, "unknown at once, before any task runs")

    // A read that starts now and sees the facts change before it ends publishes nothing; the
    // waiting reader then reads again for the new facts.
    let second = Task { await library.freshInstalled(.parakeet) }
    try await parked(reads, count: 2)
    home.applyParakeetStateForTesting(.notReady)
    reads.answer(1, true)
    try await parked(reads, count: 3)
    #expect(library.installedSnapshot(.parakeet) == nil)
    reads.answer(2, false)
    #expect(await second.value == false)
    #expect(library.installedSnapshot(.parakeet) == false)
  }

  /// #4578: the one call each job's owner makes. When this fails, a job starts on a missing
  /// engine (and loads or downloads it) or refuses an installed one.
  @Test("admits: a job may start only on an installed engine")
  func admitsFollowsTheFacts() async throws {
    for installed in [true, false] {
      let reads = HeldReads()
      let (library, root) = try heldLibrary(reads)
      defer { try? FileManager.default.removeItem(at: root) }
      let decision = Task { await library.admits(.dictation, requested: .parakeet) }
      try await parked(reads, count: 1)
      reads.answer(0, installed)
      #expect(await decision.value == installed)
    }
  }

  // MARK: - #4578 Parakeet Remove

  private func parakeetLibrary() throws -> (SpeechModelLibrary, ParakeetUpgradeCoordinator, URL) {
    let root = TestTemporaryDirectory.url
      .appendingPathComponent("ew-4578-premove-\(UUID().uuidString)", isDirectory: true)
    let home = ModelDeliveryHome(
      engineMutationScope: .alwaysAllowedForTesting,
      manifestBundle: try #require(
        Bundle(url: RepoRoot.url.appendingPathComponent("Sources/EnviousWispr/Resources"))),
      appSupportOverride: root,
      deliveryFlagDefaults: try #require(TestDefaults.suite("ew-4578-pr-\(UUID().uuidString)")))
    let upgrade = home.installParakeetUpgrade(
      parakeetSelection: ParakeetSelectionProvider(), isOnboardingComplete: { true })
    return (SpeechModelLibrary(modelDelivery: home), upgrade, root)
  }

  /// When this fails, Remove deletes Parakeet during a dictation or meeting, or a refused
  /// Remove still records the removal.
  @Test(
    "a refused Parakeet Remove says why and changes nothing",
    arguments: [WhisperRemoveNotice.refusedDictationInFlight, .refusedMeetingActive])
  func parakeetRemoveRefusal(refusal: WhisperRemoveNotice) async throws {
    let (library, upgrade, root) = try parakeetLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    var steps: [String] = []
    library.parakeetRemoval.refusal = { refusal }
    library.parakeetRemoval.unloadForRemoval = { steps.append("unload"); return true }
    #expect(library.removeParakeet() == nil)
    #expect(library.parakeetRemoveNotice == refusal)
    #expect(steps.isEmpty && !library.isRemovingParakeet)
    #expect(upgrade.isInstallWanted)
  }

  /// When this fails, Remove deletes a model still loaded in memory, leaves it to download
  /// again, or changes the engine the person picked.
  @Test("Parakeet Remove records first, unloads before deleting, reopens after; a refused unload deletes nothing and keeps the record")
  func parakeetRemoveOrder() async throws {
    for freed in [true, false] {
      let (library, upgrade, root) = try parakeetLibrary()
      defer { try? FileManager.default.removeItem(at: root) }
      var steps: [String] = []
      library.parakeetRemoval.refusal = { nil }
      library.parakeetRemoval.unloadForRemoval = {
        steps.append("unload:wanted=\(upgrade.isInstallWanted)")
        // No job may start on Parakeet while it is being removed.
        steps.append("snapshot:\(library.installedSnapshot(.parakeet).map { "\($0)" } ?? "nil")")
        return freed
      }
      library.parakeetRemoval.finishRemoval = { steps.append("finish") }
      let task = try #require(library.removeParakeet())
      #expect(library.isRemovingParakeet)
      #expect(library.removeParakeet() == nil, "one Remove at a time")
      #expect(library.installParakeet() == nil, "no Set up model during a Remove")
      await task.value
      #expect(steps == ["unload:wanted=false", "snapshot:false", "finish"])
      #expect(!library.isRemovingParakeet)
      #expect(library.parakeetRemoveNotice == (freed ? nil : .failed))
      #expect(upgrade.isInstallWanted == false, "only Set up model records wanted again")
      #expect(library.parakeetHasLeftovers == false)
    }
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
