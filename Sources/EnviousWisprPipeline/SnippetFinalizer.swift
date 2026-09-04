import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation

/// Resolves every snippet sentinel back into the user's saved text (#628).
///
/// **This is deliberately NOT a `TextProcessingStep`, and that is the whole design.**
/// `TextProcessingRunner` swallows a step's error and continues with that step's input
/// (`TextProcessingRunner.swift`, catch block: "Heart & Limbs: limb failed, continue with input
/// text"), and it skips a step whose `isEnabled` is false. Both are correct for a limb — losing
/// an emoji is survivable. Neither is acceptable here: a swallowed failure would deliver text
/// with a raw sentinel in it, straight into the user's document, their History, and the
/// recovery spool at once. An output invariant cannot be something the runner is allowed to
/// skip, so it is not a step.
///
/// Both paths that run the chain call this immediately after the runner and before anything
/// reads the result: live (`KernelFinalizationWiring`, before the outcome field copy and before
/// the empty-output floor) and recovery (`RecoveryTextProcessor`, before `usablePolish`).
///
/// The one rule this type exists to keep: **it never returns text containing a sentinel it
/// owns.**
enum SnippetFinalizer {

  /// Why a resolved dictation did not keep its polished text. Closed set; `snippetSentinelLoss`
  /// is the only member this type produces.
  static let sentinelLossReason = "snippet_sentinel_loss"

  struct Resolution: Equatable {
    /// The deterministic text, with every expansion substituted in.
    var text: String
    /// The polished text with expansions substituted in, or nil when polish was rejected.
    var polishedText: String?
    /// True when polish produced output that could not be trusted to carry the expansions.
    var rejectedPolish: Bool
  }

  /// Resolve `context` in place. A no-op when no snippet fired, so an ordinary dictation pays
  /// one array-emptiness check and nothing else.
  static func finalize(_ context: inout TextProcessingContext) {
    let records = context.protectedExpansions
    guard !records.isEmpty else { return }

    let resolution = resolve(
      text: context.text, polishedText: context.polishedText, records: records)

    context.text = resolution.text
    context.polishedText = resolution.polishedText

    guard resolution.rejectedPolish else { return }

    // A sentinel-loss fallback is a pipeline fallback, and saying so is not optional. Without
    // these three the metrics report that polish did NOT fall back on exactly the takes where
    // this type threw its output away — a counter whose name is a causal claim, measured on a
    // state that now has a second producer.
    //
    // `TextProcessingStep.swift` states the invariant these two must satisfy together:
    // `(polishFallbackReason != nil) == pipelineFellBackToRaw`.
    context.pipelineFellBackToRaw = true
    context.polishFallbackReason = sentinelLossReason
    // Cleared because no remote polish survived into the delivered text. Provider, model and
    // `polishMetadata` are deliberately RETAINED: polish was genuinely attempted, and erasing
    // that would make an attempted-and-rejected take indistinguishable from one that never
    // called a model.
    context.polishRanRemote = nil
  }

  /// The pure decision, split out so it can be tested without building a context.
  ///
  /// Polished output is kept only when EVERY sentinel appears in it EXACTLY ONCE. Not "at
  /// least once": a model that duplicated a sentinel would paste the user's saved text twice,
  /// which is a wrong document rather than a missing flourish.
  static func resolve(
    text: String, polishedText: String?, records: [SnippetExpansionRecord]
  ) -> Resolution {
    let deterministic = substituting(records, into: text)

    guard let polished = polishedText else {
      return Resolution(text: deterministic, polishedText: nil, rejectedPolish: false)
    }

    let intact = records.allSatisfy { occurrences(of: $0.sentinel, in: polished) == 1 }
    guard intact else {
      // Whole-dictation fallback rather than per-anchor repair: the promise is that the saved
      // text arrives exactly, and reconstructing a lost span at a guessed anchor trades that
      // for a heuristic on the one property whose entire value is that it is not one.
      return Resolution(text: deterministic, polishedText: nil, rejectedPolish: true)
    }

    return Resolution(
      text: deterministic,
      polishedText: substituting(records, into: polished),
      rejectedPolish: false)
  }

  /// Substitute every record. Order is irrelevant because sentinels are mutually exclusive by
  /// construction — `SnippetExpander.mintSentinel` rejects a candidate that appears in the raw
  /// input, in any saved expansion, or in a sentinel already issued for the run — so no
  /// substitution can create or destroy another's match.
  private static func substituting(
    _ records: [SnippetExpansionRecord], into text: String
  ) -> String {
    var out = text
    for record in records {
      if record.suppressFollowingSentenceEnding {
        out = removingSentenceEndingsAfter(record.sentinel, in: out)
      }
      out = out.replacingOccurrences(of: record.sentinel, with: record.expansion)
    }
    return out
  }

  /// Drop any sentence terminator sitting immediately after a sentinel whose snippet owns its
  /// ending (#2637).
  ///
  /// **The model is the LAST writer, so the expander's decision cannot be enforced upstream of
  /// it.** `SnippetExpander` removes the recogniser's terminator; polish then receives the
  /// sentinel and can put one back, and this type substitutes into that output.
  ///
  /// A lone sentinel reaching a model is not hypothetical. `LLMPolishStep` bypasses polish at
  /// three words or fewer, which covers the English case — but that gate is whitespace-based,
  /// and the sibling gate for unsegmented scripts (ja/zh/th/lo) counts CHARACTERS with a
  /// minimum of 10 (`LLMPolishStep.swift:437`). A sentinel is 38 characters and clears it every
  /// time. EG-1 was measured not to add a terminator; the user chooses the provider, so that is
  /// a fact about one model rather than about the path.
  ///
  /// Applied to the deterministic text too, where it is a no-op by construction. That is the
  /// point: one path cannot drift from the other by having the rule in only one of them.
  ///
  /// Scoped to `sentenceEnding`. A comma the model added is the model punctuating a sentence it
  /// can see, and this leaves it alone, as it leaves brackets and closing quotes alone.
  ///
  /// **Reads the WHOLE punctuation run before deciding, never a terminator prefix.** A loop that
  /// stopped at the first non-terminator left the period in `(EWSNIPccc).` and `"EWSNIPccc".`,
  /// which is the trailing-period bug back again for a quoted or bracketed snippet. That is the
  /// same property as `endsSentence` reading only a token's last character and as the expander
  /// once refusing a mixed run, so all three now ask `SnippetText.droppingSentenceEndings`.
  private static func removingSentenceEndingsAfter(
    _ sentinel: String, in text: String
  ) -> String {
    var out = ""
    var rest = Substring(text)
    while let found = rest.range(of: sentinel) {
      out += rest[rest.startIndex..<found.upperBound]
      let after = rest[found.upperBound...]
      let run = SnippetText.punctuationRunPrefix(of: after)
      out += SnippetText.droppingSentenceEndings(from: run)
      rest = after[run.endIndex...]
    }
    return out + rest
  }

  private static func occurrences(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var searchRange = haystack.startIndex..<haystack.endIndex
    while let found = haystack.range(of: needle, range: searchRange) {
      count += 1
      searchRange = found.upperBound..<haystack.endIndex
    }
    return count
  }
}
