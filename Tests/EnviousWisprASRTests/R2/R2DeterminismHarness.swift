import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprASR

// R2 (#360) — characterization safety net.
//
// PR 1 of 2 ships this harness against unchanged production code. PR 2 (#360)
// performs the WhisperKitBackend boundary refactor. The assertions in
// `R2CharacterizationTests.swift` MUST NOT be modified in PR 2 — they are the
// regression oracle.
//
// Scope of this harness:
// - Provides deterministic time + isolated UserDefaults so classifier tests
//   are stable across runs (required for R2CharacterizationTests).
// - Exposes a single `r2MakeDetector(...)` factory that returns a fresh
//   detector + clock with private flip-flop state. Each test starts from
//   nil-sessionPreferred and must seed any session memory in-line via
//   `evaluateForTesting` calls (consistent with how existing
//   LanguageDetectorTests work).
//
// Why duplicate `TestClock` / `makeEphemeralDefaults` from
// `LanguageDetectorTests.swift`? Those already exist, but PR 1 keeps R2
// characterization in its own file/namespace so the immutability boundary
// (PR 2 must not edit R2 files) is structurally clean. If both files were
// to share helpers, a PR 2 edit to the shared file could ripple into R2
// assertions without an obvious diff signal.

/// Mutable clock for deterministic tests. Production code uses
/// `SystemLanguageDetectorClock`; tests use this.
final class R2TestClock: LanguageDetectorClock, @unchecked Sendable {
  var current: Date

  init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
    self.current = start
  }

  func now() -> Date { current }

  func advance(_ seconds: TimeInterval) {
    current = current.addingTimeInterval(seconds)
  }
}

/// Per-test UserDefaults suite so tests do not cross-contaminate or pollute
/// the real defaults domain. Each call returns a fresh suite.
func r2EphemeralDefaults(_ suite: String = "R2-" + UUID().uuidString) -> UserDefaults {
  guard let defaults = UserDefaults(suiteName: suite) else {
    fatalError("Failed to create UserDefaults suite '\(suite)' for R2 characterization test")
  }
  return defaults
}

/// Build a `LanguageDetector` with a deterministic clock and isolated
/// UserDefaults. Default starting time is 2023-11-14 — chosen as a fixed
/// epoch that is far from any boundary that could alter timeout behavior.
///
/// Returns the detector and the clock so tests can advance time. The
/// UserDefaults handle is held internally by the detector and not surfaced
/// to avoid Sendable/data-race warnings on the local binding.
func r2MakeDetector(
  startingAt date: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> (LanguageDetector, R2TestClock) {
  let clock = R2TestClock(date)
  let detector = LanguageDetector(clock: clock, defaults: r2EphemeralDefaults())
  return (detector, clock)
}
