import Foundation
import Testing

@testable import EnviousWisprServices

@MainActor
@Suite("UpdateAvailabilityService (issue #343)")
struct UpdateAvailabilityServiceTests {
  // Each test gets its own ephemeral UserDefaults suite so persistence
  // doesn't bleed between tests or into the host process.
  private static func freshDefaults() -> UserDefaults {
    let suite = "ew.updateBannerTest." + UUID().uuidString
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    return d
  }

  private static func makeUpdate(
    version: String = "2.4.0",
    display: String = "2.4.0",
    critical: Bool = false
  ) -> UpdateAvailabilityService.AvailableUpdate {
    UpdateAvailabilityService.AvailableUpdate(
      versionString: version,
      displayVersion: display,
      buildString: version,
      isCriticalUpdate: critical
    )
  }

  private static func makeService(
    bundle: String = "1.9.4",
    defaults: UserDefaults? = nil
  ) -> (UpdateAvailabilityService, UserDefaults) {
    let d = defaults ?? freshDefaults()
    let s = UpdateAvailabilityService(
      installAction: {},
      defaults: d,
      currentBundleVersion: bundle
    )
    return (s, d)
  }

  // MARK: - State transitions

  @Test("noteAvailable on .none transitions to .available and persists keys")
  func noteAvailableTransitionsAndPersists() {
    let (s, d) = Self.makeService()
    s.noteAvailable(Self.makeUpdate())
    if case .available(let u) = s.state {
      #expect(u.versionString == "2.4.0")
    } else {
      Issue.record("expected .available state, got \(s.state)")
    }
    #expect(d.string(forKey: UpdateAvailabilityService.kPendingVersion) == "2.4.0")
    #expect(d.string(forKey: UpdateAvailabilityService.kPendingBuild) == "2.4.0")
  }

  @Test("noteAvailable with same version is a no-op")
  func sameVersionIsNoOp() {
    let (s, _) = Self.makeService()
    s.noteAvailable(Self.makeUpdate())
    s.dismissForSession()
    #expect(s.dismissedForSession == true)
    s.noteAvailable(Self.makeUpdate())  // re-fire same version
    #expect(s.dismissedForSession == true)  // dismissal preserved
  }

  @Test("noteAvailable with new version resets dismissal when persisted dismissed differs")
  func newVersionResetsDismissal() {
    let (s, _) = Self.makeService()
    s.noteAvailable(Self.makeUpdate(version: "2.4.0"))
    s.dismissForSession()
    s.noteAvailable(Self.makeUpdate(version: "2.4.1"))
    #expect(s.dismissedForSession == false)
  }

  @Test("dismissForSession persists dismissedVersion and keeps state")
  func dismissPersistsAndKeepsState() {
    let (s, d) = Self.makeService()
    s.noteAvailable(Self.makeUpdate())
    s.dismissForSession()
    #expect(d.string(forKey: UpdateAvailabilityService.kDismissedVersion) == "2.4.0")
    if case .available = s.state {
      // ok
    } else {
      Issue.record("state should remain .available after dismissForSession")
    }
  }

  @Test("noteResolved clears pending keys and resets state")
  func noteResolvedClearsKeys() {
    let (s, d) = Self.makeService()
    s.noteAvailable(Self.makeUpdate())
    s.noteResolved(installedVersion: "2.4.0")
    #expect(s.state == .none)
    #expect(d.string(forKey: UpdateAvailabilityService.kPendingVersion) == nil)
    #expect(d.string(forKey: UpdateAvailabilityService.kPendingBuild) == nil)
  }

  // MARK: - Persistence rehydrate

  @Test("init rehydrates .available when pending > current bundle")
  func rehydrateWhenPendingNewer() {
    let d = Self.freshDefaults()
    d.set("2.4.0", forKey: UpdateAvailabilityService.kPendingVersion)
    d.set("2.4.0", forKey: UpdateAvailabilityService.kPendingBuild)
    d.set(Date().timeIntervalSince1970, forKey: UpdateAvailabilityService.kPendingTimestamp)
    let (s, _) = Self.makeService(bundle: "1.9.4", defaults: d)
    if case .available(let u) = s.state {
      #expect(u.versionString == "2.4.0")
    } else {
      Issue.record("expected .available, got \(s.state)")
    }
  }

  @Test("init clears all keys when pending <= current bundle")
  func rehydrateClearsWhenStale() {
    let d = Self.freshDefaults()
    d.set("1.8.0", forKey: UpdateAvailabilityService.kPendingVersion)
    d.set("1.8.0", forKey: UpdateAvailabilityService.kPendingBuild)
    d.set(Date().timeIntervalSince1970, forKey: UpdateAvailabilityService.kPendingTimestamp)
    d.set("1.8.0", forKey: UpdateAvailabilityService.kDismissedVersion)
    let (s, _) = Self.makeService(bundle: "1.9.4", defaults: d)
    #expect(s.state == .none)
    #expect(d.string(forKey: UpdateAvailabilityService.kPendingVersion) == nil)
    #expect(d.string(forKey: UpdateAvailabilityService.kDismissedVersion) == nil)
  }

  @Test("init seeds dismissedForSession when persisted dismissed matches pending")
  func rehydrateSeedsDismissal() {
    let d = Self.freshDefaults()
    d.set("2.4.0", forKey: UpdateAvailabilityService.kPendingVersion)
    d.set("2.4.0", forKey: UpdateAvailabilityService.kPendingBuild)
    d.set(Date().timeIntervalSince1970, forKey: UpdateAvailabilityService.kPendingTimestamp)
    d.set("2.4.0", forKey: UpdateAvailabilityService.kDismissedVersion)
    let (s, _) = Self.makeService(bundle: "1.9.4", defaults: d)
    #expect(s.dismissedForSession == true)
  }

  // MARK: - Pipeline-state guard

  @Test("handlePipelineStateChange(true) cancels grace and clears flag")
  func recordingCancelsGrace() {
    let (s, _) = Self.makeService()
    s.handlePipelineStateChange(isRecording: true)
    #expect(s.inPostRecordingGrace == false)
    #expect(s.isRecording == true)
  }

  @Test("handlePipelineStateChange(false) sets grace; clears after duration")
  func graceClearsAfterDuration() async throws {
    let (s, _) = Self.makeService()
    s.handlePipelineStateChange(isRecording: false)
    #expect(s.inPostRecordingGrace == true)
    await s.waitForPostRecordingGraceForTesting()
    #expect(s.inPostRecordingGrace == false)
  }

  // MARK: - shouldShowBanner predicate

  @Test("shouldShowBanner is false on .none")
  func predicateNone() {
    let (s, _) = Self.makeService()
    #expect(s.shouldShowBanner == false)
  }

  @Test("shouldShowBanner is true on .available with no guards")
  func predicateAvailableHappy() {
    let (s, _) = Self.makeService()
    s.noteAvailable(Self.makeUpdate())
    #expect(s.shouldShowBanner == true)
  }

  @Test("shouldShowBanner is false when dismissed")
  func predicateDismissed() {
    let (s, _) = Self.makeService()
    s.noteAvailable(Self.makeUpdate())
    s.dismissForSession()
    #expect(s.shouldShowBanner == false)
  }

  @Test("shouldShowBanner is false during recording")
  func predicateRecording() {
    let (s, _) = Self.makeService()
    s.noteAvailable(Self.makeUpdate())
    s.handlePipelineStateChange(isRecording: true)
    #expect(s.shouldShowBanner == false)
  }

  @Test("shouldShowBanner is false for critical updates")
  func predicateCritical() {
    let (s, _) = Self.makeService()
    s.noteAvailable(Self.makeUpdate(critical: true))
    #expect(s.shouldShowBanner == false)
  }

  // MARK: - Version comparator

  @Test("compareVersions handles standard semver ordering")
  func versionCompare() {
    let (s, _) = Self.makeService()
    #expect(s.compareVersions("2.4.0", "2.4.1") == -1)
    #expect(s.compareVersions("2.4.1", "2.4.0") == 1)
    #expect(s.compareVersions("2.4.0", "2.4.0") == 0)
    #expect(s.compareVersions("2.4.10", "2.4.9") == 1)  // numeric, not lexical
    #expect(s.compareVersions("3.0.0", "2.99.99") == 1)
  }

  // MARK: - .resolving watchdog

  @Test("triggerInstall flips state to .resolving immediately")
  func triggerInstallResolving() {
    let (s, _) = Self.makeService()
    s.noteAvailable(Self.makeUpdate())
    s.triggerInstall()
    #expect(s.state == .resolving)
  }

  @Test("noteAvailable while .resolving with same version is a no-op")
  func noteAvailableSameVersionDuringResolving() {
    let (s, _) = Self.makeService()
    s.noteAvailable(Self.makeUpdate())
    s.triggerInstall()
    s.noteAvailable(Self.makeUpdate())  // same 2.4.0
    #expect(s.state == .resolving)
  }

  @Test("noteAvailable while .resolving with newer version transitions")
  func noteAvailableNewerVersionDuringResolving() {
    let (s, _) = Self.makeService()
    s.noteAvailable(Self.makeUpdate(version: "2.4.0"))
    s.triggerInstall()
    s.noteAvailable(Self.makeUpdate(version: "2.4.1"))
    if case .available(let u) = s.state {
      #expect(u.versionString == "2.4.1")
    } else {
      Issue.record("expected .available(2.4.1), got \(s.state)")
    }
  }
}
