import Foundation

/// What we say about a local Ollama model, and the only place we say it (#1950).
///
/// Replaces `OllamaQualityTier` (`best` / `medium` / `worst`, rendered "Best" / "Medium" / "Fast"),
/// which was assigned three different ways that disagreed with each other and with our own
/// measurements: curated literals, a size heuristic that called any 7B model "Best" without ever
/// running a case through it, and a placeholder on hosted rows. The measured best model we offer
/// was labelled "Medium" and a model that failed all twenty cases was labelled "Fast".
///
/// `package` rather than `public` deliberately. Nothing outside this SPM package needs a verdict, and
/// a `public` non-frozen enum from another module forces `@unknown default` at every switch over it,
/// which is the silent branch a future case would fall into. Package visibility lets sibling targets
/// switch exhaustively, so adding a case is a compile error at every consumer instead.
package enum OllamaModelVerdict: Sendable {
  /// Measured 30% or better on the behaviour corpus.
  case recommended
  /// Measured 14% to 29%. Usable, with a real failure mode worth naming.
  case mixed
  /// Measured 1% to 13%.
  case unreliable
  /// Produced no acceptable result in ANY of the twenty cases. Categorical, not a threshold: a
  /// count of zero cannot drift the way a percentage can.
  case notRecommended
  /// We have not measured this model. Says who did not do it rather than implying a reading.
  case notTested
  /// Our own model, measured on a different corpus and protocol. Makes no claim in this vocabulary
  /// in either direction, which is why it is not `notTested`.
  case firstParty

  package var label: String {
    switch self {
    case .recommended: return "Recommended"
    case .mixed: return "Mixed results"
    case .unreliable: return "Unreliable"
    case .notRecommended: return "Not recommended"
    case .notTested: return "Not tested by us"
    case .firstParty: return "Our own model"
    }
  }
}

/// The single authority for model id to verdict and note.
///
/// There is deliberately no stored verdict on `OllamaModelCatalogEntry`. Two hand written copies of
/// one decision diverge, which is the defect PR #2020 spent nine review rounds consolidating away
/// in the eval receipts the day this shipped; the model list and the selection dropdown both ask
/// here instead. `OllamaModelCatalogEntry` describes what a model IS (name, size, downloaded);
/// this describes what we THINK of it, which is a different question with a different source.
///
/// Membership is a literal a human writes after a benchmark run, never a value computed at launch.
/// `MeasuredModelVerdictsTests` compares every entry below against a fixture generated from the
/// judged receipts, so a re run that moves a model produces a failing test rather than a silent
/// relabel or a stale label nobody notices.
///
/// Source of every number: `scripts/eval/runs/ollama-bench-1950/judged-rejudged-2026-08-11/`,
/// judged 2026-08-11 by `claude-sonnet-5` over the twenty case Type B behaviour corpus. Notes are
/// verbatim from the approved `docs/feature-requests/issue-1950-artifacts/note-copy.md`.
package enum OllamaModelVerdicts {
  /// One model's measured standing.
  package struct Entry: Sendable {
    package let verdict: OllamaModelVerdict
    /// The "what goes wrong" clause, or empty where we make no measured claim.
    package let note: String

    package init(verdict: OllamaModelVerdict, note: String) {
      self.verdict = verdict
      self.note = note
    }
  }

  /// Every LOCAL model we have measured, whether or not we offer it as a suggestion.
  ///
  /// "Not in our catalog" is NOT "not tested": `deepseek-r1:1.5b` is a measured arm we do not
  /// suggest, and a user who already has it deserves the number we have rather than a shrug.
  /// `qwen3:0.6b` was in that position until the founder approved adding it (2026-08-11) on the
  /// strength of its result: the second best local score we have measured, from the smallest
  /// download of the twelve.
  ///
  /// Keys are canonical names (`canonicalModelName`), so `llama3.2` and `llama3.2:latest` are one
  /// model while `llama3.2` and `llama3.2:1b` stay two.
  private static let measured: [String: Entry] = [
    // Recommended: 30% or better.
    "qwen2.5:3b": Entry(
      verdict: .recommended, note: "best in our tests, may follow dictated instructions"),
    "qwen3:0.6b": Entry(
      verdict: .recommended, note: "scored well in our tests, very small download"),
    "qwen2.5:7b": Entry(
      verdict: .recommended,
      note: "resists dictated instructions, sometimes drops or invents words"),

    // Mixed: 14% to 29%. All three fail 6 of 7 non-English cases, hence one shared phrase: they
    // are 5pp apart on an instrument whose measured tail is 5pp, so three different sentences
    // would imply a distinction the data cannot support.
    "gemma2:2b": Entry(verdict: .mixed, note: "mixed results, often mishandles other languages"),
    "gemma2": Entry(verdict: .mixed, note: "mixed results, often mishandles other languages"),
    "gemma3n:e4b": Entry(
      verdict: .mixed, note: "mixed results, often mishandles other languages"),

    // Unreliable: 1% to 13%. All three at 5.0% with 10 to 11 trust breaking failures.
    //
    // `llama3.2` was the shipped default until #1950. Its automated score reads 6.2% over 16
    // scored cases, because the judge returns no score for four of its outputs; those four are
    // hand adjudicated in `issue-1950-artifacts/llama32-ungradeable-four.md` (three translate
    // non-English dictation into English, one reproduces an injection trap into the user's text),
    // which puts it at 1 pass in 20 with 11 S4. The automated number is the flattering one.
    "llama3.2": Entry(verdict: .unreliable, note: "rarely cleans dictation correctly"),
    "mistral": Entry(verdict: .unreliable, note: "rarely cleans dictation correctly"),
    "deepseek-r1:1.5b": Entry(
      verdict: .unreliable, note: "rarely cleans dictation correctly"),

    // Zero acceptable results in twenty cases, with 12, 16 and 19 trust breaking failures.
    "phi3": Entry(verdict: .notRecommended, note: "failed every test we ran"),
    "llama3.2:1b": Entry(verdict: .notRecommended, note: "failed every test we ran"),
    "tinyllama": Entry(verdict: .notRecommended, note: "failed every test we ran"),

    // Ours, measured elsewhere. Empty note: this vocabulary would be the wrong ruler.
    "eg-1": Entry(verdict: .firstParty, note: ""),
  ]

  /// The verdict for any model id. An id we have not measured returns `.notTested`, never a guess
  /// derived from its name or its parameter count.
  ///
  /// First-party ids normalize through `isFirstPartyModel` rather than through `canonicalModelName`,
  /// which strips only `:latest`. Without that, a user running the already-supported `eg-1:q4` would
  /// be told "Not tested by us" about OUR OWN model. That authority also refuses lookalikes, so
  /// `eg-10` and `eg-1-acme-client` stay `.notTested` as they should.
  package static func entry(for modelID: String) -> Entry {
    let normalizedID =
      OllamaSetupService.isFirstPartyModel(modelID)
      ? "eg-1"
      : OllamaSetupService.canonicalModelName(modelID.lowercased())
    return measured[normalizedID] ?? Entry(verdict: .notTested, note: "")
  }

  /// Convenience for the common case.
  package static func verdict(for modelID: String) -> OllamaModelVerdict {
    entry(for: modelID).verdict
  }

  /// Every id carrying a measured verdict, `eg-1` excluded because it was measured elsewhere.
  /// The generated fixture test asserts set equality against this in BOTH directions, so an extra
  /// key here and a missing key here both fail.
  package static var measuredModelIDs: Set<String> {
    Set(measured.keys.filter { $0 != "eg-1" })
  }

  /// Rendered once above the local model list, not on any single row.
  ///
  /// Universal rather than model specific: the best local result is 3 of 7 non-English cases and
  /// seven of the twelve measured models pass zero of 7. Saying it only on the rows that fail worst
  /// would imply the others are fine.
  package static let nonEnglishCaveat = "No local model handled other languages well in our tests."
}
