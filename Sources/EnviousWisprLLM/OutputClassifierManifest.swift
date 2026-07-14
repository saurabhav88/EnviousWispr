import EnviousWisprCore
import Foundation

/// Canonical constants for the on-device output-safety classifier (#832/#913 PR8).
///
/// The classifier is the Phase-3 winner: a MiniLM-L6 cross-encoder (seed 13)
/// that scores an (instruction, polished-output) pair and flags cases where
/// Apple Intelligence composed an artifact instead of cleaning the dictation.
///
/// Provenance (durable artifact tree, not committed here):
///   `~/Developer/EnviousLabs/EnviousWispr-artifacts/issue-832-classifier-probe/`
///   - model:     `phase3-models/MiniLM-L6-reformat2-13/fixed.mlpackage` (#949 retrain)
///   - tokenizer: `phase2-models/MiniLM-L6-13/checkpoint-best/{tokenizer.json,tokenizer_config.json}`
///     (UNCHANGED — same base; tokenizer folder + contract not re-shipped)
///   - threshold: `phase2-models/MiniLM-L6-reformat2-13/eval.json` → `T_clf`
///
/// #949 retrain (2026-06-02): same MiniLM-L6 seed 13, fine-tuned one gentle epoch
/// (lr 2e-5) on the v5 corpus + ~3.1k synthesized faithful-reformat KEEP pairs and
/// adversarial unfaithful-reformat DISCARD pairs, so faithful contact-block reformats
/// (phone/date/address) score KEEP instead of being discarded as composed. No-regression
/// gates green: locked-test discard-recall 98.67% (floor 98.5%; shipped 98.89%), KEEP
/// FPR-95 2.77%, reformat false-discard 67.5% → 3.0%, Core ML drift 0 band-flips.
///
/// The model ships as `OutputClassifier.mlpackage` in the APP bundle's
/// `Contents/Resources` (an app-target folder reference) and is compiled to a
/// `.mlmodelc` on-device at prewarm. See the PR8 runbook refresh addendum for
/// why the compile is load-time rather than build-time (Tuist `.mlpackage`
/// build-phase limitation).
public enum OutputClassifierManifest {
  public static let modelName = "MiniLM-L6"
  public static let modelSeed = 13

  /// Resource names in `Bundle.main.resourceURL`. Xcode compiles the committed
  /// source `.mlpackage` into `.mlmodelc` at build time, so the runtime loads
  /// the compiled model (the `.mlpackage` is the defensive fallback only).
  public static let compiledModelName = "OutputClassifier.mlmodelc"
  public static let mlpackageName = "OutputClassifier.mlpackage"
  public static let tokenizerFolderName = "OutputClassifierTokenizer"
  public static let contractFileName = "tokenizer-contract.json"

  /// Sigmoid-probability threshold: probability >= this ⇒ DISCARD (fall back to
  /// raw transcript). Sourced from the trained checkpoint's `eval.json` `T_clf`.
  /// #949: re-swept on the reformat-augmented dev (max discard-recall @ KEEP FPR-95
  /// ≤ 3%), down from 0.10498441010713577 — the lower threshold keeps faithful
  /// reformats (the #949 case scores 0.025) while holding hallucination recall.
  public static let discardThreshold = 0.08155437558889389

  /// Fixed Core ML tensor shape locked at Phase 3 (NOT `model_max_length=512`).
  public static let maxLength = 128

  // Pair-encoding budgets (mirror of the Python `PairDataset`; see
  // `PairEncodingAdapter`). Authoritative copy also lives in the shipped
  // `tokenizer-contract.json`; these constants are the in-code source of truth
  // used when no contract override applies.
  public static let padTokenID = 0
  public static let clsTokenID = 101
  public static let sepTokenID = 102
  public static let specialsBudget = 4
  public static let inputHeadTokens = 64
  public static let inputTailTokens = 32
  public static let minOutputTokens = 32
  public static let segmentVocabSize = 2

  /// Core ML I/O contract (verified at load; mismatch ⇒ fail open).
  public static let inputIDsFeature = "input_ids"
  public static let attentionMaskFeature = "attention_mask"
  public static let tokenTypeIDsFeature = "token_type_ids"
  public static let logitsFeature = "logits"

  /// Build-time integrity anchors (verified by `OutputClassifierResourceTests`
  /// against the committed sources, NOT at runtime — the runtime artifact is a
  /// compiled `.mlmodelc` whose bytes differ from the source `.mlpackage`).
  /// `mlpackageSHA256` = sha256 over sorted "<relpath> <filesha256>" lines of
  /// the committed `OutputClassifier.mlpackage` directory.
  public static let mlpackageSHA256 =
    "0770ab0559ac90f95358a85a19845fa2745fc182ab06637ecb005b52d7bdce2d"
  /// The shipped `tokenizer-contract.json` `contractHash` (canonical contract
  /// bytes ++ tokenizer.json ++ tokenizer_config.json). Recomputed and verified
  /// at runtime; mismatch ⇒ classifier disabled, fail open.
  public static let tokenizerContractSHA256 =
    "49366fbd8c05093ef90433a737f67d2f0fc3664cfe2a0309ba48c4dd5811ab22"
}

/// Why the classifier was disabled for an app run (telemetry only — never
/// carries raw text or tokens).
public enum OutputClassifierDisabledReason: String, Sendable {
  case contractHashMismatch = "contract_hash_mismatch"
  case missingFile = "missing_file"
  case unsupportedFamily = "unsupported_family"
  case fixtureSelfTestFailed = "fixture_selftest_failed"
  case shapeMismatch = "shape_mismatch"
  case inferenceError = "inference_error"
  case tokenizerLoadFailed = "tokenizer_load_failed"
  case modelLoadFailed = "model_load_failed"
}

/// Typed load/score failures. All map to fail-open at the call site.
public enum OutputClassifierError: Error, Sendable, CustomStringConvertible {
  case disabled(OutputClassifierDisabledReason)

  public var reason: OutputClassifierDisabledReason {
    switch self {
    case let .disabled(r): return r
    }
  }
  public var description: String { "OutputClassifier disabled: \(reason.rawValue)" }
}

// MARK: - Sentry identity

/// Pins the case's Sentry grouping key to the exact string it has been
/// sending in production, so the identity survives any future add/remove of
/// a case (#1525 PR D; mirrors `HeartPathError`/`ModelLoadWatchdog.WedgeError`).
///
/// The descriptor below is NOT derived — it was MEASURED against shipping
/// code and cross-checked against the live Sentry issue titles
/// (`docs/audits/2026-07-14-1525-pr-d-preflight.md`). Only one case exists
/// today, so the associated `OutputClassifierDisabledReason` never enters
/// this descriptor — it splits Sentry issues only via `fingerprintDetail`
/// (the reason's raw value), passed separately at the capture site.
///
/// NEVER change this shipped `sentryFingerprintDescriptor`: it would split
/// this error's 3 existing production Sentry issues in two. A NEW case gets
/// a fresh unused string, never `#0`. The switch is exhaustive, so a new case
/// cannot compile until it declares an identity — the same guardrail
/// `HeartPathError` uses.
extension OutputClassifierError: StableSentryErrorIdentity {
  public var sentryFingerprintDescriptor: String {
    switch self {
    case .disabled: return "EnviousWisprLLM.OutputClassifierError#0"
    }
  }

  public var sentrySemanticID: String {
    switch self {
    case .disabled: return "outputclassifier.disabled"
    }
  }
}
