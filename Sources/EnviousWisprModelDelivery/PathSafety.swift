import Foundation

/// Link-aware path questions the delivery layer asks before it writes or deletes
/// (#2697).
///
/// One owner, because the same three questions were being answered privately in
/// more than one file and a copy that drifts is worse than no check at all. Every
/// comparison here is between `realpath`-resolved paths: comparing unresolved
/// ones would be the same mistake one level down.
enum PathSafety {

  /// Whether `path` is the root itself or sits beneath it. Both arguments must
  /// already be resolved.
  static func contained(_ path: String, in root: String) -> Bool {
    path == root || path.hasPrefix(root + "/")
  }

  /// The closest ancestor of `url` that exists on disk, so containment can be
  /// judged without creating anything first. Creating the parents and validating
  /// afterwards is too late: if an existing component is a symlink,
  /// `createIntermediateDirectories` follows it and has already made directories
  /// on the far side by the time a later guard declines.
  static func nearestExistingAncestor(of url: URL) -> URL? {
    var candidate = url
    let fm = FileManager.default
    while candidate.path != "/" {
      if fm.fileExists(atPath: candidate.path) { return candidate }
      let parent = candidate.deletingLastPathComponent()
      guard parent.path != candidate.path else { break }
      candidate = parent
    }
    return fm.fileExists(atPath: candidate.path) ? candidate : nil
  }

  /// Why a path could not be reached. Three values, because a two-valued answer
  /// is the defect: "absent" and "I could not look" collapse into one `nil`, and
  /// a caller that RECORDS the collapsed value writes down a permanent
  /// conclusion about a directory it never saw.
  enum Reachability: Equatable {
    /// It is not there, and a later launch will find the same.
    case absent
    /// It may well be there; this process could not look. Never durable.
    case unreadable
    /// Some other errno. Treated as `unreadable`, because the safe reading of an
    /// error nobody enumerated is "I could not tell".
    case indeterminate
  }

  /// Whether `url` exists, WITHOUT following a final symlink, and when it does
  /// not, WHY.
  ///
  /// `lstat` rather than `FileManager.fileExists`, which answers `false` for both
  /// absence and a permission failure and hands the caller no way to tell them
  /// apart.
  static func reachability(of url: URL) -> Reachability? {
    var info = stat()
    if lstat(url.path, &info) == 0 { return nil }
    switch errno {
    case ENOENT, ENOTDIR: return .absent
    case EACCES, EPERM: return .unreadable
    default: return .indeterminate
    }
  }

  /// The fully link-resolved path, or nil when it does not resolve.
  ///
  /// `realpath(3)` rather than `URL.resolvingSymlinksInPath()`, which this repo
  /// documents as insufficient for the `/private/tmp` case every
  /// temporary-directory test runs in.
  static func resolvedPath(_ url: URL) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(url.path, &buffer) != nil else { return nil }
    return String(cString: buffer)
  }

  /// Whether `subject`, or the nearest ancestor of it that exists, resolves
  /// inside `root` — or inside the nearest ancestor of `root` that exists.
  ///
  /// **Both sides use the nearest EXISTING ancestor, and the root side is the
  /// half that matters on a first run.** Resolving `root` directly fails when it
  /// has not been created yet, which on a fresh install is every root we are
  /// about to make. A check that answers "unsafe" there refuses the first
  /// migration of every new user — the same first-install regression that broke
  /// #2483 twice, and the reason the fixture for this creates nothing but the
  /// donor.
  ///
  /// It is not weaker where it counts. Nothing that does not exist can be
  /// redirected; a symlink has to BE there to send a write somewhere else, and
  /// an existing redirected component is exactly what the anchor lands on.
  ///
  /// Still fails CLOSED when neither side can be resolved at all.
  static func resolvesInside(_ subject: URL, root: URL) -> Bool {
    guard let rootAnchor = nearestExistingAncestor(of: root),
      let rootPath = resolvedPath(rootAnchor),
      let anchor = nearestExistingAncestor(of: subject),
      let anchorPath = resolvedPath(anchor)
    else { return false }
    return contained(anchorPath, in: rootPath)
  }
}

/// The staging directory a fetch writes through must be somewhere we own
/// (#2697).
///
/// This check used to live inside the donor importer, which made it a side effect
/// of a step that no longer runs here. `ManifestFetchTask` writes into staging
/// with no containment check of its own, and promotion then moves component roots
/// out of whatever staging resolves to, so the check has to survive the importer's
/// removal on its own terms rather than as somebody else's by-product.
enum StagingSafety {

  /// True when the staging directory for this registration is inside the
  /// registration's own metadata directory.
  ///
  /// Deliberately NOT "is it outside the donor". The donor was one dangerous
  /// destination among many; a staging component symlinked to any unrelated
  /// directory is the same defect, and asking the positive question — is it
  /// inside the one place we own — closes the set instead of listing it.
  static func isSafe(staging: URL, metadataDirectory: URL) -> Bool {
    PathSafety.resolvesInside(staging, root: metadataDirectory)
  }
}
