import Foundation

// Moved here from `EnviousWisprPipeline` (#2087 chunk 11). The pipeline
// PRODUCES these outcomes and `EnviousWisprServices` REPORTS them, and
// Services does not depend on Pipeline — so the vocabulary had to live in the
// module both share, or be duplicated. A second copy plus a freeze test was
// the alternative and is strictly worse: two definitions that agree today are
// two definitions that can disagree, and the telemetry label is the thing a
// dashboard reads months later.

/// Distinguished rather than collapsed into success/failure because the four
/// non-saved endings are not one thing: `abandoned` is a choice the user made,
/// `empty` is a recording with no speech in it, and only `transcriptionFailed`
/// and `saveFailed` are faults of ours. A boolean would report all four as
/// failures and make the feature look broken to whoever reads the data.
// RAW VALUES ARE THE WIRE FORMAT and are spelled explicitly for that reason.
// Swift's default derives the label from the case NAME, which produced
// `transcriptionFailed` where the approved schema says `transcription_failed`
// — a rename away from a silently split series, and invisible until a
// dashboard comes up empty.
public enum EscapeRecoveryTerminalOutcome: String, Equatable, Sendable, CaseIterable {
  /// Text was durably written. The ONLY outcome that may present a pill, because
  /// the pill is an offer to restore something that exists. (Chunk 9 owns where
  /// the row lives and how long it lasts.)
  case saved
  /// ASR returned nothing. There is no text to keep, and nothing to apologise
  /// for — the user cancelled a recording that had no speech in it.
  case empty
  /// Transcription failed outright. Distinct from `empty`: something broke, and
  /// conflating them would hide a real failure inside an ordinary one.
  case transcriptionFailed = "transcription_failed"
  /// Text existed but the durable write failed. No pill, deliberately: offering
  /// to restore a row that was never saved is a promise the app cannot keep.
  case saveFailed = "save_failed"
  /// The user pressed the cancel shortcut a second time and discarded the
  /// output. Not a failure — a choice, and it must never read as one in the data.
  case abandoned
}
