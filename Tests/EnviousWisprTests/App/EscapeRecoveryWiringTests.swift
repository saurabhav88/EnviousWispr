import EnviousWisprCore
import EnviousWisprStorage
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprPipeline

/// The composition seam that lets the kernel write crash provenance (#2087).
///
/// Small on purpose, and tested anyway: a connector that silently does nothing is
/// indistinguishable from one that works, and the cost of that here is a
/// cancelled dictation coming back as a permanent History row after a crash.
@MainActor
/// Class: `.productOutcome` — a half-connected feature: a held row nobody can see, or a dead button.
@Suite("Escape Recovery wiring (#2087)", .tags(.productOutcome))
struct EscapeRecoveryWiringTests {

  private func tempStore() -> RecoverySpoolStore {
    RecoverySpoolStore(
      directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("ew-wiring-\(UUID().uuidString)", isDirectory: true))
  }

  /// The writer must actually reach the store. `makeStore` is a parameter with a
  /// production default precisely so this can be asserted — hard-coding the real
  /// directory would have made the composition untestable by construction, since
  /// no test may write into the user's own recovery folder.
  @Test("the writer commits a readable marker through the store it is given")
  func writerCommitsThroughItsStore() {
    let store = tempStore()
    let at = Date(timeIntervalSince1970: 1_755_300_000)

    let write = EscapeRecoveryWiring.writer(makeStore: { store })
    #expect(write("sess-1", at, "take-3"))

    guard case .valid(let marker) = store.readEscapeMarker(for: "sess-1") else {
      Issue.record("the writer reported success but committed nothing")
      return
    }
    #expect(marker.recoverySessionID == "sess-1")
    #expect(marker.triggeredAt == at, "the user's keypress time, not the write time")
    #expect(marker.takeID == "take-3")
  }

  /// The writer reports failure rather than swallowing it, because the kernel
  /// branches on that answer: `false` means perform today's ordinary destructive
  /// cancel. A writer that returned `true` regardless would leave the kernel
  /// believing a take is recoverable when nothing was recorded.
  @Test("the writer reports failure when the store cannot commit")
  func writerReportsFailure() throws {
    let store = tempStore()
    try FileManager.default.createDirectory(
      at: store.directoryURL, withIntermediateDirectories: true)
    // Block the write at its first step (temp path is a directory ⇒ EISDIR).
    try FileManager.default.createDirectory(
      at: store.directoryURL.appendingPathComponent(
        ".sess-2.\(RecoveryConstants.escapeMarkerFileExtension).tmp"),
      withIntermediateDirectories: true)

    let write = EscapeRecoveryWiring.writer(makeStore: { store })
    #expect(write("sess-2", Date(), nil) == false)
  }

  /// The writer must not be reachable by accident. A store that cannot even
  /// create its directory still answers `false` rather than throwing into the
  /// kernel's cancel path, which is a heart-path surface.
  ///
  /// (The factory's own unwired default is the literal `{ _, _, _ in false }` in
  /// its signature; the capability-level activation canary for chunks 4-11 lives
  /// in `KernelDictationDriverBridgeMatrixTests`, asserted against a real driver.)
  @Test("an unusable store answers false instead of throwing into the cancel path")
  func unusableStoreFailsClosedQuietly() throws {
    // A directory whose PARENT is a regular file can never be created.
    let blocker = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-wiring-blocker-\(UUID().uuidString)")
    try Data([0]).write(to: blocker)
    let doomed = RecoverySpoolStore(directory: blocker.appendingPathComponent("spools"))

    let write = EscapeRecoveryWiring.writer(makeStore: { doomed })
    #expect(write("sess-3", Date(), nil) == false)
  }
}
