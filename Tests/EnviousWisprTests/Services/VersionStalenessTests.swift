import Testing

@testable import EnviousWisprServices

/// #1178 (Telemetry Bible Phase 9, B3): the version-staleness bucket. Boundary cases
/// per the Codex grounded review (equal, ahead, each delta order, malformed, pre-release,
/// differing component counts, numeric compare).
@Suite("VersionStaleness bucket")
struct VersionStalenessTests {

  @Test("equal versions report on_latest")
  func equalIsOnLatest() {
    #expect(VersionStaleness.bucket(current: "2.1.4", latest: "2.1.4") == "on_latest")
  }

  @Test("a build AHEAD of the feed reports on_latest, never behind")
  func aheadIsOnLatest() {
    // dev/beta ahead of the public feed — must never report "behind"
    #expect(VersionStaleness.bucket(current: "2.2.0", latest: "2.1.4") == "on_latest")
    #expect(VersionStaleness.bucket(current: "3.0.0", latest: "2.9.9") == "on_latest")
  }

  @Test("a patch behind reports patch_behind")
  func patchBehind() {
    #expect(VersionStaleness.bucket(current: "2.1.3", latest: "2.1.4") == "patch_behind")
    #expect(VersionStaleness.bucket(current: "2.1.0", latest: "2.1.9") == "patch_behind")
  }

  @Test("a minor behind reports minor_behind")
  func minorBehind() {
    #expect(VersionStaleness.bucket(current: "2.0.9", latest: "2.1.0") == "minor_behind")
    #expect(VersionStaleness.bucket(current: "2.0.0", latest: "2.4.1") == "minor_behind")
  }

  @Test("a major behind reports major_behind")
  func majorBehind() {
    #expect(VersionStaleness.bucket(current: "1.9.9", latest: "2.0.0") == "major_behind")
    #expect(VersionStaleness.bucket(current: "1.0.0", latest: "3.2.1") == "major_behind")
  }

  @Test("numeric (not lexical) component compare: 2.4.10 is newer than 2.4.9")
  func numericComponentCompare() {
    #expect(VersionStaleness.bucket(current: "2.4.9", latest: "2.4.10") == "patch_behind")
    #expect(VersionStaleness.bucket(current: "2.4.10", latest: "2.4.9") == "on_latest")
  }

  @Test("differing component counts: 2.1 vs 2.1.4")
  func differingComponentCounts() {
    // 2.1 parses as (2,1,0) → one patch behind 2.1.4
    #expect(VersionStaleness.bucket(current: "2.1", latest: "2.1.4") == "patch_behind")
    #expect(VersionStaleness.bucket(current: "2.1.4", latest: "2.1") == "on_latest")
  }

  @Test("malformed / non-semver current parses to zeros (worst case, major_behind)")
  func malformedCurrent() {
    #expect(VersionStaleness.bucket(current: "abc", latest: "2.1.4") == "major_behind")
    #expect(VersionStaleness.bucket(current: "", latest: "2.1.4") == "major_behind")
  }

  @Test("pre-release suffix on a component parses that component to zero")
  func preReleaseSuffix() {
    // "2.1.4-beta" → (2,1,0) (the "4-beta" component is non-integer → 0) → vs 2.1.4 = patch_behind.
    #expect(VersionStaleness.bucket(current: "2.1.4-beta", latest: "2.1.4") == "patch_behind")
  }
}
