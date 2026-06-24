import Foundation

/// #1178 (Telemetry Bible Phase 9, B3): buckets how far a user's installed version is
/// behind the latest available release, for the `version_staleness_bucket` property on
/// `update.sparkle_cycle_finished`.
///
/// An EXACT "releases behind" count is NOT derivable — the appcast lists only the latest
/// item, not the intermediate versions — so this projects the delta to a low-cardinality,
/// semver-meaningful bucket. It OWNS the parse/compare (Codex grounded review r3: do not
/// spawn a second comparator unrelated to `UpdateAvailabilityService.compareVersions`;
/// this is the pure, self-contained version, mirroring that comparator's split-by-dot int
/// parse — non-integer components count as 0). Pure + content-free.
public enum VersionStaleness {
  /// `on_latest` when `current >= latest` (including a dev/beta build AHEAD of the feed —
  /// never reports "behind" for an ahead build). Otherwise the highest-order component
  /// that differs: `major_behind` / `minor_behind` / `patch_behind`.
  public static func bucket(current: String, latest: String) -> String {
    let c = parse(current)
    let l = parse(latest)
    if compare(c, l) >= 0 { return "on_latest" }
    if l.major > c.major { return "major_behind" }
    if l.minor > c.minor { return "minor_behind" }
    return "patch_behind"
  }

  /// Split-by-dot integer parse (production tags are `^\d+\.\d+\.\d+$` per release.yml).
  /// Malformed / pre-release / non-integer components parse to 0 (e.g. `"2.1.4-beta"` →
  /// `(2, 1, 0)`, `"abc"` → `(0, 0, 0)` → buckets as the worst case, `major_behind`).
  private static func parse(_ v: String) -> (major: Int, minor: Int, patch: Int) {
    let parts = v.split(separator: ".").map { Int($0) ?? 0 }
    return (
      parts.count > 0 ? parts[0] : 0,
      parts.count > 1 ? parts[1] : 0,
      parts.count > 2 ? parts[2] : 0
    )
  }

  private static func compare(
    _ a: (major: Int, minor: Int, patch: Int), _ b: (major: Int, minor: Int, patch: Int)
  ) -> Int {
    if a.major != b.major { return a.major < b.major ? -1 : 1 }
    if a.minor != b.minor { return a.minor < b.minor ? -1 : 1 }
    if a.patch != b.patch { return a.patch < b.patch ? -1 : 1 }
    return 0
  }
}
