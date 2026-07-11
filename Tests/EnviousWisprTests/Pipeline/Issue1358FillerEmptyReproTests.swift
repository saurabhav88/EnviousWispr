import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

// The founder's real one-at-a-time dictations that DELIVERED (2026-07-11). None of
// these may ever be emptied by filler removal. File-scope so @Test argument access is
// not actor-isolated.
private let realWordsThatDelivered: [String] = [
  "Okay.", "Sounds good.", "Hi.", "Hello.", "No.", "No.", "Yeah.",
  "A B.", "See.", "D.", "Gee.", "1988.", "27.", "25.", "Eight.",
  "OK", "no", "hi", "I", "yes", "8",
]

// Bare filler captures — the cold-mic artifact class. Expected to collapse to empty.
private let fillerOnlyCaptures: [String] = [
  "uh", "um", "umm", "uhh", "hmm", "mm", "mhm", "mmm", "ah", "er",
  "uh.", "Um.", "Mm-", "hmm...",
]

// MARK: - #1358 reproduction — "text processing can erase meaningful 2-4 char transcripts"
//
// EMPIRICAL REPRODUCTION (founder directive 2026-07-11: replicate the bug against the
// REAL shipped step, do not trust the Sentry auto-triage narrative).
//
// Hypothesis under test: the eraser is FillerRemovalStep (ON by default —
// SettingsDefaultValues.fillerRemovalEnabled = true), NOT the AI polish (polish is
// skipped on short dictations). A cold-mic quick press yields an ASR best-guess that
// is a bare filler token ("uh"/"um"/"mm"...). FillerRemovalStep has no empty-floor, so
// the whole utterance collapses to "". TranscriptFinalizer then trims to empty and
// throws FinalizationError.emptyAfterProcessing — a heart-path finalization failure
// with no transcript delivered.
//
// This suite runs the real step over the founder's live dictation battery + the filler
// tokens and records, for each input, whether it survives the same trim the finalizer
// applies (trimmingCharacters(in: .whitespacesAndNewlines)). It asserts:
//   (1) real short words the founder confirmed work are NEVER emptied, and
//   (2) filler-only captures DO collapse to empty (reproducing the failure precondition).
@MainActor
@Suite("#1358 filler-removal empties short transcripts (reproduction)")
struct Issue1358FillerEmptyReproTests {

  /// Mirrors TranscriptFinalizer.swift:130 — the trim whose emptiness throws.
  private func finalTrim(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func runFiller(_ input: String) async throws -> String {
    let step = FillerRemovalStep()
    step.fillerRemovalEnabled = true  // shipped default
    let ctx = try await step.process(TextProcessingContext(text: input, language: nil))
    return ctx.text
  }

  @Test(
    "real short words the founder confirmed are never erased", arguments: realWordsThatDelivered)
  func realWordSurvives(_ word: String) async throws {
    let out = finalTrim(try await runFiller(word))
    #expect(!out.isEmpty, "REGRESSION: filler removal erased a real word: \"\(word)\" -> \"\"")
  }

  @Test(
    "bare filler captures collapse to empty (reproduces the failure precondition)",
    arguments: fillerOnlyCaptures)
  func fillerCollapsesToEmpty(_ filler: String) async throws {
    let out = finalTrim(try await runFiller(filler))
    #expect(
      out.isEmpty,
      "Expected filler-only \"\(filler)\" to collapse to empty (the emptyAfterProcessing precondition); got \"\(out)\""
    )
  }

  // Partial-strip of a repeated filler leaves a fragment rather than empty — this is
  // why "Mm-mm" from the recognizer delivered "Mm-" in a build with filler removal ON
  // (regex strips only the trailing token). Same cold-mic filler-artifact class; documents
  // that the empty-collapse is the fully-bare-filler subset, not every filler capture.
  @Test("repeated filler partially strips to a fragment, not empty")
  func repeatedFillerLeavesFragment() async throws {
    #expect(finalTrim(try await runFiller("Mm-mm")) == "Mm-")
    #expect(finalTrim(try await runFiller("mm-hmm")) == "mm-")
  }
}
