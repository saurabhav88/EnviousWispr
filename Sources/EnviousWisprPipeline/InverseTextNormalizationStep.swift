import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation

/// Deterministic inverse text normalization (spoken-form → written-form) as a post-ASR
/// limb: "two zero three nine five four…" → "203-954-8879", "twenty twenty six" → "2026",
/// "eighty million dollars" → "$80 million". The engine (`InverseTextNormalizer`) won the
/// #145 ITN bake-off; this is the thin pipeline wrapper around it.
///
/// Design contract + parity validation: `docs/feature-requests/issue-145-2026-06-02-itn-swift-port.md`.
///
/// Limb semantics (heart & limbs): never blocks the heart path; on no-op it returns the
/// input context untouched; timeout + failure-isolation are owned by `TextProcessingRunner`
/// via `maxDuration`, matching every other step. Default OFF — placement in the live chain,
/// the settings toggle, and the raw-fallback-floor integration are the founder-gated ship
/// step and are NOT wired in this change.
@MainActor
public final class InverseTextNormalizationStep: TextProcessingStep {
  public let name = "Inverse Text Normalization"

  /// Default OFF until the founder-approved wiring PR binds it through settings.
  public var inverseTextNormalizationEnabled: Bool = false

  public var isEnabled: Bool { inverseTextNormalizationEnabled }

  /// Runner-level safety net. Same budget as `EmojiFormatterStep`; the engine is pure CPU
  /// over short transcripts and benchmarked at p95 ~0.1ms, so this is pure runaway protection.
  public var maxDuration: Duration { .milliseconds(50) }

  private let normalizer: InverseTextNormalizer

  public init(normalizer: InverseTextNormalizer = InverseTextNormalizer()) {
    self.normalizer = normalizer
  }

  public func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
    let input = context.text
    let converted = normalizer.normalize(input)
    if converted == input { return context }

    Task {
      await AppLogger.shared.log(
        "InverseTextNormalization: converted \(input.count)→\(converted.count) chars",
        level: .verbose, category: "Pipeline"
      )
    }

    var ctx = context
    ctx.text = converted
    return ctx
  }
}
