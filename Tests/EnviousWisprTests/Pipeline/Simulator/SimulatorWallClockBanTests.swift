import Foundation
import Testing

/// Wall-clock ban (epic #827, PR-2 plan §11.2, §10 — Codex round-1 revision 10).
///
/// Scans every Swift source file in the simulator directory and fails if any
/// uses a wall-clock API. The simulator's determinism rests on `FakeClock`
/// being the ONLY time source; a stray `Task.sleep` / `Date()` / `Timer` would
/// reintroduce nondeterminism. This catches that at PR CI — the earliest
/// failure point — before it produces a flake.
@Suite("Simulator wall-clock ban")
struct SimulatorWallClockBanTests {

  /// Banned substrings — wall-clock APIs no simulator file may use.
  /// `Task.yield()` is NOT banned: it is a cooperative yield, not a wall-clock
  /// wait.
  private static let bannedPatterns = [
    "Task.sleep",
    "DispatchQueue",
    "Date()",
    "ContinuousClock",
    "SuspendingClock",
    "Timer(",
    "asyncAfter",
    "ProcessInfo.processInfo.systemUptime",
  ]

  @Test("no simulator source file uses a wall-clock API")
  func noWallClockInSimulatorDirectory() throws {
    let simulatorDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    // Self-exclude by full path, not basename — a same-named file in any
    // nested subfolder must not silently skip this scan (#834 finding 2).
    let selfPath = URL(fileURLWithPath: #filePath).standardizedFileURL

    // Recursive enumeration — a non-recursive `contentsOfDirectory` would miss
    // wall-clock APIs in any future nested subfolder under Simulator/.
    let enumerator = FileManager.default.enumerator(
      at: simulatorDir, includingPropertiesForKeys: nil)
    var swiftFiles: [URL] = []
    while let url = enumerator?.nextObject() as? URL {
      if url.pathExtension == "swift" && url.standardizedFileURL != selfPath {
        swiftFiles.append(url)
      }
    }

    #expect(!swiftFiles.isEmpty, "expected to find simulator source files to scan")

    for file in swiftFiles {
      let source = try String(contentsOf: file, encoding: .utf8)
      for pattern in Self.bannedPatterns where source.contains(pattern) {
        let name = file.lastPathComponent
        Issue.record(
          "\(name) uses banned wall-clock API \"\(pattern)\"; simulator time must come from FakeClock"
        )
      }
    }
  }
}
