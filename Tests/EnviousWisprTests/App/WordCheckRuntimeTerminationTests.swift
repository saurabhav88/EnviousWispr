import EnviousWisprCore
import EnviousWisprModelDelivery
import EnviousWisprPipeline
import EnviousWisprWordCheck
import Foundation
import Testing

@testable import EnviousWisprAppKit
import EnviousWisprAppKitTestSupport

/// The word check at quit (#3853). `WisprBootstrapper.applicationWillTerminate` calls
/// `releaseForTermination()` on the main thread. When this fails, quitting hangs behind a take's
/// MLX evaluation, the word check loads again during quit, or a load finishing during quit puts
/// the model back; with the `mlx-kev` controls, quitting with the model in memory shows a crash
/// dialog.
///
/// The real-model tests and controls run where the model has been downloaded
/// (`~/Library/Application Support/EnviousWispr/Models/word-check`), as `KevBatchParityTests`
/// does; skipped elsewhere, including CI, which has no model. They use an APFS clone of that
/// folder, never the folder itself.
@MainActor
@Suite("WordCheckRuntime: quit drops the model without waiting (#3853)", .tags(.productOutcome))
struct WordCheckRuntimeTerminationTests {
  /// The runtime's inputs, changeable mid-test.
  @MainActor final class Inputs {
    var dictionary = true
    var needed = true
    var onboarding = true
  }

  private static let resources = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/EnviousWispr/Resources")

  nonisolated static let realModelFolder = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("EnviousWispr/Models/word-check", isDirectory: true)
  nonisolated static var realModelPresent: Bool {
    FileManager.default.fileExists(
      atPath: realModelFolder.appendingPathComponent("kev-contract.json").path)
  }

  /// A runtime over a real `ModelDeliveryHome` in a temp folder (as `WordCheckRuntimeResidencyTests`
  /// builds it), driven to admitted. Without `realModel` no model files exist there, so a load fails
  /// at once. With it, the real model is cloned into the install folder after the launch probe has
  /// finished, so the probe never sees (or touches) those files. Admission is then forced, as the
  /// residency tests force it. Throws instead of recording, so a child process can call it.
  private static func makeRuntime(
    in temp: URL, realModel: Bool = false,
    drainForTermination: @escaping (TimeInterval) -> Bool = KevWordCheckModel.drainForTermination
  ) async throws -> WordCheckRuntime
  {
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    guard let flags = TestDefaults.suite("ew-3853-\(UUID().uuidString)"),
      let bundle = Bundle(url: Self.resources)
    else { throw FixtureError.setup }
    let delivery = ModelDeliveryHome(
      engineMutationScope: .live(tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
      manifestBundle: bundle, appSupportOverride: temp, deliveryFlagDefaults: flags)
    guard let registration = delivery.wordCheckRegistration else { throw FixtureError.setup }
    if realModel {
      // The probe's Task runs on the main actor, so it cannot finish before this callback is set.
      let probeFinished = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
        let once = Once()
        delivery.onWordCheckLaunchProbeFinished = { if once.claim() { done.resume(returning: true) } }
        Task { @MainActor in
          try? await Task.sleep(for: .seconds(30))  // deadline-fallback: the probe never finished
          if once.claim() { done.resume(returning: false) }
        }
      }
      guard probeFinished else { throw FixtureError.probe }
      delivery.onWordCheckLaunchProbeFinished = nil
      let install = registration.installDirectory
      try FileManager.default.createDirectory(
        at: install.deletingLastPathComponent(), withIntermediateDirectories: true)
      // On APFS this is a clone: no bytes copied, and the real folder is never written.
      try FileManager.default.copyItem(at: Self.realModelFolder, to: install)
    }
    let inputs = Inputs()
    let runtime = WordCheckRuntime(
      delivery: delivery,
      isDictionaryEnabled: { inputs.dictionary },
      someEngineLacksOwnChecker: { inputs.needed },
      isOnboardingComplete: { inputs.onboarding }, drainForTermination: drainForTermination)
    // The delivery handle replays its current state (not admitted) to the runtime on a later main
    // actor turn; forced admission must land after it, or that replay unloads what a test loads.
    let replayed = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
      let once = Once()
      runtime.onStatusChange = { if once.claim() { done.resume(returning: true) } }
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(30))  // deadline-fallback: the replay never arrived
        if once.claim() { done.resume(returning: false) }
      }
    }
    runtime.onStatusChange = {}
    guard replayed else { throw FixtureError.replay }
    runtime.deliveryStateChangedForTests(.admitted)
    guard runtime.loadAttemptsForTests == 0 else { throw FixtureError.loadedOnAdmission }
    return runtime
  }

  /// A fresh temp folder for one test's fixture. The PARENT test owns it and removes it, child
  /// failures included: an exit-test child ends with `exit()` or `_exit()`, so no cleanup of its
  /// own would run, and each real-model fixture holds a ~486 MB clone.
  private static func makeTempRoot() -> URL {
    URL(fileURLWithPath: TestTemporaryDirectory.path)
      .appendingPathComponent("ew-3853-\(UUID().uuidString)", isDirectory: true)
  }

  enum FixtureError: Error { case setup, probe, replay, loadedOnAdmission }

  /// Resumes the probe wait exactly once, whichever of the probe and its deadline comes first.
  @MainActor private final class Once {
    private var claimed = false
    func claim() -> Bool {
      defer { claimed = true }
      return claimed == false
    }
  }

  /// One learned-word question, as a take asks it.
  nonisolated static func question(id: Int, padding: Int = 0) -> LearnedWordCheckQuestion {
    let filler = String(
      repeating: "We reviewed the build logs before the release went out. ", count: padding)
    let sentence = "\(filler)Twist builds our Xcode project from Swift manifests."
    let start = sentence.index(sentence.startIndex, offsetBy: filler.count)
    let range = start..<sentence.index(start, offsetBy: "Twist".count)
    return LearnedWordCheckQuestion(
      id: id, sentence: sentence, range: range,
      contextRange: sentence.startIndex..<sentence.endIndex, word: "Tuist")
  }

  // MARK: - Runtime contract (no model needed)

  @Test("after the quit release no work loads the word check again")
  func laterLoadsRefused() async throws {
    let temp = Self.makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    // In-process tests must not permanently close the shared MLX gate (#3939).
    let runtime = try await Self.makeRuntime(in: temp, drainForTermination: { _ in true })
    runtime.releaseForTermination()
    #expect(runtime.isLoadedForTelemetry == false)
    #expect(runtime.terminationCleanupForTests != nil, "the cleanup is handed off, not skipped")
    runtime.recordingStarted(needsWordCheckForRecording: true)
    runtime.fileImportStarted(needsWordCheck: true)
    runtime.recoveryStarted(needsWordCheck: true)
    runtime.retryDownload()
    let selection = await runtime.selection()
    #expect(runtime.loadAttemptsForTests == 0, "a load started after the quit release")
    #expect(selection.checker == nil, "a take after the quit release got a checker")
    await runtime.terminationCleanupForTests?.value
  }

  // MARK: - Real model (skipped where it is not downloaded)

  @Test(
    "the quit release drops a loaded model at once; a take holding it keeps answering",
    .enabled(if: realModelPresent), .timeLimit(.minutes(1)))
  func dropsLoadedModel() async throws {
    let temp = Self.makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let runtime = try await Self.makeRuntime(
      in: temp, realModel: true, drainForTermination: { _ in true })
    let selection = await runtime.selection()
    let checker = try #require(selection.checker, "fixture: the real model must load")
    #expect(runtime.isLoadedForTelemetry)
    runtime.releaseForTermination()
    #expect(runtime.isLoadedForTelemetry == false, "the runtime still holds the model")
    await runtime.terminationCleanupForTests?.value
    // The take's hold outlives the runtime's: its check still answers after the cleanup ran.
    let decisions = try await checker.decide([Self.question(id: 1)])
    #expect(decisions.count == 1)
    #expect((await runtime.selection()).checker == nil)
    #expect(runtime.loadAttemptsForTests == 1)
  }

  @Test(
    "a load in flight at the quit release publishes nothing when it finishes",
    .enabled(if: realModelPresent), .timeLimit(.minutes(1)))
  func inFlightLoadDiscarded() async throws {
    let temp = Self.makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let runtime = try await Self.makeRuntime(
      in: temp, realModel: true, drainForTermination: { _ in true })
    let (reading, signal) = AsyncStream<Void>.makeStream()
    runtime.onLoadReadingForTests = { signal.yield() }
    runtime.recordingStarted(needsWordCheckForRecording: true)
    #expect(runtime.loadAttemptsForTests == 1, "fixture: record start begins a load")
    var iterator = reading.makeAsyncIterator()
    _ = await iterator.next()  // bounded by the test's time limit
    runtime.releaseForTermination()
    await runtime.runningLoadsFinishedForTests()
    #expect(runtime.isLoadedForTelemetry == false, "a load finishing after quit put the model back")
    #expect(runtime.loadAttemptsForTests == 1)
  }

  // MARK: - mlx-kev exit controls (#3853 §3.4)

  /// The `kev-` lines the child printed on stdout.
  private static func childLines(_ output: [UInt8]) -> [String] {
    String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init)
      .filter { $0.hasPrefix("kev-") }
  }

  /// The release time the child reported on its `kev-released ms=<n> <token>` line.
  private static func releaseMs(in lines: [String]) -> Int? {
    guard let line = lines.first(where: { $0.hasPrefix("kev-released ms=") }) else { return nil }
    return Int(line.split(separator: " ")[1].dropFirst("ms=".count))
  }

  /// Idle quit's bound, in milliseconds. Active evaluations use the production drain timeout.
  nonisolated static let releaseBoundMs = 100

  /// Retained-after-inference: the model has answered a real question and a take still holds it
  /// when the production quit release runs and the process calls `exit()`, which runs MLX's static
  /// Metal device destructor with the weights alive.
  @Test(
    "mlx-kev: a take holding the model through quit and exit() ends the process cleanly",
    .enabled(if: realModelPresent), .tags(.realBoundary), .timeLimit(.minutes(2)), .realBoundaryRun)
  func exitControlRetained() async throws {
    let token = UUID().uuidString
    let temp = Self.makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let path = temp.path
    let observed = await #expect(
      processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]
    ) { [token = token as String, path = path as String] in
      await Self.retainedChild(token: token, root: path)
    }
    let result = try #require(observed)
    let lines = Self.childLines(result.standardOutputContent)
    let stderr = String(decoding: result.standardErrorContent, as: UTF8.self)
    #expect(lines.last == "kev-exit \(token)", "stdout: \(lines) stderr: \(stderr)")
    let ms = try #require(Self.releaseMs(in: lines), "stdout: \(lines) stderr: \(stderr)")
    #expect(ms < Self.releaseBoundMs, "the quit release took \(ms) ms")
  }

  /// Active work (#3939): a short evaluation drains before quit returns; a long one is still
  /// running when the bounded drain gives up. Both children must survive the real `exit()`.
  @Test(
    "mlx-kev: quit drains short evaluations and bounds long evaluations, then exits cleanly",
    .enabled(if: realModelPresent), .tags(.realBoundary), .timeLimit(.minutes(2)), .realBoundaryRun,
    arguments: [false, true])
  func exitControlActive(longEvaluation: Bool) async throws {
    let token = UUID().uuidString
    let temp = Self.makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let path = temp.path
    let observed = await #expect(
      processExitsWith: .success, observing: [\.standardOutputContent, \.standardErrorContent]
    ) { [token = token as String, path = path as String, longEvaluation = longEvaluation as Bool] in
      await Self.activeChild(token: token, root: path, longEvaluation: longEvaluation)
    }
    let result = try #require(observed)
    let lines = Self.childLines(result.standardOutputContent)
    let stderr = String(decoding: result.standardErrorContent, as: UTF8.self)
    #expect(lines.last == "kev-exit \(token)", "stdout: \(lines) stderr: \(stderr)")
    let ms = try #require(Self.releaseMs(in: lines), "stdout: \(lines) stderr: \(stderr)")
    #expect(ms <= Self.activeReleaseBoundMs, "the quit release took \(ms) ms")
    #expect(lines.contains("kev-drained \(longEvaluation ? "false" : "true") \(token)"))
  }

  /// The existing 100 ms idle allowance covers scheduling/cache-cleanup overhead beyond the
  /// production timeout, not extra evaluation time. The long fixture must outlast twice this bound.
  private static var activeReleaseBoundMs: Int {
    Int((WordCheckRuntime.quitDrainTimeout * 1000).rounded(.up)) + releaseBoundMs
  }

  nonisolated private static func milliseconds(_ duration: Duration) -> Int {
    Int(duration / .milliseconds(1))
  }

  private static func say(_ line: String) {
    FileHandle.standardOutput.write(Data("\(line)\n".utf8))
  }

  /// Child body for the retained control. Records no test issues; a failed step ends with status 1.
  private static func retainedChild(token: String, root: String) async {
    // deadline-fallback: a hung child fails by name instead of running out the time limit
    DispatchQueue.global().asyncAfter(deadline: .now() + 90) { childFail("watchdog") }
    guard let runtime = try? await makeRuntime(in: URL(filePath: root), realModel: true) else {
      childFail("fixture")
    }
    guard let checker = await runtime.selection().checker else { childFail("load") }
    guard (try? await checker.decide([question(id: 1)]))?.count == 1 else { childFail("inference") }
    let started = ContinuousClock.now
    runtime.releaseForTermination()
    let ms = milliseconds(ContinuousClock.now - started)
    guard runtime.isLoadedForTelemetry == false else { childFail("still loaded") }
    // Checked here too, so a slow release fails by name even if the exit below then crashes.
    guard ms < releaseBoundMs else { childFail("the quit release took \(ms) ms") }
    say("kev-released ms=\(ms) \(token)")
    withExtendedLifetime(checker) {
      say("kev-exit \(token)")
      exit(0)
    }
  }

  /// Releases while MLX's evaluation lock is held, observed by a blocked real cache clear.
  /// Calibrate with measured model work, never a sleeping fake. These real-boundary controls
  /// intentionally take seconds: only real MLX work plus `exit()` reaches the shutdown race.
  private static func activeChild(token: String, root: String, longEvaluation: Bool) async {
    // deadline-fallback: a hung child fails by name instead of running out the time limit
    DispatchQueue.global().asyncAfter(deadline: .now() + 90) { childFail("watchdog") }
    let drainResult = ChildResult()
    guard let runtime = try? await makeRuntime(
      in: URL(filePath: root), realModel: true,
      drainForTermination: { timeout in
        let drained = KevWordCheckModel.drainForTermination(timeout: timeout)
        drainResult.record(drained)
        return drained
      })
    else { childFail("fixture") }
    guard let checker = await runtime.selection().checker else { childFail("load") }
    let timeoutMs = WordCheckRuntime.quitDrainTimeout * 1000
    var batch = longEvaluation
      ? (0..<16).map { question(id: $0, padding: 60) } : [question(id: 0)]
    var batchMs = 0
    // At most three measured sizes; fail the fixture if this Mac cannot stage the requested case.
    for _ in 0..<3 {
      let timed = ContinuousClock.now
      guard (try? await checker.decide(batch))?.count == batch.count else { childFail("batch") }
      batchMs = milliseconds(ContinuousClock.now - timed)
      if longEvaluation == false || batchMs >= 2 * activeReleaseBoundMs { break }
      batch += batch.map { question(id: $0.id + batch.count, padding: 60) }
    }
    if longEvaluation {
      guard batchMs >= 2 * activeReleaseBoundMs else {
        childFail("long batch too short: \(batchMs) ms")
      }
    } else {
      guard batchMs >= 4, Double(batchMs) < timeoutMs / 2 else {
        childFail("short batch outside fixture range: \(batchMs) ms")
      }
    }
    say("kev-batch ms=\(batchMs) \(token)")
    let evaluation = ChildResult()
    let activeBatch = batch
    let work = Task.detached {
      let count = try? await checker.decide(activeBatch).count
      evaluation.record(count == activeBatch.count)
    }
    let probe = EvalLockProbe()
    probe.start()
    // Measured lock contention is the precondition, not a fixed pause. The watchdog bounds it.
    while probe.blockedMs() < 1 {
      guard evaluation.value == nil else { childFail("evaluation ended before quit") }
    }
    probe.stopAfterCurrentClear()
    let started = ContinuousClock.now
    runtime.releaseForTermination()
    let elapsed = ContinuousClock.now - started
    let ms = milliseconds(elapsed)
    guard runtime.isLoadedForTelemetry == false else { childFail("still loaded") }
    guard ms <= activeReleaseBoundMs else { childFail("the quit release took \(ms) ms") }
    if longEvaluation {
      guard drainResult.value == false, elapsed >= .seconds(WordCheckRuntime.quitDrainTimeout),
        probe.blockedMs() > 0, evaluation.value == nil
      else { childFail("long evaluation did not outlast the bounded drain") }
    } else {
      // A successful production drain means the evaluation AND the cache clear have left the
      // MLX gate. This observes actual completion without racing the detached task's resumption.
      guard drainResult.value == true else {
        childFail("short evaluation did not finish before quit returned")
      }
      await work.value
      guard evaluation.value == true else { childFail("short evaluation failed") }
    }
    say("kev-drained \(drainResult.value == true ? "true" : "false") \(token)")
    say("kev-released ms=\(ms) \(token)")
    withExtendedLifetime(work) {
      say("kev-exit \(token)")
      exit(0)
    }
  }

  /// Cross-thread observations; nil means the operation has not returned yet.
  private final class ChildResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    func record(_ value: Bool) { lock.withLock { result = value } }
    var value: Bool? { lock.withLock { result } }
  }

  // MARK: - #3987: the quit cleanup must never be MLX's first use

  /// The app's `exit()` runs C++ static destructors for a long time; a bare test process's does
  /// not. Busy steps registered with `__cxa_atexit` stand in for that, so the quit cleanup's
  /// detached task runs while `exit()` is still finalizing (#3987, ENVIOUSWISPR-7W).
  nonisolated static let busyExitSteps = 2_000_000
  nonisolated static let quitRuns = Array(0..<20)

  /// A process that never used MLX quits: the production quit release, then `exit()` under a
  /// long finalization. When the quit cleanup was MLX's first use, MLX built its allocator while
  /// `exit()` destroyed the device-info map it reads, and the child died by SIGSEGV.
  @Test(
    "a quit with MLX never used exits cleanly while exit() finalizes",
    .bug("https://github.com/saurabhav88/EnviousWispr/issues/3987", "quit cleanup was MLX's first use"),
    .timeLimit(.minutes(2)), arguments: quitRuns)
  func quitWithMLXUnusedExitsCleanly(run: Int) async throws {
    let temp = Self.makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let path = temp.path
    let result = await #expect(
      processExitsWith: .success, observing: [\.standardOutputContent]
    ) { [path = path as String] in
      await Self.unusedMLXQuitChild(root: path)
    }
    // Clean exit only (#4155): production lets this detached cleanup stay unfinished at `exit()`, so
    // whether its line reaches stdout first is a race and is not asserted here. That the cleanup
    // runs to completion is asserted deterministically by `cleanupCompletesWhenAwaited*` below.
    _ = try #require(result)
  }

  /// Child body: no model, no MLX call before the production quit release.
  private static func unusedMLXQuitChild(root: String) async {
    // deadline-fallback: a hung child fails by name instead of running out the time limit
    DispatchQueue.global().asyncAfter(deadline: .now() + 60) { childFail("watchdog") }
    guard let runtime = try? await makeRuntime(in: URL(filePath: root)) else { childFail("fixture") }
    registerBusyExit()
    runtime.releaseForTermination()
    exit(0)
  }

  /// Registers the busy exit steps; a step that cannot register fails the child, so a short
  /// finalization can never pass for the long one.
  nonisolated private static func registerBusyExit() {
    for step in 0..<busyExitSteps {
      guard registerExitStep(busyExitStep, nil, nil) == 0 else {
        childFail("busy-exit registration \(step)")
      }
    }
  }

  nonisolated static let mlxUsedQuitRuns = Array(0..<20)
  nonisolated static let realModelQuitRuns = Array(0..<10)

  /// Lifetime control: MLX was used before production quit cleanup under the same busy exit.
  /// Checks sampled clean exits; the separate Bool checks verify the cleanup branch.
  @Test(
    "a quit after MLX was used exits cleanly while exit() finalizes",
    .bug("https://github.com/saurabhav88/EnviousWispr/issues/3987", "quit cleanup was MLX's first use"),
    .timeLimit(.minutes(2)), arguments: mlxUsedQuitRuns)
  func quitAfterMLXUsedExitsCleanly(run: Int) async throws {
    let temp = Self.makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let path = temp.path
    let result = await #expect(
      processExitsWith: .success, observing: [\.standardOutputContent]
    ) { [path = path as String] in
      await Self.usedMLXQuitChild(root: path)
    }
    // Clean exit only (#4155): production lets this detached cleanup stay unfinished at `exit()`, so
    // whether its line reaches stdout first is a race and is not asserted here. That the cleanup
    // runs to completion is asserted deterministically by `cleanupCompletesWhenAwaited*` below.
    _ = try #require(result)
  }

  private static func usedMLXQuitChild(root: String) async {
    // deadline-fallback: a hung child fails by name instead of running out the time limit
    DispatchQueue.global().asyncAfter(deadline: .now() + 60) { childFail("watchdog") }
    guard let runtime = try? await makeRuntime(in: URL(filePath: root)) else { childFail("fixture") }
    _ = KevWordCheckModel.memorySnapshotForLog()
    registerBusyExit()
    runtime.releaseForTermination()
    exit(0)
  }

  /// Control: the real model loaded and answered one question, the take let go of it, then the app
  /// quits under the same long finalization. Skipped where the model is not downloaded.
  @Test(
    "a quit after the real model answered exits cleanly while exit() finalizes",
    .bug("https://github.com/saurabhav88/EnviousWispr/issues/3987", "quit cleanup was MLX's first use"),
    .enabled(if: realModelPresent), .tags(.realBoundary), .timeLimit(.minutes(2)),
    .realBoundaryRun,
    arguments: realModelQuitRuns)
  func quitAfterRealModelExitsCleanly(run: Int) async throws {
    let temp = Self.makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let path = temp.path
    let result = await #expect(
      processExitsWith: .success, observing: [\.standardOutputContent]
    ) { [path = path as String] in
      await Self.realModelQuitChild(root: path)
    }
    // Clean exit only (#4155): production lets this detached cleanup stay unfinished at `exit()`, so
    // whether its line reaches stdout first is a race and is not asserted here. That the cleanup
    // runs to completion is asserted deterministically by `cleanupCompletesWhenAwaited*` below.
    _ = try #require(result)
  }

  private static func realModelQuitChild(root: String) async {
    // deadline-fallback: a hung child fails by name instead of running out the time limit
    DispatchQueue.global().asyncAfter(deadline: .now() + 60) { childFail("watchdog") }
    guard let runtime = try? await makeRuntime(in: URL(filePath: root), realModel: true) else {
      childFail("fixture")
    }
    await answerOneQuestion(runtime)
    registerBusyExit()
    runtime.releaseForTermination()
    exit(0)
  }

  /// One take's check, its checker released when this returns, so only the runtime holds the model
  /// at quit.
  private static func answerOneQuestion(_ runtime: WordCheckRuntime) async {
    guard let checker = await runtime.selection().checker else { childFail("load") }
    guard (try? await checker.decide([question(id: 1)]))?.count == 1 else { childFail("inference") }
  }

  /// #4155: the cleanup reaches its end. The child waits for the detached cleanup task itself (the
  /// subject's own completion signal) before it exits, so the line is not racing `exit()`.
  @Test(
    "the quit cleanup runs to its end when the process waits for it (no model)",
    .bug("https://github.com/saurabhav88/EnviousWispr/issues/4155", "line raced exit()"),
    .timeLimit(.minutes(2)))
  func cleanupCompletesWhenAwaitedNoModel() async throws {
    let temp = Self.makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let path = temp.path
    let result = await #expect(
      processExitsWith: .success, observing: [\.standardOutputContent]
    ) { [path = path as String] in
      await Self.awaitedCleanupChild(root: path, realModel: false)
    }
    let output = try #require(result).standardOutputContent
    #expect(Self.childLines(output) == ["kev-quit-cleanup-complete"])
  }

  @Test(
    "the quit cleanup runs to its end when the process waits for it (real model answered)",
    .bug("https://github.com/saurabhav88/EnviousWispr/issues/4155", "line raced exit()"),
    .enabled(if: realModelPresent), .tags(.realBoundary), .timeLimit(.minutes(2)),
    .realBoundaryRun)
  func cleanupCompletesWhenAwaitedRealModel() async throws {
    let temp = Self.makeTempRoot()
    defer { try? FileManager.default.removeItem(at: temp) }
    let path = temp.path
    let result = await #expect(
      processExitsWith: .success, observing: [\.standardOutputContent]
    ) { [path = path as String] in
      await Self.awaitedCleanupChild(root: path, realModel: true)
    }
    let output = try #require(result).standardOutputContent
    #expect(Self.childLines(output) == ["kev-quit-cleanup-complete"])
  }

  private static func awaitedCleanupChild(root: String, realModel: Bool) async {
    // deadline-fallback: a hung child fails by name instead of running out the time limit
    DispatchQueue.global().asyncAfter(deadline: .now() + 60) { childFail("watchdog") }
    guard let runtime = try? await makeRuntime(in: URL(filePath: root), realModel: realModel) else {
      childFail("fixture")
    }
    if realModel { await answerOneQuestion(runtime) }
    runtime.onTerminationCleanupForTests = {
      FileHandle.standardOutput.write(Data("kev-quit-cleanup-complete\n".utf8))
    }
    runtime.releaseForTermination()
    await runtime.terminationCleanupForTests?.value
    exit(0)
  }

  /// The cleanup's own answer, each in a fresh process (MLX state is process-wide): it skips MLX
  /// while nothing in the process has used MLX, and clears once something has (#3987).
  @Test(
    "the cache clear skips MLX until this process has used it, then clears",
    .bug("https://github.com/saurabhav88/EnviousWispr/issues/3987", "quit cleanup was MLX's first use"),
    .timeLimit(.minutes(2)))
  func cacheClearSkipsUntilMLXUsed() async throws {
    let unused = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
      // deadline-fallback: a hung child fails instead of stranding the branch check
      DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
        childFail("watchdog")
      }
      let cleared = KevWordCheckModel.releaseCachedBuffers()
      FileHandle.standardOutput.write(Data("kev-clear \(cleared ? "cleared" : "skipped")\n".utf8))
      exit(0)
    }
    #expect(Self.childLines(try #require(unused).standardOutputContent) == ["kev-clear skipped"])
    let used = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
      // deadline-fallback: a hung child fails instead of stranding the branch check
      DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
        childFail("watchdog")
      }
      _ = KevWordCheckModel.memorySnapshotForLog()
      let cleared = KevWordCheckModel.releaseCachedBuffers()
      FileHandle.standardOutput.write(Data("kev-clear \(cleared ? "cleared" : "skipped")\n".utf8))
      exit(0)
    }
    #expect(Self.childLines(try #require(used).standardOutputContent) == ["kev-clear cleared"])
  }

  /// Clears MLX's cache in a loop on its own thread. `Memory.clearCache()` takes MLX's evaluation
  /// lock, so a clear that stays blocked means an evaluation holds that lock right now.
  private final class EvalLockProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var enteredAt: ContinuousClock.Instant?
    private var stopping = false

    func start() {
      Thread.detachNewThread { [self] in
        while true {
          lock.withLock { enteredAt = .now }
          KevWordCheckModel.releaseCachedBuffers()
          let stopped = lock.withLock {
            enteredAt = nil
            return stopping
          }
          if stopped { return }
        }
      }
    }

    func stopAfterCurrentClear() { lock.withLock { stopping = true } }

    /// How long the current clear has been blocked, or 0 when none is.
    func blockedMs() -> Int {
      lock.withLock { enteredAt.map { WordCheckRuntimeTerminationTests.milliseconds(.now - $0) } ?? 0 }
    }
  }
}

/// `__cxa_atexit` directly: `atexit()` looks up the caller's image (`dladdr`) on every call, which
/// makes two million registrations take hours (#3987).
@_silgen_name("__cxa_atexit")
private func registerExitStep(
  _ step: @convention(c) (UnsafeMutableRawPointer?) -> Void, _ argument: UnsafeMutableRawPointer?,
  _ image: UnsafeMutableRawPointer?
) -> Int32

/// One shutdown step of about 200 ns that never sleeps: a sleeping step lets the cleanup thread
/// pass the microsecond window the crash needs.
private let busyExitStep: @convention(c) (UnsafeMutableRawPointer?) -> Void = { _ in
  let end = mach_absolute_time() &+ 5  // test-fixture-timer: 5 ticks of the 24 MHz clock
  while mach_absolute_time() < end {}
}

/// A child-process check failed: names the step on stderr and ends with status 1, so the
/// parent's success condition can never be met after it (#3853; same contract as #3849's).
private func childFail(_ step: String) -> Never {
  FileHandle.standardError.write(Data("child failed: \(step)\n".utf8))
  _exit(1)
}
