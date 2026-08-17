import Foundation
import Testing

@testable import EnviousWisprModelDelivery

/// Guards the assumption the superseded-artefact identification rests on
/// (#2109, #2120).
///
/// `cacheKey` flattens name and revision with no injective boundary, so
/// prefix/suffix parsing can only distinguish models while no name within a
/// family is a prefix of another. Rather than detect that at runtime, it is
/// made impossible to author: the day someone adds a colliding name, this
/// fails.
@Suite struct ShippedModelNamesTests {

  /// THE guard. Runs over every name EVER shipped, not the current bundle,
  /// because staging directories and admission markers outlive app versions:
  /// a build carrying only `eg-1` can still meet leftover `eg-1-mini-*`
  /// entries written by a build that shipped both.
  @Test func noShippedNameIsAPrefixOfAnotherInTheSameFamily() {
    for family in ShippedModelNames.families {
      let names = Array(ShippedModelNames.everShipped(in: family)).sorted()
      for a in names {
        for b in names where a != b {
          #expect(
            b.hasPrefix(a) == false,
            "\(family.rawValue): \"\(a)\" is a prefix of \"\(b)\", so superseded-artefact identification cannot tell them apart and one could delete the other's bytes")
        }
      }
    }
  }

  /// Two-way control. The guard above passes trivially on a list with no
  /// collisions, which is every list we ship — so it proves nothing until it
  /// is shown to REJECT one. This constructs the collision the real registry
  /// must never contain.
  @Test func theGuardRejectsACollidingPair() {
    let colliding = ["eg-1", "eg-1-mini"].sorted()
    var caught = false
    for a in colliding {
      for b in colliding where a != b {
        if b.hasPrefix(a) { caught = true }
      }
    }
    #expect(caught, "the prefix rule cannot detect the collision it exists to forbid")
  }

  /// The registry must not drift from what actually ships. A bundled manifest
  /// naming a model absent from this list means the guard above is reasoning
  /// over a stale set and silently covers less than it appears to.
  @Test func everyBundledManifestIdentityIsRegistered() throws {
    // Read from the repo, not a bundle: these are APP-target resources and are
    // absent from the test bundle. Same approach as the shipped-manifest
    // assertion in `EGOneManifestTests`.
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // ModelDelivery
      .deletingLastPathComponent()  // EnviousWisprTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // repo root
    let resourceDir = repoRoot.appendingPathComponent("Sources/EnviousWispr/Resources")

    for resource in [
      "eg1-delivery-manifest", "parakeet-delivery-manifest",
      "whisperkit-delivery-manifest", "whisperkit-preview-delivery-manifest",
    ] {
      let url = resourceDir.appendingPathComponent("\(resource).json")
      let manifest = try DeliveryManifest.load(from: try Data(contentsOf: url))
      let identity = manifest.identity
      // Checks `current`, deliberately, not `everShipped`: a still-bundled
      // name wrongly moved to `retired` would pass the looser check while the
      // registry claimed we no longer ship it.
      #expect(
        ShippedModelNames.current[identity.family]?.contains(identity.name) == true,
        "\(resource) ships \(identity.family.rawValue)/\(identity.name), which is not in current")
    }
  }

  /// Append-only is a property nothing enforces unless a test names the past
  /// members. The coverage test above detects a MISSING current name; it
  /// cannot detect a DELETED tombstone, and deleting one silently reopens the
  /// historical case the registry exists to close.
  @Test func theHistoricalMinimumIsNeverReduced() {
    let minimum: [ModelFamily: Set<String>] = [
      .egOne: ["eg-1"],
      .parakeet: ["parakeet-tdt-0.6b-v3-coreml"],
      .whisperKit: ["whisperkit-coreml"],
    ]
    // EXACT equality, not containment. Containment would let the registry GROW
    // without this minimum growing with it, so a name added today could be
    // silently deleted tomorrow with nothing failing. Equality forces both to
    // move together, which makes a deletion visible in the diff as a shrinking
    // minimum rather than a one-line removal.
    #expect(ShippedModelNames.families == Set(minimum.keys))
    for family in ShippedModelNames.families {
      #expect(
        ShippedModelNames.everShipped(in: family) == minimum[family, default: []],
        "\(family.rawValue): the registry and its historical minimum disagree; entries are tombstoned, never deleted, because removing one reopens the case it was added to close")
    }
  }

  // MARK: - Variant uniqueness (#2109)

  /// The OTHER assumption the sweep rests on, and the one that nearly bit.
  ///
  /// "Superseded" means same family, same name, SAME VARIANT, different
  /// revision. WhisperKit ships stable and Preview with the same family, the
  /// same name AND the same revision, separated only by variant — so if two
  /// registrations ever differed only by REVISION, the sweep would read one as
  /// a superseded copy of the other and delete an in-flight download.
  ///
  /// The plan's prose originally omitted variant from that definition. The
  /// inherited prefix/suffix mechanism carries it anyway, so the code was
  /// correct by accident of an implementation detail rather than by statement.
  /// This makes the assumption explicit and enforced.
  /// The uniqueness key the sweep's notion of "superseded" depends on.
  /// Revision is deliberately EXCLUDED: two registrations differing only by
  /// revision are exactly the collision that must be forbidden.
  static func uniquenessKey(_ identity: ModelIdentity) -> String {
    [identity.family.rawValue, identity.name, identity.variant].joined(separator: "|")
  }

  /// Returns the first duplicate key, or nil. Shared by the real check and its
  /// control so the control exercises THIS logic rather than a restatement of
  /// it — a control that re-implements the rule proves only that the test file
  /// is self-consistent.
  static func firstCollision(_ keys: [String]) -> String? {
    var seen: Set<String> = []
    for key in keys {
      if seen.contains(key) { return key }
      seen.insert(key)
    }
    return nil
  }

  @Test func noTwoBundledRegistrationsShareFamilyNameAndVariant() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let resourceDir = repoRoot.appendingPathComponent("Sources/EnviousWispr/Resources")

    var keys: [String] = []
    for resource in [
      "eg1-delivery-manifest", "parakeet-delivery-manifest",
      "whisperkit-delivery-manifest", "whisperkit-preview-delivery-manifest",
    ] {
      let url = resourceDir.appendingPathComponent("\(resource).json")
      let identity = try DeliveryManifest.load(from: try Data(contentsOf: url)).identity
      keys.append(Self.uniquenessKey(identity))
    }

    #expect(
      Self.firstCollision(keys) == nil,
      "two bundled manifests share family+name+variant, so the staging sweep would treat one as a superseded revision of the other and delete a live download")
    #expect(keys.count == 4, "expected four bundled registrations, got \(keys.count)")
  }

  /// Two-way control that drives the REAL detector. Every set we ship is
  /// distinct, so the check above passes trivially and proves nothing until
  /// `firstCollision` is shown to FIRE on the shape it forbids.
  ///
  /// The shipped stable and Preview pair differ only by VARIANT and must stay
  /// distinct; two registrations differing only by REVISION collapse to the
  /// same key and must be caught. Both directions asserted, because a key that
  /// caught everything would break Preview and a key that caught nothing would
  /// let the sweep delete a live download.
  @Test func theCollisionDetectorFiresOnRevisionOnlyDifferences() {
    let stable = ModelIdentity(
      family: .whisperKit, name: "whisperkit-coreml", revision: "aaa",
      variant: "openai_whisper-large-v3-v20240930_turbo", runtimeABI: "abi")
    let preview = ModelIdentity(
      family: .whisperKit, name: "whisperkit-coreml", revision: "aaa",
      variant: "openai_whisper-small_216MB", runtimeABI: "abi")
    // Differs from `stable` ONLY by revision: the forbidden shape.
    let stableNewerRevision = ModelIdentity(
      family: .whisperKit, name: "whisperkit-coreml", revision: "bbb",
      variant: "openai_whisper-large-v3-v20240930_turbo", runtimeABI: "abi")

    #expect(
      Self.firstCollision([stable, preview].map(Self.uniquenessKey)) == nil,
      "the shipped stable and Preview pair differ only by variant and must NOT collide")

    #expect(
      Self.firstCollision([stable, stableNewerRevision].map(Self.uniquenessKey)) != nil,
      "two identities differing only by revision must collide, or the sweep could delete a live download")
  }

  // MARK: - Variant suffix safety (whole-diff review)

  /// The staging match ends with `hasSuffix("-\(variant)")`, so a variant that
  /// is a SUFFIX of another is ambiguous in the same way a prefix name is:
  /// sweeping `foo` would also match a directory for `bar-foo` and delete its
  /// resumable bytes. The family+name+variant uniqueness freeze does not catch
  /// it, because those variants genuinely differ.
  @Test func noShippedVariantIsASuffixOfAnotherForTheSameModel() {
    for (key, variants) in ShippedModelNames.variants {
      let sorted = Array(variants).sorted()
      for a in sorted {
        #expect(a.isEmpty == false, "\(key): an empty variant makes the suffix match everything")
        for b in sorted where a != b {
          #expect(
            b.hasSuffix(a) == false,
            "\(key): variant \"\(a)\" is a suffix of \"\(b)\", so a sweep for one would match the other's staging and delete its resumable bytes")
        }
      }
    }
  }

  /// Two-way control, driving the same rule against the collision it forbids.
  @Test func theVariantSuffixRuleRejectsAnOverlappingPair() {
    let colliding = ["foo", "bar-foo"].sorted()
    var caught = false
    for a in colliding {
      for b in colliding where a != b {
        if b.hasSuffix(a) { caught = true }
      }
    }
    #expect(caught, "the suffix rule cannot detect the overlap it exists to forbid")

    // And it must NOT fire on the real shipped WhisperKit pair, which is
    // neither a prefix nor a suffix of the other.
    let shipped = ["openai_whisper-large-v3-v20240930_turbo", "openai_whisper-small_216MB"]
    for a in shipped {
      for b in shipped where a != b {
        #expect(b.hasSuffix(a) == false, "the shipped pair must not be flagged")
      }
    }
  }

  /// The variant registry must not drift from what ships.
  @Test func everyBundledVariantIsRegistered() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let resourceDir = repoRoot.appendingPathComponent("Sources/EnviousWispr/Resources")
    for resource in [
      "eg1-delivery-manifest", "parakeet-delivery-manifest",
      "whisperkit-delivery-manifest", "whisperkit-preview-delivery-manifest",
    ] {
      let url = resourceDir.appendingPathComponent("\(resource).json")
      let identity = try DeliveryManifest.load(from: try Data(contentsOf: url)).identity
      let key = ShippedModelNames.variantKey(family: identity.family, name: identity.name)
      #expect(
        ShippedModelNames.variants[key]?.contains(identity.variant) == true,
        "\(resource) ships variant \(identity.variant) for \(key), which is not registered")
    }
  }
}
