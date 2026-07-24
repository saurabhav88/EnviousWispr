#if DEBUG
import EnviousWisprCore
import Foundation
import Testing

/// #1755 chunk 6 — the crash-boundary controller contract (plan §10/§11.1
/// leg 5). Every test uses an ISOLATED controller with its own temp file
/// paths — nothing here touches the shared `/tmp` production paths, so the
/// suite needs no serialization.
@Suite("CrashBoundaryFaultController (#1755 chunk 6)")
struct CrashBoundaryFaultControllerTests {

  private struct Fixture {
    let controller: CrashBoundaryFaultController
    let armPath: String
    let reachedPath: String
  }

  private static func makeFixture() -> Fixture {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-crash-boundary-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let arm = dir.appendingPathComponent("arm").path
    let reached = dir.appendingPathComponent("reached").path
    return Fixture(
      controller: CrashBoundaryFaultController(armFilePath: arm, reachedFilePath: reached),
      armPath: arm, reachedPath: reached)
  }

  private static func write(_ record: CrashBoundarySignalRecord, to path: String) {
    let data = try! PropertyListEncoder().encode(record)
    try! data.write(to: URL(fileURLWithPath: path), options: .atomic)
  }

  /// Lock-protected fired-or-waiting one-shot (same shape as the recovery
  /// coordinator tests' helper): whichever of signal()/wait() runs first, the
  /// waiter resumes exactly once. Signals, never clocks.
  private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiter: CheckedContinuation<Void, Never>?
    func signal() {
      let resumable: CheckedContinuation<Void, Never>? = lock.withLock {
        if fired { return nil }
        fired = true
        let w = waiter
        waiter = nil
        return w
      }
      resumable?.resume()
    }
    func wait() async {
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        let resumeNow: Bool = lock.withLock {
          if fired { return true }
          waiter = c
          return false
        }
        if resumeNow { c.resume() }
      }
    }
  }

  private struct BackgroundHit {
    let entered: OneShot
    let finished: OneShot
  }

  /// Fires `boundaryReached` on a dedicated background thread and returns
  /// (entered, finished) one-shot observation points.
  private static func fireOnBackgroundTask(
    _ controller: CrashBoundaryFaultController, _ boundary: CrashBoundary
  ) -> BackgroundHit {
    let entered = OneShot()
    let finished = OneShot()
    Thread.detachNewThread {
      entered.signal()
      controller.boundaryReached(boundary)
      finished.signal()
    }
    return BackgroundHit(entered: entered, finished: finished)
  }

  @Test("the boundary vocabulary is exactly the five approved raw values")
  func vocabularyIsClosed() {
    #expect(
      Set(CrashBoundary.allCases.map(\.rawValue)) == [
        "retry_exhaustion_decided", "live_terminal_published", "before_spool_delete",
        "before_key_delete", "destruction_api_return",
      ])
    #expect(CrashBoundary.allCases.count == 5)
  }

  @Test("arm acknowledgement records the exact pair; empty trial fails closed")
  func armWritesExactPair() throws {
    let fx = Self.makeFixture()
    #expect(!fx.controller.arm(trialID: "", boundary: .beforeSpoolDelete), "empty trial refused")
    #expect(fx.controller.arm(trialID: "t1", boundary: .beforeSpoolDelete))
    let data = try Data(contentsOf: URL(fileURLWithPath: fx.armPath))
    let record = try PropertyListDecoder().decode(CrashBoundarySignalRecord.self, from: data)
    #expect(record == CrashBoundarySignalRecord(trialID: "t1", boundary: "before_spool_delete"))
    fx.controller.clear()
  }

  @Test(
    "missing, malformed, stale-trial, wrong-trial, and wrong-boundary reached files query false")
  func reachedQueryFailsClosed() throws {
    let fx = Self.makeFixture()
    // Missing.
    #expect(!fx.controller.isReached(trialID: "t1", boundary: .beforeSpoolDelete))
    // Malformed.
    try Data([0xDE, 0xAD]).write(to: URL(fileURLWithPath: fx.reachedPath))
    #expect(!fx.controller.isReached(trialID: "t1", boundary: .beforeSpoolDelete))
    // Stale/wrong trial and wrong boundary.
    Self.write(
      CrashBoundarySignalRecord(trialID: "old-trial", boundary: "before_spool_delete"),
      to: fx.reachedPath)
    #expect(!fx.controller.isReached(trialID: "t1", boundary: .beforeSpoolDelete), "wrong trial")
    #expect(
      !fx.controller.isReached(trialID: "old-trial", boundary: .beforeKeyDelete), "wrong boundary")
    #expect(
      fx.controller.isReached(trialID: "old-trial", boundary: .beforeSpoolDelete),
      "the exact pair still reads true")
    // Empty trial never matches.
    #expect(
      !CrashBoundaryFaultController.readReached(
        trialID: "", boundary: .beforeSpoolDelete, reachedFilePath: fx.reachedPath))
  }

  @Test("a wrong-boundary hit leaves the live arm intact and does not block")
  func wrongBoundaryHitLeavesArm() {
    let fx = Self.makeFixture()
    #expect(fx.controller.arm(trialID: "t1", boundary: .beforeSpoolDelete))
    // Wrong boundary: returns synchronously (this call would hang the test if
    // it parked — its prompt return IS the assertion), consumes nothing.
    fx.controller.boundaryReached(.retryExhaustionDecided)
    #expect(fx.controller.hasLiveArmForTesting, "the arm survives a wrong-boundary hit")
    #expect(FileManager.default.fileExists(atPath: fx.armPath), "arm artifact survives")
    #expect(!fx.controller.isReached(trialID: "t1", boundary: .retryExhaustionDecided))
    fx.controller.clear()
  }

  @Test("a matching hit consumes the arm BEFORE publishing, holds until release, exact record")
  func matchingHitConsumesPublishesAndHolds() async {
    let fx = Self.makeFixture()
    #expect(fx.controller.arm(trialID: "t2", boundary: .liveTerminalPublished))
    let published = OneShot()
    fx.controller.onPublishForTesting = { _ in published.signal() }
    let run = Self.fireOnBackgroundTask(fx.controller, .liveTerminalPublished)
    await published.wait()
    fx.controller.releaseHeldForTesting()
    await run.finished.wait()
    #expect(
      fx.controller.isReached(trialID: "t2", boundary: .liveTerminalPublished),
      "the exact reached record was published before the park")
    #expect(!FileManager.default.fileExists(atPath: fx.armPath), "arm consumed before publication")
    #expect(!fx.controller.hasLiveArmForTesting)
  }

  @Test("a duplicate matching hit neither republishes nor holds")
  func duplicateHitPassesThrough() async {
    let fx = Self.makeFixture()
    #expect(fx.controller.arm(trialID: "t3", boundary: .beforeSpoolDelete))
    let published = OneShot()
    fx.controller.onPublishForTesting = { _ in published.signal() }
    let run = Self.fireOnBackgroundTask(fx.controller, .beforeSpoolDelete)
    await published.wait()
    fx.controller.releaseHeldForTesting()
    await run.finished.wait()
    // Second hit: arm is gone — synchronous pass-through (a park would hang).
    fx.controller.boundaryReached(.beforeSpoolDelete)
    #expect(fx.controller.isReached(trialID: "t3", boundary: .beforeSpoolDelete))
  }

  @Test("clear removes both artifacts and releases a held path")
  func clearRemovesAndReleases() async {
    let fx = Self.makeFixture()
    #expect(fx.controller.arm(trialID: "t4", boundary: .beforeKeyDelete))
    let published = OneShot()
    fx.controller.onPublishForTesting = { _ in published.signal() }
    let run = Self.fireOnBackgroundTask(fx.controller, .beforeKeyDelete)
    await published.wait()
    fx.controller.clear()
    await run.finished.wait()
    #expect(!FileManager.default.fileExists(atPath: fx.armPath))
    #expect(!FileManager.default.fileExists(atPath: fx.reachedPath))
  }

  @Test("a new controller does not activate stale on-disk arm or reached files")
  func freshControllerIgnoresStaleFiles() {
    let fx = Self.makeFixture()
    Self.write(
      CrashBoundarySignalRecord(trialID: "ghost", boundary: "before_key_delete"), to: fx.armPath)
    Self.write(
      CrashBoundarySignalRecord(trialID: "ghost", boundary: "before_key_delete"),
      to: fx.reachedPath)
    let fresh = CrashBoundaryFaultController(
      armFilePath: fx.armPath, reachedFilePath: fx.reachedPath)
    #expect(!fresh.hasLiveArmForTesting, "files are evidence, never permission to re-arm")
    // An unarmed hit passes straight through (a park would hang the test).
    fresh.boundaryReached(.beforeKeyDelete)
    // The stale reached file still reads for ITS pair (external cleanup is
    // the harness's job) — but nothing new was armed, consumed, or held.
    #expect(fresh.isReached(trialID: "ghost", boundary: .beforeKeyDelete))
  }

  // MARK: - destruction_api_return two-order matrix

  @Test(
    "key-delete first: gated without publication; caller hook then publishes; release frees both")
  func destructionAPIReturnKeyFirst() async {
    let fx = Self.makeFixture()
    #expect(fx.controller.arm(trialID: "t5", boundary: .destructionAPIReturn))
    // Schedule 1: the detached key path arrives BEFORE the API returns —
    // observe the GATE DECISION itself.
    let gateDecision = OneShot()
    let gatedBox = NSLock()
    nonisolated(unsafe) var gated: Bool?
    fx.controller.onKeyDeleteGateDecisionForTesting = { decision in
      gatedBox.withLock { if gated == nil { gated = decision } }
      gateDecision.signal()
    }
    let keyPath = Self.fireOnBackgroundTask(fx.controller, .beforeKeyDelete)
    await gateDecision.wait()
    #expect(gatedBox.withLock { gated } == true, "key-first: the key path is gated")
    #expect(
      !fx.controller.isReached(trialID: "t5", boundary: .destructionAPIReturn),
      "gating the key path must not publish destruction_api_return")
    #expect(fx.controller.hasLiveArmForTesting, "the gate does not consume the arm")
    // The caller hook (API returned) now publishes and holds.
    let published = OneShot()
    fx.controller.onPublishForTesting = { _ in published.signal() }
    let caller = Self.fireOnBackgroundTask(fx.controller, .destructionAPIReturn)
    await published.wait()
    #expect(
      fx.controller.isReached(trialID: "t5", boundary: .destructionAPIReturn),
      "the caller-side hook published the exact record before parking")
    fx.controller.releaseHeldForTesting()
    await keyPath.finished.wait()
    await caller.finished.wait()
  }

  @Test(
    "API-return first: publishes and holds; a later key-delete path is still gated; release frees both"
  )
  func destructionAPIReturnCallerFirst() async {
    let fx = Self.makeFixture()
    #expect(fx.controller.arm(trialID: "t6", boundary: .destructionAPIReturn))
    // Schedule 2: the caller hook fires first. NOTE the consumed arm: gating
    // afterwards relies on `released` still being false.
    let published = OneShot()
    fx.controller.onPublishForTesting = { _ in published.signal() }
    let caller = Self.fireOnBackgroundTask(fx.controller, .destructionAPIReturn)
    await published.wait()
    #expect(fx.controller.isReached(trialID: "t6", boundary: .destructionAPIReturn))
    // The later key path must STILL be gated (persistent gate flag after the
    // arm was consumed) — observe the GATE DECISION itself, not thread entry.
    let gateDecision = OneShot()
    let gatedBox = NSLock()
    nonisolated(unsafe) var gated: Bool?
    fx.controller.onKeyDeleteGateDecisionForTesting = { decision in
      gatedBox.withLock { if gated == nil { gated = decision } }
      gateDecision.signal()
    }
    let keyPath = Self.fireOnBackgroundTask(fx.controller, .beforeKeyDelete)
    await gateDecision.wait()
    #expect(gatedBox.withLock { gated } == true, "caller-first: the key path is still gated")
    fx.controller.releaseHeldForTesting()
    await caller.finished.wait()
    await keyPath.finished.wait()
  }

  @Test("stale files with no live in-process arm do not gate key deletion")
  func staleFilesDoNotGateKeyDeletion() {
    let fx = Self.makeFixture()
    Self.write(
      CrashBoundarySignalRecord(trialID: "ghost", boundary: "destruction_api_return"),
      to: fx.armPath)
    Self.write(
      CrashBoundarySignalRecord(trialID: "ghost", boundary: "destruction_api_return"),
      to: fx.reachedPath)
    let fresh = CrashBoundaryFaultController(
      armFilePath: fx.armPath, reachedFilePath: fx.reachedPath)
    let gatedBox = NSLock()
    nonisolated(unsafe) var gated: Bool?
    fresh.onKeyDeleteGateDecisionForTesting = { decision in
      gatedBox.withLock { if gated == nil { gated = decision } }
    }
    // Synchronous return IS the assertion — a gate would hang the test.
    fresh.boundaryReached(.beforeKeyDelete)
    #expect(gatedBox.withLock { gated } == false, "no live arm ⇒ the key path passes ungated")
    #expect(!fresh.hasLiveArmForTesting)
  }
}
#endif
