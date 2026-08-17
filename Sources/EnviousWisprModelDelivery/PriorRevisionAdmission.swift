import Foundation

/// Reads the admission markers of OTHER revisions of the same model (#2096).
///
/// This module owns the admission-marker FORMAT, so reading it lives here. The POLICY of what
/// to do about a superseded revision — whether to fetch, when to defer, what a decline means —
/// stays in the owning family's coordinator, which is the only place that knows it. Nothing in
/// this type decides anything; it answers two questions about files on disk.
///
/// Markers are named `<cacheKey>.admission.json` and share ONE metadata directory across every
/// family, so identification must be exact. `cacheKey` is
/// `family-name-revision[-variant]` and BOTH `name` and `revision` may contain hyphens
/// (`eg_one-eg-1-v3-eg2-q5km`), so the revision cannot be recovered by splitting on `-`.
/// Instead the known-constant prefix and suffix are stripped: everything between
/// `family-name-` and `[-variant].admission.json` is the revision, whatever it contains.
public enum PriorRevisionAdmission {

  /// Markers in `metadataDirectory` for the same `family` AND `name` as `identity`, at a
  /// DIFFERENT revision. Empty when the directory cannot be read — the caller treats an
  /// unreadable metadata directory as "no prior revision", which fails closed (no download).
  /// Internal: only `supersededInstallSurvives` is needed across modules, and chunk 4's marker
  /// cleanup lives in this same module. Keeping the public surface to exactly one function.
  static func markerURLs(for identity: ModelIdentity, metadataDirectory: URL) -> [URL] {
    let prefix = "\(identity.family.rawValue)-\(identity.name)-"
    let suffix =
      identity.variant.isEmpty ? ".admission.json" : "-\(identity.variant).admission.json"
    let current = "\(identity.cacheKey).admission.json"

    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: metadataDirectory, includingPropertiesForKeys: nil)
    else { return [] }

    return entries.filter { url in
      let name = url.lastPathComponent
      guard name != current, name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
      // A degenerate identity could make prefix and suffix overlap in a short name and admit a
      // file that is neither. Require a non-empty revision segment between them.
      return name.count > prefix.count + suffix.count
    }
  }

  /// Staging directories in `metadataDirectory/staging` belonging to the same
  /// `family`, `name` AND `variant` as `identity`, at a DIFFERENT revision
  /// (#2109, #2119).
  ///
  /// Same prefix/suffix stripping as `markerURLs`, and for the same reason:
  /// `cacheKey` flattens name and revision with no injective boundary, so the
  /// revision cannot be recovered by splitting on `-`. Its soundness rests on
  /// no model name within a family being a prefix of another, which
  /// `ShippedModelNames` freezes over every name ever shipped.
  ///
  /// VARIANT IS PART OF THE MATCH, not an afterthought. WhisperKit ships
  /// stable and Preview with the same family, name and revision, separated
  /// only by variant; if two registrations ever differed only by REVISION,
  /// one would be read as a superseded copy of the other and a live download
  /// would be deleted. `ShippedModelNamesTests` freezes that too.
  ///
  /// Empty when the directory cannot be read — the caller then deletes
  /// nothing, which is the only safe answer to "I could not look".
  static func supersededStagingURLs(for identity: ModelIdentity, metadataDirectory: URL) -> [URL] {
    let staging = metadataDirectory.appendingPathComponent("staging", isDirectory: true)
    let prefix = "\(identity.family.rawValue)-\(identity.name)-"
    let suffix = identity.variant.isEmpty ? "" : "-\(identity.variant)"
    let current = identity.cacheKey

    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: staging, includingPropertiesForKeys: [.isDirectoryKey])
    else { return [] }

    return entries.filter { url in
      let name = url.lastPathComponent
      guard name != current, name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
      // Require a non-empty revision segment between prefix and suffix, so a
      // degenerate identity whose two ends overlap cannot admit an entry that
      // is neither. Mirrors the same guard in `markerURLs`.
      guard name.count > prefix.count + suffix.count else { return false }
      // DIRECTORIES ONLY. Staging is always a directory; a regular file whose
      // name happens to match would otherwise be deleted as if it were one.
      // The caller removes whatever this returns, so a name match alone is not
      // enough to authorise deletion.
      guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
        values.isDirectory == true
      else { return false }
      return true
    }
  }

  /// True when a prior revision was admitted AND at least one file it recorded is STILL on disk.
  ///
  /// The marker alone proves an install once completed, never that its bytes survive: a user who
  /// reclaimed space in Finder or with a cleaner tool must not have gigabytes re-fetched unasked.
  /// This is a `stat` per recorded file with no hashing — it answers "is there something left to
  /// supersede", not "is it valid".
  ///
  /// Fails closed in every direction: an unreadable directory, an undecodable marker, a marker
  /// recording no files, or files that are all gone all yield `false`, and `false` means no
  /// automatic download.
  public static func supersededInstallSurvives(
    identity: ModelIdentity, metadataDirectory: URL, installDirectory: URL
  ) -> Bool {
    let fm = FileManager.default
    for markerURL in markerURLs(for: identity, metadataDirectory: metadataDirectory) {
      guard let data = try? Data(contentsOf: markerURL),
        let marker = try? JSONDecoder().decode(CacheAdmission.AdmissionMarker.self, from: data),
        !marker.files.isEmpty
      else { continue }

      for stamp in marker.files
      where fm.fileExists(atPath: installDirectory.appendingPathComponent(stamp.path).path) {
        return true
      }
    }
    return false
  }
}
