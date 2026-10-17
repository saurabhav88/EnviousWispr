import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprTranscribeCpp

/// A native driver whose load is the test's closure; decodes return at once.
private struct ScopeDriver: WhisperExecutorDriving {
  typealias Handle = Int
  let loadModel: @Sendable (String) async throws -> Int
  func load(modelPath: String, lane: TranscribeCppExecutor.Lane) async throws -> Int {
    try await loadModel(modelPath)
  }
  func detectLanguage(
    _ handle: Int, samples: [Float], lane: TranscribeCppExecutor.Lane
  ) async throws -> TranscribeCppLanguageObservation {
    TranscribeCppLanguageObservation(code: "en", logProb: -0.01)
  }
  func transcribe(
    _ handle: Int, samples: [Float], language: String?, lane: TranscribeCppExecutor.Lane,
    onInferenceEntered: (@Sendable () -> Void)?, onProgress: (@Sendable (Int64, Int64) -> Void)?
  ) async throws -> TranscribeCppRunResult {
    TranscribeCppRunResult(text: "", detectedLanguage: "en", segments: [])
  }
  func waitForDrain(_ handle: Int) async {}
  func unload(_ handle: Int) async {}
  /// Nothing outlives a call here: the test's load returns its handle and unload frees
  /// nothing, so the heart lane is always settled.
  func awaitSettled(openedOn lane: TranscribeCppExecutor.Lane) async -> Int { 0 }
}

/// Delivered scope snapshots, readable synchronously from any thread (the fake native loader
/// reads it at its first statement). Safe: every access holds `lock`, nothing awaits or calls
/// out while holding it, and waiters are resumed after it is released.
private final class DeliveredScope: @unchecked Sendable {
  private let lock = NSLock()
  private var snapshots: [ASRModelScopeOwner.Snapshot] = []
  private var lastSequence: UInt64 = 0
  private typealias Condition = @Sendable ([ASRModelScopeOwner.Snapshot]) -> Bool
  private var waiters: [(id: UUID, met: Condition, resume: CheckedContinuation<Void, Never>)] = []

  /// Drops a repeat or late delivery by its sequence, as `ASRModelScopeOwner.observe` does.
  func append(_ snapshot: ASRModelScopeOwner.Snapshot, sequence: UInt64? = nil) {
    lock.lock()
    if let sequence {
      guard sequence > lastSequence else {
        lock.unlock()
        return
      }
      lastSequence = sequence
    }
    snapshots.append(snapshot)
    let current = snapshots
    let ready = waiters.filter { $0.met(current) }
    waiters.removeAll { $0.met(current) }
    lock.unlock()
    for waiter in ready { waiter.resume.resume() }
  }

  var all: [ASRModelScopeOwner.Snapshot] {
    lock.lock()
    defer { lock.unlock() }
    return snapshots
  }

  func waitFor(count: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
    await waitUntil(sourceLocation: sourceLocation) { $0.count >= count }
  }

  /// Waits until the delivered snapshots meet `condition` (the subject's own signal); the
  /// deadline only fails a delivery that never comes.
  func waitUntil(
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @escaping @Sendable ([ASRModelScopeOwner.Snapshot]) -> Bool
  ) async {
    let id = UUID()
    let timeout = Task {
      try? await Task.sleep(for: .seconds(5))  // deadline-fallback: bounds the signal wait
      self.release(id, sourceLocation: sourceLocation)
    }
    await withCheckedContinuation { continuation in
      lock.lock()
      if condition(snapshots) {
        lock.unlock()
        continuation.resume()
      } else {
        waiters.append((id, condition, continuation))
        lock.unlock()
      }
    }
    timeout.cancel()
  }

  private func release(_ id: UUID, sourceLocation: SourceLocation) {
    lock.lock()
    let pending = waiters.filter { $0.id == id }
    waiters.removeAll { $0.id == id }
    lock.unlock()
    guard !pending.isEmpty else { return }
    Issue.record("the expected scope delivery never arrived", sourceLocation: sourceLocation)
    for waiter in pending { waiter.resume.resume() }
  }
}

/// A one-shot hold with a bounded wait: the deadline records a failure and releases the
/// waiters; it never stands in for the signal.
private actor Hold {
  private var arrived = false
  private var released = false
  private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
  private var deadlineTask: Task<Void, Never>?
  /// How many held deliveries must arrive before the hold counts as reached: the Whisper
  /// tests need both the queued loading report and the physical-load barrier's own delivery.
  private let arrivalsRequired: Int
  private var arrivalsObserved = 0

  init(arrivalsRequired: Int = 1) {
    precondition(arrivalsRequired > 0)
    self.arrivalsRequired = arrivalsRequired
  }

  func arriveAndWait() async {
    arrivalsObserved += 1
    if arrivalsObserved >= arrivalsRequired {
      arrived = true
      for waiter in arrivalWaiters { waiter.resume() }
      arrivalWaiters.removeAll()
    }
    if released { return }
    armDeadline()
    await withCheckedContinuation { releaseWaiters.append($0) }
  }

  func waitForArrival() async {
    if arrived { return }
    armDeadline()
    await withCheckedContinuation { arrivalWaiters.append($0) }
  }

  func release() {
    released = true
    for waiter in releaseWaiters { waiter.resume() }
    releaseWaiters.removeAll()
    if arrived { deadlineTask?.cancel() }
  }

  private func armDeadline() {
    guard deadlineTask == nil else { return }
    deadlineTask = Task {
      // deadline-fallback: bounds the hold's arrival and release signals
      do { try await Task.sleep(for: .seconds(5)) } catch { return }
      self.failAndRelease()
    }
  }

  private func failAndRelease() {
    guard !arrived || !released else { return }
    Issue.record("hold did not complete")
    arrived = true
    for waiter in arrivalWaiters { waiter.resume() }
    arrivalWaiters.removeAll()
    release()
  }
}

private actor Counter {
  private(set) var value = 0
  func bump() { value += 1 }
}

/// #3546 §3.7 T3: the two physical load owners report the crash-report model tags. When this
/// fails, a crash during an Ultra load names no model, a failed load still reads `loading`,
/// or an unloaded engine still claims to serve its model.
@MainActor
@Suite("ASR model scope producers (#3546)", .tags(.observabilityContract))
struct ASRModelScopeProducerTests {
  static let whisperVariant = "whisper-large-v3-turbo-Q8_0"
  static let whisper = ASRModelIdentity(
    name: "whisper-large-v3-turbo-gguf", revision: "0123456789abcdef", variant: whisperVariant)

  fileprivate static func backend(
    load: @escaping @Sendable (String) async throws -> Int,
    identity: ASRModelIdentity? = whisper, delivered: DeliveredScope,
    hold: Hold? = nil
  ) -> TranscribeCppWhisperBackend<ScopeDriver> {
    TranscribeCppWhisperBackend(
      driver: ScopeDriver(loadModel: load), modelVariant: whisperVariant,
      admittedModelPath: { "/fake/turbo.gguf" }, modelIdentity: identity,
      scopeDelivery: { sequence, snapshot in
        if let hold, snapshot.phase == .loading { await hold.arriveAndWait() }
        delivered.append(snapshot, sequence: sequence)
      },
      authorizeUnload: nil, warmupDeadlineSeconds: 5)
  }

  @Test("a Whisper load reports loading, then loaded and serving; an unload stops serving")
  func whisperLoadAndUnload() async throws {
    let delivered = DeliveredScope()
    let backend = Self.backend(load: { _ in 1 }, delivered: delivered)
    try await backend.prepare()
    await delivered.waitFor(count: 2)
    #expect(delivered.all.map(\.phase) == [.loading, .loaded])
    #expect(delivered.all.first?.requested == Self.whisper)
    #expect(delivered.all.first?.serving == nil)
    #expect(delivered.all.last?.serving == Self.whisper)
    await backend.unload()
    await delivered.waitFor(count: 3)
    #expect(delivered.all.last?.serving == nil, "an unloaded engine serves nothing")
  }

  @Test("a failed Whisper load reports failed and serves nothing")
  func whisperFailure() async throws {
    struct BrokenCache: Error {}
    let delivered = DeliveredScope()
    let backend = Self.backend(load: { _ in throw BrokenCache() }, delivered: delivered)
    await #expect(throws: BrokenCache.self) { try await backend.prepare() }
    await delivered.waitFor(count: 2)
    #expect(delivered.all.map(\.phase) == [.loading, .failed])
    #expect(delivered.all.last?.requested == Self.whisper)
    #expect(delivered.all.last?.serving == nil)
  }

  @Test("a Whisper load that throws a cancellation reports cancelled, not failed")
  func whisperCancellation() async throws {
    let delivered = DeliveredScope()
    let backend = Self.backend(load: { _ in throw CancellationError() }, delivered: delivered)
    await #expect(throws: CancellationError.self) { try await backend.prepare() }
    await delivered.waitFor(count: 2)
    #expect(delivered.all.map(\.phase) == [.loading, .cancelled])
  }

  /// The loading delivery is held: the native loader must not start until it lands, and at
  /// its first statement the loading tags are already delivered. Removing the barrier in
  /// `TranscribeCppWhisperBackend.runLoad` fails this test.
  @Test("the Whisper native load waits until its loading tags are delivered")
  func nativeLoadWaitsForLoadingTags() async throws {
    let delivered = DeliveredScope()
    let hold = Hold(arrivalsRequired: 2)
    let entries = Counter()
    let atEntry = DeliveredScope()
    let backend = Self.backend(
      load: { _ in
        if let last = delivered.all.last { atEntry.append(last) }
        await entries.bump()
        return 1
      }, delivered: delivered, hold: hold)
    let load = Task { try await backend.prepare() }
    await hold.waitForArrival()
    #expect(await entries.value == 0, "no native entry while the loading tags are held")
    await hold.release()
    try await load.value
    #expect(await entries.value == 1)
    #expect(atEntry.all.first?.phase == .loading)
    #expect(atEntry.all.first?.requested == Self.whisper)
  }

  /// An unload while the loading delivery is held: the abandoned load never enters the
  /// native loader, and the tags end cancelled with nothing serving.
  @Test("a Whisper load unloaded while its tags are held never enters the native load")
  func unloadWhileTagsHeldNeverLoads() async throws {
    let delivered = DeliveredScope()
    let hold = Hold(arrivalsRequired: 2)
    let entries = Counter()
    let backend = Self.backend(
      load: { _ in
        await entries.bump()
        return 1
      }, delivered: delivered, hold: hold)
    let load = Task { try await backend.prepare() }
    await hold.waitForArrival()
    // #3849: the unload joins the load it cancels, so it returns only after the held delivery
    // lets that load end. Its cancelled report (never held) shows it has superseded the load.
    let unload = Task { await backend.unload() }
    await delivered.waitUntil { $0.contains { $0.phase == .cancelled } }
    await hold.release()
    await unload.value
    await #expect(throws: (any Error).self) { try await load.value }
    #expect(await entries.value == 0, "the abandoned load never reached the native loader")
    // The unload's report outranks the held loading one, which may then be dropped.
    #expect(delivered.all.contains { $0.phase == .cancelled && $0.serving == nil })
  }

  @Test("a delivered identity for another Whisper variant is never reported")
  func mismatchedVariantNamesNoModel() async throws {
    let delivered = DeliveredScope()
    let other = ASRModelIdentity(
      name: "whisper-large-v3-turbo-gguf", revision: "01234567", variant: "small-Q8_0")
    let backend = Self.backend(
      load: { _ in 1 }, identity: other, delivered: delivered)
    try await backend.prepare()
    await delivered.waitFor(count: 2)
    #expect(delivered.all.last?.phase == .loaded)
    #expect(delivered.all.allSatisfy { $0.requested == nil && $0.serving == nil })
  }

  @MainActor final class Recorder {
    var snapshots: [ASRModelScopeOwner.Snapshot] = []
  }

  /// A real `ParakeetBackend` asked to load Ultra from an empty cache-only folder: the
  /// vendor refuses, so the tags must say which model was requested and that it failed.
  /// ASRManager reports synchronously on the main actor, so no delivery wait is needed.
  @Test("a failed Parakeet load reports the requested model, loading, then failed")
  func parakeetFailure() async throws {
    let empty = FileManager.default.temporaryDirectory
      .appendingPathComponent("ASRModelScopeProducerTests-\(UUID().uuidString)/parakeet-ultra")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: empty.deletingLastPathComponent()) }
    try await withParakeetOfflineModeExclusion {
      let selection = ParakeetSelectionProvider()
      selection.beforePhysicalLoad = { _ in }
      let request = selection.select(
        model: .ultra, revision: "95eaa59a39d4394f047a4dc5cce480388a60d1b6", directory: empty,
        cacheOnly: true, displayBytes: 1, repairable: false)
      let manager = ASRManager(
        engineMutationScope: .alwaysAllowedForTesting, parakeetSelection: selection)
      let recorder = Recorder()
      let owner = ASRModelScopeOwner(sink: { recorder.snapshots.append($0) })
      owner.activate(.parakeet)
      recorder.snapshots.removeAll()
      manager.modelScopeOwner = owner
      manager.setInitialBackendType(.parakeet)
      await #expect(throws: (any Error).self) { try await manager.loadModel() }
      #expect(recorder.snapshots.map(\.phase) == [.loading, .failed])
      #expect(recorder.snapshots.last?.requested == request.modelIdentity)
      #expect(recorder.snapshots.last?.requested?.name == "parakeet-ultra-coreml")
      #expect(recorder.snapshots.last?.serving == nil)
    }
  }
}

/// Harness control: a hold whose arrival never comes releases its waiter at the deadline
/// and records an issue, so a regression fails instead of hanging the suite.
@Suite("ASR model scope producer harness (#3546)", .tags(.harnessContract))
struct ASRModelScopeProducerHarnessTests {
  @Test("a hold that never arrives records an issue and releases its waiter")
  func missingArrivalIsBounded() async {
    let hold = Hold()
    await withKnownIssue {
      await hold.waitForArrival()
    }
  }
}
