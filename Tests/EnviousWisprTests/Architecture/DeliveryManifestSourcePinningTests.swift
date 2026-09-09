import Foundation
import Testing

/// Every delivery source URL is one of exactly two shapes, and the Hugging Face shape
/// carries its own manifest's immutable commit.
///
/// #2693: `parakeet-delivery-manifest.json` pinned revision `aed0274…` and pointed its
/// backup source at `.../resolve/main/`, a moving branch. On a FIRST INSTALL every
/// component is fetched, so the file upstream had replaced was always in the set and
/// failover always failed. Parakeet is the default engine.
///
/// **Why a folder sweep when `DeliveryManifestTests` already pins three manifests by
/// hand.** Those three stay; each also pins its own repository, variant path and source
/// order. Parakeet had no row, and a hand-written row can only cover the manifest its
/// author was looking at. This one is generated from the FOLDER, so a manifest added
/// tomorrow is covered on arrival.
///
/// **An ALLOWLIST over every source, because four review rounds each found a different
/// spelling that escaped a semantic check.** `contains(revision)` accepted
/// `revision: "main"` beside `.../resolve/main/`. `Character.isHexDigit` is true for
/// fullwidth forms, so 40 `U+FF41`-class characters passed as a commit. Reading
/// `URL.path` hands the decision to Foundation, which percent-decodes before you split,
/// keeps a host's trailing dot and normalises `..`. And a raw `contains("huggingface")`
/// TRIGGER missed `hugg%69ngface.co`, which skipped the source entirely.
///
/// The first three were the pattern; the fourth was the TRIGGER, which is the same defect
/// one level up — deciding whether a rule APPLIES is as open-ended as the rule itself. So
/// there is no trigger any more. **Every source must match one of two anchored patterns
/// over its literal bytes, and anything else FAILS.** A new host, a percent-encoded one,
/// a homoglyph, an unpinned Hugging Face URL: none of them need to be recognised, because
/// none of them match. Adding a genuinely new CDN is a deliberate edit here, which is the
/// point rather than a cost.
///
/// **Falsification, published so closure is a claim rather than a hope:** a further
/// finding of ANY URL spelling that this suite accepts and should not means the patterns
/// are deleted in favour of a literal per-source string table. Findings on discovery
/// (which manifests are read) or vacuity (whether anything was checked) are different
/// questions.
///
/// **Network-free by design.** This proves URL shape, never availability and never the
/// bytes a source serves. Byte verification belongs in the PR that changes a revision.
///
/// Fails closed: no manifests found, a manifest with no `sources`, an empty `sources`, a
/// source matching neither pattern, and zero Hugging Face sources in the whole folder.
@Suite("Delivery manifests pin every Hugging Face source (#2693)", .tags(.driftGuard))
struct DeliveryManifestSourcePinningTests {

  private struct Manifest: Decodable {
    struct Identity: Decodable { let revision: String }
    struct Source: Decodable {
      let id: String
      let baseURL: String
    }
    let identity: Identity?
    let sources: [Source]?
  }

  /// Resolved through `RepoRoot`, never a fixed-depth trim of `#filePath`: this
  /// worktree lives under `/private/tmp`, where `/tmp` being a symlink perturbs a
  /// component count (#1675).
  private static var resourcesDirectory: URL {
    RepoRoot.sourceURL("Sources/EnviousWispr/Resources")
  }

  /// Every `*-delivery-manifest.json`, with its repo-relative path.
  ///
  /// An empty or unreadable directory would make every assertion below vacuously
  /// true, which is the shape where a guard stops guarding with nothing going red.
  private static func deliveryManifests() throws -> [(path: String, manifest: Manifest)] {
    let dir = resourcesDirectory
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
      .filter { $0.hasSuffix("-delivery-manifest.json") }
      .sorted()
    try #require(
      !names.isEmpty,
      "no *-delivery-manifest.json found under \(dir.path) — the guard has lost its subject")
    return try names.map { name in
      let data = try Data(contentsOf: dir.appendingPathComponent(name))
      return (
        "Sources/EnviousWispr/Resources/\(name)",
        try JSONDecoder().decode(Manifest.self, from: data)
      )
    }
  }

  /// One path segment: opens with an alphanumeric, so `..` is unrepresentable, and `%`
  /// is outside the class, so percent-encoding is unrepresentable.
  private static let segment = "[A-Za-z0-9][A-Za-z0-9._-]*"

  /// An explicit ASCII set, never `Character.isHexDigit`, which is TRUE for fullwidth
  /// forms — `U+FF41` reports `isHexDigit == true` and `isUppercase == false`.
  private static let asciiHexDigits = Set("0123456789abcdef")

  private static func isFullCommitSHA(_ revision: String) -> Bool {
    revision.count == 40 && revision.allSatisfy { asciiHexDigits.contains($0) }
  }

  /// Our own mirror. Revision-scoping is per-family and not asserted here; the sibling
  /// suites own that.
  private static var mirrorPattern: String {
    "^https://models\\.enviouslabs\\.co/(\(segment)/)+$"
  }

  /// `https://huggingface.co/<owner>/<repo>/resolve/<revision>/[<path>/]*`. The revision
  /// is interpolated only after `isFullCommitSHA`, so it carries no regex metacharacter.
  private static func huggingFacePattern(revision: String) -> String {
    "^https://huggingface\\.co/\(segment)/\(segment)/resolve/\(revision)/(\(segment)/)*$"
  }

  private static func matches(_ pattern: String, _ value: String) -> Bool {
    guard let regex = try? Regex(pattern) else { return false }
    return (try? regex.wholeMatch(in: value)) != nil
  }

  @Test("every delivery source is our mirror or a commit-pinned Hugging Face URL")
  func everySourceMatchesAnAllowedShape() throws {
    var huggingFaceSourcesSeen = 0
    for (path, manifest) in try Self.deliveryManifests() {
      // A manifest with no sources, or none listed, is a failure rather than a skip: the
      // production loader rejects it, and skipping lets a new manifest hide behind the
      // others.
      let sources = try #require(manifest.sources, "\(path): declares no sources")
      try #require(!sources.isEmpty, "\(path): declares an empty sources list")

      for source in sources {
        if Self.matches(Self.mirrorPattern, source.baseURL) { continue }

        // Everything that is not our mirror must be a pinned Hugging Face URL. There is
        // no test for whether it "looks like" Hugging Face — that decision is what the
        // fourth review round escaped.
        let revision = try #require(
          manifest.identity?.revision,
          "\(path): source '\(source.id)' is not our mirror and the manifest declares no identity.revision, so nothing can pin it"
        )
        guard Self.isFullCommitSHA(revision) else {
          Issue.record(
            "\(path): identity.revision '\(revision)' must be 40 lowercase ASCII hex characters; a tag or a branch name can move"
          )
          continue
        }
        let pinned = Self.huggingFacePattern(revision: revision)
        #expect(
          Self.matches(pinned, source.baseURL),
          "\(path): source '\(source.id)' baseURL \(source.baseURL) matches neither \(Self.mirrorPattern) nor \(pinned). A source outside both shapes is either an unpinned ref — which fetches whatever upstream pushed since, so a first install's failover dies on integrity_mismatch (#2693) — or a host nobody has reviewed. Add it here deliberately."
        )
        if Self.matches(pinned, source.baseURL) { huggingFaceSourcesSeen += 1 }
      }
    }
    #expect(
      huggingFaceSourcesSeen > 0,
      "no pinned Hugging Face source was found in the whole folder — this guard passed without guarding anything"
    )
  }
}
