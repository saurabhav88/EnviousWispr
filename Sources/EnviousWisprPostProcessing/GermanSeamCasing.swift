import Foundation

/// Whether a German word may be lowercased when it opens a dictation inserted
/// mid-sentence.
///
/// German capitalises EVERY noun mid-sentence, so the English rule — "lowercase
/// when the word is a known ordinary lowercase word" — is not merely useless
/// here, it is inverted. `See`, `Start`, `Test`, `Team` and `Most` are ordinary
/// English lowercase words AND German nouns (#1785), which is why casing shipped
/// English-only.
///
/// ## Why a closed list rather than the tagger alone
///
/// Apple's tagger CAN tell a German noun from a German adverb, and measured
/// alone it was tempting: 100% on 50 ordinary cases. It collapses on the class
/// German actually turns on — **nominalisation**. German capitalises a word for
/// the ROLE it plays in the sentence, so adverbs, pronouns, numbers,
/// prepositions, conjunctions and interjections all take a capital when used as
/// nouns, and the formal `Sie` is capitalised without being a noun at all.
///
/// Measured over 90 cases, four candidate rules, 2026-07-26
/// (`docs/feature-requests/issue-1803-artifacts/`):
///
/// | rule | precision | damage |
/// |---|---|---|
/// | tagger alone ("not a noun") | 77% | 14 |
/// | tagger + a safe-tag allowlist | 77% | 13 |
/// | + a homograph refusal list | 79% | 11 |
/// | + ranked-hypothesis ambiguity check | 85% | 7 |
/// | **this rule** | **100%** | **0** |
///
/// Every one of the seven survivors of the best tagger-driven rule was a
/// nominalisation — `Jetzt`, `Hier`, `Drei`, `Für`, `Wenn`, `Ich`, `Nein` — and
/// none of them is detectable from the fragment we can see, because the evidence
/// for nominalisation lives in the part of the sentence we do not have.
///
/// So the list below is a safe SUBSET, not the mechanism. It is deliberately
/// small, it contains only words whose nominalised use is vanishingly rare in
/// dictation, and **every word that damaged an earlier candidate rule is
/// absent** — `jetzt`, `hier`, `drei`, `für`, `wenn`, `ich`, `nein`, `sie`,
/// `morgen`, `heute`, `gestern`, `recht`. Membership alone is not enough: the
/// tagger must also agree the word is not a noun, so a listed word used
/// unusually still keeps its capital.
///
/// Trade: recall 68%. About a third of the German continuations that COULD be
/// lowercased are left alone. That is the correct direction — leaving a capital
/// is exactly today's behaviour, while lowercasing a real German noun corrupts
/// text that was already right.
///
/// Statistical footing: zero errors is only meaningful with enough decisions
/// behind it. With no failures in n decisions the one-sided 95% lower bound on
/// precision is `0.05^(1/n)`; the shipped corpus yields 31 zero-error decisions,
/// a lower bound of **90.8%**, which clears the founder's 90% bar as an interval
/// rather than merely as an observation. The test asserts that BOUND, not a
/// decision count, so a shrinking corpus fails instead of quietly weakening.
///
/// Issue #1803 part 2.
public enum GermanSeamCasing {

  /// German words that are effectively never nominalised at the start of a
  /// dictated continuation.
  ///
  /// Closed and auditable by design. Growing it is a deliberate act that must be
  /// re-measured, never a reflex: each addition widens the set of words we are
  /// willing to lowercase, and the failure it risks is silent.
  public static let neverNominalised: Set<String> = [
    // Conjunctions.
    "und", "oder", "aber", "weil", "obwohl", "falls", "dass", "damit", "sondern",
    // Sentence adverbs and modal particles.
    "vielleicht", "leider", "natürlich", "eigentlich", "manchmal", "trotzdem",
    "deshalb", "deswegen", "außerdem", "allerdings", "jedoch", "dennoch",
    "hoffentlich", "wahrscheinlich", "sicherlich", "immer", "wieder", "bereits",
    "endlich", "sofort", "zuerst", "danach", "schließlich", "ziemlich",
    "wirklich", "einfach", "gerade", "besonders", "sehr", "kaum", "fast", "nur",
    "auch", "schon", "noch", "nicht", "zwischendurch", "übrigens", "nochmal",
    // Determiners and quantifiers.
    "dieser", "diese", "dieses", "jeder", "jede", "jedes", "alle", "beide",
    "einige", "viele", "manche", "solche", "mein", "meine", "dein", "deine",
    // Pronouns. `sie` and `ich` are DELIBERATELY absent: the formal `Sie` is
    // always capitalised, and `das Ich` is an ordinary nominalisation.
    "wir", "du", "er", "es", "man", "uns", "euch",
    // Prepositions that do not head a common nominalisation. `für` is absent —
    // `das Für und Wider` is idiomatic.
    "ohne", "gegen", "trotz", "seit", "während", "wegen",
    // Question words. `wann`/`wo`/`wie` nominalise only in fixed philosophical
    // phrases, which do not open a dictated continuation.
    "warum", "wieso", "weshalb", "wann", "wo", "wie",
    // Verbs that frequently open a continuation.
    "kann", "könnte", "sollte", "müsste", "habe", "hat", "ist", "war", "wird",
    // Politeness openers.
    "bitte", "danke",
  ]

  /// Whether `word` is a member, compared case-insensitively and
  /// locale-independently.
  ///
  /// `lowercased()` rather than a locale-aware fold: the Turkish dotless-i
  /// mapping would silently change membership for a user whose region is set to
  /// Turkey, and this set is German.
  public static func isNeverNominalised(_ word: String) -> Bool {
    neverNominalised.contains(word.lowercased())
  }
}
