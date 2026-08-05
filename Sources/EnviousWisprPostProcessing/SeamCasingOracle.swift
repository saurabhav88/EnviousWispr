import Foundation

/// Whether a capitalised word may be lowered where it sits, in any of the
/// twelve languages that have a casing policy.
///
/// A VALUE, not a service: its four closures — `dictionaryVerdict`,
/// `isLearnedWord`, `isRecognizedName`, `isNoun` — are the only contact with the
/// operating system, so unit tests inject fixed answers and never touch a
/// system facility. `SeamCasingOracleRuntime` is the only thing that builds a
/// live one, which keeps `AppKit` and `NaturalLanguage` confined to that file.
///
/// Named `EnglishWordOracle` until #1922 (2026-08-05) made it serve twelve
/// languages. `mayLower` still asks the two questions below; the German noun
/// VETO that issue added lives OUTSIDE it, in
/// `CursorInsertionRepair.applyLeadingCase`, which is what keeps it structurally
/// a veto rather than a decider.
///
/// Replaces `OrdinaryLowercaseLexicon`, a hand-authored 799-word allowlist that
/// could not contain the English language: `go`, `send`, `call`, `buy`, `email`
/// and `learn` were all absent, so ordinary continuations kept a wrong capital.
/// Issue #1803.
package struct SeamCasingOracle: Sendable {
  /// Why this oracle cannot decide, or `nil` when it can.
  package let unavailableReason: CursorInsertionRepair.CaseSkipReason?

  /// What the dictionary says about the lowercase form.
  ///
  /// Three-valued, not a Bool: the dictation that DISCOVERS an outage must
  /// report the outage, not a bland `.notOrdinaryWord`. Collapsing "the
  /// dictionary said no" and "the dictionary is gone" into `false` mislabels the
  /// one event worth seeing (local diff review r4).
  package enum DictionaryVerdict: Equatable, Sendable {
    case ordinary
    case notOrdinary
    case unavailable(CursorInsertionRepair.CaseSkipReason)
  }

  package let dictionaryVerdict: @Sendable (String) -> DictionaryVerdict

  /// Has the user taught this word to macOS?
  ///
  /// Learned words skew heavily toward names, brands and technical spellings,
  /// so a learned word is evidence AGAINST lowering, never for it. Measured:
  /// after `learnWord`, a nonsense string reports as correctly spelled, so
  /// without this check anything the user taught macOS would become "an
  /// ordinary English word" and be lowered.
  package let isLearnedWord: @Sendable (String) -> Bool

  /// Does the recogniser read the payload's first word as a NAME, judged
  /// against the text actually preceding the caret?
  ///
  /// This is the primary guard. Apple's model is trained on exactly the
  /// polyseme problem — "speak with Mark" reads as a personal name, "mark the
  /// page" does not — so it is asked with the real surrounding text, never a
  /// bare word.
  ///
  /// It does not catch everything. A name it has never seen falls through to
  /// the dictionary, which is why that second step exists.
  package let isRecognizedName: @Sendable (_ left: String, _ payload: String) -> Bool

  /// Does the word-class tagger call the payload's first word a noun?
  ///
  /// Consulted ONLY where `CasingPolicy.nounVeto` is set, which today is German
  /// alone — the one supported language that capitalises every noun. #1922.
  ///
  /// Takes the payload and not the joined seam on purpose: #1803 measured that
  /// feeding the surrounding document made German WORSE, flipping `Morgen` from
  /// adverb to noun. This is the opposite of `isRecognizedName`, which needs the
  /// left context because a name is recognised from its neighbours.
  ///
  /// Answering `true` KEEPS the capital, so `true` is the conservative direction
  /// and every refusal path returns it.
  package let isNoun: @Sendable (_ payload: String) -> Bool

  package var isAvailable: Bool { unavailableReason == nil }

  /// The same oracle, but asking permission before every consultation.
  ///
  /// `authorize` answers two things at once for a caller holding a deadline
  /// (#1921), and both need to be one atomic answer rather than a notification:
  ///
  /// - **It records that the oracle was genuinely reached.**
  ///   `CursorInsertionRepair.repair` has early exits and does its spacing work
  ///   before ever consulting word knowledge, so the moment repair STARTS is not
  ///   the moment the oracle is involved — and a deadline that conflates the two
  ///   permanently disables a component that was never touched.
  /// - **It refuses once the deadline has fired.** Cancellation cannot preempt a
  ///   blocked thread, so an un-preempted repair would otherwise walk into the
  ///   real oracle after the timeout gave up, making exactly the unbounded call
  ///   the deadline exists to bound (integration review round 2).
  ///
  /// Each refusal is conservative in that closure's OWN vocabulary — dictionary
  /// unavailable, learned word, recognised name — so every one of them prevents
  /// lowering. That is what makes a late refusal safe by construction: the worst
  /// it can do is decline to improve text, which is what the app did before this
  /// feature existed.
  ///
  /// `isLearnedWord` deliberately returns `true` here while `unavailable(_:)`
  /// returns `false` there, and the difference is not an inconsistency. That
  /// factory sets a non-nil `unavailableReason`, which short-circuits `mayLower`
  /// at its first line, so none of its closures is ever consulted and their
  /// values are inert. This wrapper passes the wrapped oracle's own
  /// `unavailableReason` through, so on a healthy oracle the closures ARE
  /// consulted and each value has to refuse on its own.
  ///
  /// I described these as "copied verbatim" from that factory when handing this
  /// to review. They are not, and the reviewer checked. The values are right;
  /// the reason I gave for them was not.
  ///
  /// Built here rather than at the call site because the memberwise initialiser
  /// is internal to this module, and because a type that can be wrapped should
  /// own how it is wrapped. `repair` stays unaware of any of this: it remains a
  /// pure function of the oracle it is handed.
  package func authorized(
    by authorize: @escaping @Sendable () -> Bool
  ) -> SeamCasingOracle {
    SeamCasingOracle(
      unavailableReason: unavailableReason,
      dictionaryVerdict: { word in
        guard authorize() else { return .unavailable(.oracleTimedOut) }
        return dictionaryVerdict(word)
      },
      isLearnedWord: { word in
        guard authorize() else { return true }
        return isLearnedWord(word)
      },
      isRecognizedName: { left, payload in
        guard authorize() else { return true }
        return isRecognizedName(left, payload)
      },
      // `true` on refusal, same as the others and for the same reason: a veto
      // answering "noun" keeps the capital, which is what the app did before
      // this feature existed.
      isNoun: { payload in
        guard authorize() else { return true }
        return isNoun(payload)
      })
  }

  package static func unavailable(
    _ reason: CursorInsertionRepair.CaseSkipReason
  ) -> SeamCasingOracle {
    SeamCasingOracle(
      unavailableReason: reason,
      dictionaryVerdict: { _ in .unavailable(reason) },
      isLearnedWord: { _ in false },
      isRecognizedName: { _, _ in true },
      isNoun: { _ in true })
  }

  /// The decision, in one place.
  ///
  /// Two steps, in this order, and the order is the whole design:
  ///
  /// 1. **Is it a name here?** The recogniser sees the real surrounding text, so
  ///    it can separate "speak with Mark" from "mark the page". A recognised
  ///    name keeps its capital and the dictionary is never consulted.
  /// 2. **Is it even English?** A word the dictionary knows is an ordinary word
  ///    and may be lowered. A word it does NOT know is an invented name —
  ///    `Ghostty`, `Vercel`, `Figma` — and keeps its capital.
  ///
  /// The dictionary is deliberately asked "is this English?", not "is this
  /// ordinary?". An earlier design asked the second question and then refused
  /// every noun to compensate, which needed a hand-maintained exception list and
  /// cost 21 points of coverage. Measured on 11,577 real continuations: 97.3%
  /// against 75.9%.
  ///
  /// Known limit: a brand that reuses an English word — `Bluetooth`, `Apple`,
  /// `Discord`, `Chrome` — is in the dictionary, so if the recogniser misses it
  /// in context it will be lowered. Custom Words is the per-user answer to that,
  /// and unlike a built-in list it scales past one person's vocabulary.
  ///
  /// Every refusal keeps the capital, which is exactly what the app did before
  /// this feature existed, so no failure here can damage text that was already
  /// correct.
  package func mayLower(
    word: String, left: String, payload: String, languageCode: String? = nil
  ) -> CursorInsertionRepair.CaseSkipReason? {
    if let unavailableReason { return unavailableReason }
    // LOCALE-AWARE, and it has to be: `lowercased()` uses the root locale, so a
    // Turkish word opening with dotless `I` was queried as `işık` rather than
    // `ışık` — the Turkish dictionary rejects that, so an ordinary word kept its
    // capital. The defect fails SAFE, which is exactly why nothing caught it: it
    // costs Turkish recall and never damages text. Whole-diff review, P2.
    //
    // Defaults to nil (root locale) so the many test call sites that pass no
    // language keep their existing behaviour, which is correct for English.
    let lower = word.lowercased(with: CursorInsertionRepair.casingLocale(for: languageCode))
    guard !isRecognizedName(left, payload) else { return .recognizedName }
    // Queried lowercased, and that is sufficient: `hasLearnedWord` folds case in
    // both directions. Measured with clean before-teaching controls — teach
    // `Zqxvkjbrandone`, query `zqxvkjbrandone`, and it answers yes; teach a
    // lowercase probe and every capitalisation of it answers yes too. Cloud
    // review raised the opposite as a defect (PR #1815), because a user teaching
    // macOS `Sentry` or `Olive` is exactly the population this design is weakest
    // on. Probe and controls: issue-1803-artifacts/2026-07-26-learned-word-positive-control.swift.
    guard !isLearnedWord(lower) else { return .learnedWord }
    switch dictionaryVerdict(lower) {
    case .unavailable(let reason): return reason
    case .notOrdinary: return .notOrdinaryWord
    case .ordinary: break
    }
    return nil
  }
}
