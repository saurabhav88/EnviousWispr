import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprLLM

/// Issue #1073 — `app.launched` `ai_capable` / `ai_enabled` / `hardware` must be
/// derived from a live synchronous snapshot, never a nil/stale cached
/// availability report. These tests lock the snapshot's independence from the
/// cache and the real hardware read.
@Suite("Launch availability snapshot (#1073)")
struct LaunchAvailabilitySnapshotTests {

  /// The exact UserDefaults key the OLD buggy launch path read from
  /// (`AIAvailabilityCoordinator.snapshotKey`).
  private static let cacheKey = "aiDiagnosticsLatestReport"

  @Test("hardware class is real, never \"unknown\"")
  func hardwareClassIsReal() {
    let snap = AppleIntelligenceDiagnosticsService.launchSnapshot()
    #expect(snap.hardwareClass.isEmpty == false)
    #expect(snap.hardwareClass != "unknown")
    // Stable across calls (live sysctl, deterministic).
    let again = AppleIntelligenceDiagnosticsService.launchSnapshot()
    #expect(again.hardwareClass == snap.hardwareClass)
  }

  @Test("snapshot ignores a poisoned cached report (independence from cache)")
  func ignoresPoisonedCachedReport() throws {
    let defaults = UserDefaults.standard
    let original = defaults.data(forKey: Self.cacheKey)
    defer {
      if let original {
        defaults.set(original, forKey: Self.cacheKey)
      } else {
        defaults.removeObject(forKey: Self.cacheKey)
      }
    }

    // Clean-cache baseline.
    defaults.removeObject(forKey: Self.cacheKey)
    let clean = AppleIntelligenceDiagnosticsService.launchSnapshot()

    // Poison the cache with an "available" report carrying a fake hardware class.
    // The synchronous snapshot must ignore it entirely (it reads live gates, not
    // this key) — that is the whole point of the #1073 fix.
    let poisoned = AppleIntelligenceAvailabilityReport(
      overallStatus: .available,
      gates: AIGateSet(
        build: .passed(summary: "fake"),
        runtime: .passed(summary: "fake"),
        eligibility: .passed(summary: "fake"),
        modelAccess: .passed(summary: "fake"),
        functionalProbe: .passed(summary: "fake")),
      failureReasons: [],
      osVersion: "26.0.0",
      hardwareClass: "poisoned-fake-hw")
    let data = try #require(try? JSONEncoder().encode(poisoned))
    defaults.set(data, forKey: Self.cacheKey)

    let afterPoison = AppleIntelligenceDiagnosticsService.launchSnapshot()
    #expect(afterPoison.isCapable == clean.isCapable)
    #expect(afterPoison.isEnabled == clean.isEnabled)
    #expect(afterPoison.hardwareClass == clean.hardwareClass)
    #expect(afterPoison.hardwareClass != "poisoned-fake-hw")
  }

  /// #1572. The whole point of this field is that it is NOT the architecture:
  /// `hardwareClass` reads `arm64` on every Mac we ship to, so it can never
  /// answer "which Macs". Asserting only that the field is populated would pass
  /// on a copy of `hardwareClass`, which is the mistake worth freezing against.
  @Test("device model is the specific machine, not the architecture")
  func deviceModelIsTheMachineNotTheArchitecture() {
    let snap = AppleIntelligenceDiagnosticsService.launchSnapshot()
    #expect(snap.deviceModel.isEmpty == false)
    #expect(
      snap.deviceModel != snap.hardwareClass,
      "device_model must not be a second copy of the architecture")
    // Stable across calls, same as the architecture read.
    #expect(AppleIntelligenceDiagnosticsService.launchSnapshot().deviceModel == snap.deviceModel)
  }

  /// A failed read reports `unknown` rather than an empty string, so it groups
  /// separately in the data instead of merging with every other empty value.
  /// Real hardware answers `hw.model`, so on a healthy machine this is the
  /// model — the assertion accepts either and rejects the empty string, which is
  /// the only genuinely unusable answer.
  @Test("a device model is either a real model string or the explicit unknown")
  func deviceModelIsNeverEmpty() {
    let value = AppleIntelligenceDiagnosticsService.launchSnapshot().deviceModel
    #expect(value == "unknown" || value.contains(","), "saw \(value)")
  }

  @Test("isEnabled implies isCapable")
  func isEnabledImpliesCapable() {
    let snap = AppleIntelligenceDiagnosticsService.launchSnapshot()
    if snap.isEnabled {
      #expect(snap.isCapable == true)
    }
  }

  @Test("deterministic across consecutive calls")
  func deterministicAcrossCalls() {
    let a = AppleIntelligenceDiagnosticsService.launchSnapshot()
    let b = AppleIntelligenceDiagnosticsService.launchSnapshot()
    #expect(a.isCapable == b.isCapable)
    #expect(a.isEnabled == b.isEnabled)
  }
}
