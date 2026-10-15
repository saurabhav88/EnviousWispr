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
  /// Currently offered for delivery. Must stay in step with the bundled
  /// delivery manifests; a test asserts every bundled identity appears here or,
  /// for a validation-only manifest, in `retired`.
  static let current: [ModelFamily: Set<String>] = [
    .editJudge: ["xenc-mmbert-small"],
    .egOne: ["eg-1"],
    .egOneChecker: ["eg1c"],
    .parakeet: ["parakeet-ultra-coreml"],
    .s1Mini: ["s1-mini"],
    .s1MiniChecker: ["s1c"],
    .whisper: ["whisper-large-v3-turbo-gguf", "whisper-small-gguf"],
    .wordCheck: ["kev-wc"],
  ]

  /// Historical models no longer offered for delivery. Their validation-only
  /// manifests may remain bundled for migration and acceptance. #3735: the retired
  /// `whisper_kit` family is absent with its `ModelFamily` case; no registration or
  /// per-family sweep can exist for it, and `WhisperModelMigration` recognizes its
  /// leftovers by literal name.
  static let retired: [ModelFamily: Set<String>] = [
    .parakeet: ["parakeet-tdt-0.6b-v3-coreml"],
  ]

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
    "edit_judge|xenc-mmbert-small": ["fp16"],
    "eg_one|eg-1": ["q5km"],
    "eg_one_checker|eg1c": ["f16"],
    "parakeet|parakeet-tdt-0.6b-v3-coreml": ["int8"],
    "parakeet|parakeet-ultra-coreml": ["int8"],
    "s1_mini|s1-mini": ["q4km"],
    "s1_mini_checker|s1c": ["f16"],
    "whisper|whisper-large-v3-turbo-gguf": ["q8_0"],
    "whisper|whisper-small-gguf": ["q8_0"],
    "word_check|kev-wc": ["mlx-q4", "mlx-q5-embed-q4"],
  ]

  static func variantKey(family: ModelFamily, name: String) -> String {
    "\(family.rawValue)|\(name)"
  }
}
