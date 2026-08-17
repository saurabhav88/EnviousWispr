import Foundation

/// Every model NAME this app has ever shipped, per family, including retired
/// ones (#2109, #2120).
///
/// WHY THIS EXISTS. Superseded artefacts are identified by stripping a known
/// prefix and suffix from a `cacheKey`, because `cacheKey` flattens name and
/// revision with no injective boundary: `name=foo, revision=bar-baz` and
/// `name=foo-bar, revision=baz` produce the same string. That technique is
/// sound only while no model name within a family is a PREFIX of another —
/// otherwise one model's artefacts can be read as a superseded revision of a
/// different model, and the consequence is deleting the wrong bytes.
///
/// WHY EVER-SHIPPED AND NOT THE CURRENT BUNDLE. Staging directories and
/// admission markers OUTLIVE app versions. A guard checking only today's
/// manifests proves nothing about a directory written by a build from last
/// year: ship `eg-1-mini`, retire it, and a later build carrying only `eg-1`
/// passes a current-bundle check while its parser can still misread the
/// leftover `eg-1-mini-*` entries. This list is therefore APPEND-ONLY —
/// entries are tombstoned, never removed, because removing one silently
/// reopens exactly the case it was added to close.
///
/// This is data with no runtime reader by design. Its only consumer is a
/// freeze test. Making it a lookup consulted at runtime would turn it into a
/// second source of truth that could drift from the manifests themselves.
enum ShippedModelNames {
  /// Currently shipped. Must stay in step with the bundled manifests; a test
  /// asserts every bundled identity appears here.
  static let current: [ModelFamily: Set<String>] = [
    .egOne: ["eg-1"],
    .parakeet: ["parakeet-tdt-0.6b-v3-coreml"],
    .whisperKit: ["whisperkit-coreml"],
  ]

  /// Names shipped by an earlier build and no longer bundled. Empty today —
  /// no model name has ever been retired. It is declared anyway so that
  /// retiring one has an obvious home, rather than the name simply vanishing
  /// from `current` and taking its guard with it.
  static let retired: [ModelFamily: Set<String>] = [:]

  /// The union, which is what the prefix-safety guard must reason over.
  static func everShipped(in family: ModelFamily) -> Set<String> {
    (current[family] ?? []).union(retired[family] ?? [])
  }

  static var families: Set<ModelFamily> {
    Set(current.keys).union(retired.keys)
  }

  /// Every VARIANT ever shipped, keyed by family and name (#2109, whole-diff
  /// review).
  ///
  /// The staging match ends with `hasSuffix("-\(variant)")`, which is
  /// ambiguous in exactly the same way the name prefix is: sweeping variant
  /// `foo` also matches a directory for variant `bar-foo`, and the
  /// family+name+variant uniqueness freeze permits that pair because the
  /// variants ARE different. So an unrelated model's resumable bytes could be
  /// deleted. An EMPTY variant is worse still — the suffix becomes the empty
  /// string and matches everything in the family.
  ///
  /// Frozen for the same reason as the names: make the collision impossible to
  /// author rather than detectable after the deletion.
  static let variants: [String: Set<String>] = [
    "eg_one|eg-1": ["q5km"],
    "parakeet|parakeet-tdt-0.6b-v3-coreml": ["int8"],
    "whisper_kit|whisperkit-coreml": [
      "openai_whisper-large-v3-v20240930_turbo", "openai_whisper-small_216MB",
    ],
  ]

  static func variantKey(family: ModelFamily, name: String) -> String {
    "\(family.rawValue)|\(name)"
  }
}
