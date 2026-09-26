import Foundation

/// The model families the delivery layer can move bytes for (epic #1348).
/// Ollama is deliberately absent: its daemon owns bytes; our scope there is
/// telemetry only (contract scope guardrails).
public enum ModelFamily: String, Codable, Sendable, CaseIterable {
  case parakeet
  case whisperKit = "whisper_kit"
  case egOne = "eg_one"
  /// #3105: independently admitted companion, never a member of EG-1's
  /// exhaustive shard set or its revision cleanup.
  case egOneChecker = "eg_one_checker"
  /// #2649: S1-mini, a third-party ASR-output normalizer served by the same
  /// bundled llama-server as EG-1. A SEPARATE family, not an EG-1 variant:
  /// folding someone else's weights into the `eg_one` identity would put them
  /// behind our first-party name in the delivery manifest, the admission
  /// marker and telemetry.
  case s1Mini = "s1_mini"
  /// #996 phase D: the learn-from-edits correction judge, a Core ML
  /// cross-encoder we trained (`xenc-mmbert-small`). Its own family because
  /// it is our own weights with our own examined revision, delivered as a
  /// self-contained folder (package, tokenizer, contract) that
  /// `CoreMLCorrectionJudge` loads; nothing about it is an ASR or polish
  /// engine, so it shares no other family's marker, folder or kill switch.
  case editJudge = "edit_judge"
  /// #3105: S1-mini's learned-word checker (D5), a LoRA adapter admitted on
  /// its own like `egOneChecker`, never a member of S1-mini's shard set.
  case s1MiniChecker = "s1_mini_checker"

  /// The base family a checker adapter runs on; nil for a family that is not
  /// a checker. Exhaustive, so a new family must say whether it is one.
  public var checkerBaseFamily: ModelFamily? {
    switch self {
    case .egOneChecker: .egOne
    case .s1MiniChecker: .s1Mini
    case .parakeet, .whisperKit, .egOne, .s1Mini, .editJudge: nil
    }
  }
}

/// Canonical identity of one deliverable model (contract §3, D2 §1).
///
/// `revision` is the BYTE pin (upstream commit SHA / our version tag);
/// `runtimeABI` is the CODE pin (the runtime build the bytes were validated
/// against). They move independently — #1339's existence proof: the FluidAudio
/// code pin and HF model revision advance independently. `runtimeABI` is part
/// of the manifest's canonical JSON, so changing it changes `manifestDigest`.
/// Existing bytes are revalidated once and re-admitted without re-download;
/// the delivery layer still never loads or compiles the runtime (invariant 9).
public struct ModelIdentity: Hashable, Codable, Sendable {
  public let family: ModelFamily
  public let name: String
  public let revision: String
  public let variant: String
  public let runtimeABI: String

  public init(
    family: ModelFamily, name: String, revision: String, variant: String, runtimeABI: String
  ) {
    self.family = family
    self.name = name
    self.revision = revision
    self.variant = variant
    self.runtimeABI = runtimeABI
  }

  /// Filesystem-safe key for staging dirs, admission markers, and telemetry
  /// joins: `family/name-revision-variant` flattened. Revision is included so
  /// a pin bump can never alias the previous revision's marker (D2 §3 — for
  /// the shared FluidAudio install dir the marker, not the path, carries the
  /// revision binding).
  public var cacheKey: String {
    let variantSuffix = variant.isEmpty ? "" : "-\(variant)"
    return "\(family.rawValue)-\(name)-\(revision)\(variantSuffix)"
  }
}
