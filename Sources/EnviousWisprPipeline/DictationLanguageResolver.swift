import EnviousWisprCore
import Foundation
import NaturalLanguage

/// The three facts a caller can know about a dictation's language BEFORE
/// reading the text (#2614). Built by both production chain callers
/// (`KernelFinalizationWiring`, `RecoveryTextProcessor`) and handed to
/// `TextProcessingRunner.run`, which resolves once through
/// `DictationLanguageResolver.resolve` and seeds the context for every step.
package struct LanguageEvidence: Sendable {
  package let lockedLanguage: String?
  package let engineDetectsLanguage: Bool
  package let engineReportedLanguage: String?
  /// #3124: the spelling in force for this take, frozen with the lock by the caller
  /// (`EnglishSpelling.effective`). Not language evidence in the resolver's sense: the runner
  /// seeds it into the context unchanged, and the spelling steps read it from there.
  package let englishSpelling: EnglishSpelling

  package init(
    lockedLanguage: String?, engineDetectsLanguage: Bool, engineReportedLanguage: String?,
    englishSpelling: EnglishSpelling
  ) {
    self.lockedLanguage = lockedLanguage
    self.engineDetectsLanguage = engineDetectsLanguage
    self.engineReportedLanguage = engineReportedLanguage
    self.englishSpelling = englishSpelling
  }

  /// The user locked a language: nothing else is consulted.
  package static func locked(
    _ language: String, englishSpelling: EnglishSpelling = .american
  ) -> LanguageEvidence {
    LanguageEvidence(
      lockedLanguage: language, engineDetectsLanguage: false, engineReportedLanguage: nil,
      englishSpelling: englishSpelling)
  }

  /// Automatic on an engine that does not detect: the text alone decides.
  package static let none = LanguageEvidence(
    lockedLanguage: nil, engineDetectsLanguage: false, engineReportedLanguage: nil,
    englishSpelling: .american)
}

/// Decides what language a finished dictation is in, for consumers that must not
/// act on a guess (#1785, #1921).
///
/// The cursor-insertion repair only recases text in a language whose rules it
/// knows, so a WRONG language is worse than no language: it lowercases a
/// correctly capitalised German noun. This resolves the question from positive
/// evidence and abstains when there is none.
///
/// Written because the obvious source is not evidence. `ParakeetBackend` USED TO
/// stamp `language: "en"` on EVERY result, while the settings screen advertised
/// "Parakeet's 25 European languages, not just English" — and Parakeet is the
/// default engine. Reading that field directly meant a German dictation on the
/// default path was recased with English rules (cloud review, PR #1802).
///
/// #1678 removed that constant: Parakeet now reports `nil`, because it performs
/// no language detection and a user's lock is intent rather than a measurement.
/// **The precedence rule below is unchanged and still load-bearing** — it keys
/// on `engineDetectsLanguage`, not on the field's value, so it refuses a
/// non-detecting engine's answer whatever that answer is. That is exactly why
/// nil was the right replacement rather than writing the locked code here.
///
/// #1921 replaced a LENGTH floor with a CONFIDENCE floor. The old rule demanded
/// 24 alphabetic scalars before it would look at the recogniser's answer at all,
/// which refused **29.9% of 12,150 real continuations** — the short mid-sentence
/// insertions this feature exists for. The recogniser can identify far shorter
/// text than that; it was simply never asked how sure it was. Measured:
/// `Rat war gut.` (9 scalars) is German at 1.000, `On my way.` (7) is English at
/// 0.966, and across 33 deliberately adversarial non-English negatives the
/// highest ENGLISH score was 0.204. Receipts:
/// `docs/feature-requests/issue-1921-artifacts/`.
package enum DictationLanguageResolver {

  /// How sure the recogniser must be before its answer is used.
  ///
  /// 0.90 rather than a value closer to the observed noise floor, deliberately.
  /// These are not demonstrated calibrated probabilities, and the adversarial
  /// corpus was written by the same person choosing this number, so "headroom
  /// over my own worst case" is close to circular reasoning. 0.90 costs 3.8
  /// points of acceptance against 0.80 and still moves the feature from 70.0% to
  /// 87.6% of real continuations. Lower it only against an independently sourced
  /// multilingual corpus.
  package static let minConfidence = 0.90

  /// What the resolver decided, and on what evidence.
  ///
  /// `language` alone cannot say whether it came from the user's setting, the
  /// engine, the text, or nothing — so a field regression would be invisible.
  /// `Sendable` because this value is carried across the repair deadline's
  /// isolation boundary.
  package struct Resolution: Sendable {

    /// Which rung of the precedence ladder answered.
    package enum Source: String, Sendable {
      case locked, engine, dictation, document, none
    }

    /// Bucketed confidence. Buckets, never the raw score: the operational
    /// question is "did the gate start resolving", and a raw float per dictation
    /// is more precision than that needs.
    package enum Bucket: String, Sendable {
      case none, lt50, f50to70, f70to90, ge90

      /// Whether an ABSTAINED text answer in this bucket may veto English
      /// cleanup rules (#2614). A switch rather than a comparison because the
      /// enum is not `Comparable`, and exhaustiveness is what makes a new
      /// bucket a compile error here instead of a silent non-veto.
      var permitsEnglishVeto: Bool {
        switch self {
        case .none, .lt50: return false
        case .f50to70, .f70to90, .ge90: return true
        }
      }

      init(_ confidence: Double) {
        // A non-finite score falls to `none` rather than through the range
        // ladder. NaN compares false against every bound, so it would otherwise
        // reach `default` and be reported as the HIGHEST bucket — a telemetry
        // value that says "very confident" about an answer the gate refused,
        // since NaN also fails `>= minConfidence`.
        guard confidence.isFinite else {
          self = .none
          return
        }
        switch confidence {
        case ..<0.50: self = .lt50
        case ..<0.70: self = .f50to70
        case ..<0.90: self = .f70to90
        default: self = .ge90
        }
      }
    }

    let language: String?
    let source: Source
    let confidenceBucket: Bucket
    /// #2614: true ONLY on the abstention path, when the text rung's top
    /// hypothesis is a non-English language at a bucket that
    /// `permitsEnglishVeto`. The locked, engine, dictation and document
    /// answers all carry `false`. Same philosophy as the document rung below:
    /// a veto, never an authorisation. Nothing below the floor resolves a
    /// language; this only says "do not apply English-only rules to it".
    let englishVeto: Bool
    /// #996: the base language the learn-from-edits gate may use. The locked
    /// language or a detecting engine's answer when there is one; otherwise
    /// the dictation text's TOP hypothesis at any confidence, unless
    /// `englishVeto` refuses it. Separate from `language` on purpose: cleanup
    /// rewrites text and stays confidence-gated at `minConfidence`, while
    /// learning only raises a card the user must click, so a 0.73 English
    /// read is enough evidence to ask. Measured on the 2026-09-20 baseline:
    /// one misheard name ("Sorat") took a plain English sentence from 0.98 to
    /// 0.73 and the gate refused exactly the takes that had something to
    /// learn. The document rung leaves this nil: it says the DOCUMENT is not
    /// English, nothing about the insertion. Wispr Flow takes this language
    /// from the user's setting and its ASR, never from a confidence read.
    let learnLanguage: String?
    /// #3111: what the dictation TEXT alone says, at `minConfidence`, whatever
    /// rung answered `language`. A lock is intent and an engine answer can come
    /// from one window, so EG-1 names a language only when the text agrees:
    /// naming the wrong one translates INTO it (Polish labelled German came back
    /// German on 31 of 40 sentences). Never used to change `language`, `source`,
    /// `englishVeto` or `learnLanguage`.
    ///
    /// Nil means unsure OR not requested: the lock and engine rungs read the
    /// text only when the caller passes `identifyTextOnAllPaths`, which the
    /// pipeline runner does and the cursor-insertion repair, inside its 100 ms
    /// deadline, does not.
    let textLanguage: String?

    init(
      language: String?, learnLanguage: String?, source: Source, confidenceBucket: Bucket,
      englishVeto: Bool = false, textLanguage: String? = nil
    ) {
      self.language = language
      self.learnLanguage = learnLanguage
      self.source = source
      self.confidenceBucket = confidenceBucket
      self.englishVeto = englishVeto
      self.textLanguage = textLanguage
    }
  }

  /// What the recogniser thinks, and how sure it is. No policy.
  ///
  /// Deliberately sets NO `languageConstraints`. Constraining to the default
  /// engine's own language list looks obviously right and is not: every
  /// non-Latin script then returns nil, which collapses Japanese, Chinese and
  /// Thai to `LanguageRules.unknown`, whose `usesWordSpacing` is true — so the
  /// repair would ADD spaces those languages must not have, on BOTH sides:
  /// rule 1 (`CursorInsertionRepair.swift:392`) adds the leading one and rule 3
  /// (`:487`) the trailing one, and both read that same field. Measured both
  /// ways; unconstrained also decouples this from which engine ran.
  /// #3111: whether a mostly non-English text carries an English STRETCH. The whole-text
  /// recogniser reads a Polish sentence with an English clause inside as Polish at 1.000, and
  /// EG-1 told "Polish" then translates the clause (4 of 20 measured). This reads every run of
  /// `englishStretchWindow` consecutive words and reports `.mixed` on the first run whose top
  /// hypothesis is English at `englishStretchConfidence` or more.
  ///
  /// Measured on the #3111 sets: 19 of 20 Polish sentences with an English phrase flagged (all
  /// four EG-1 translated), 0 of 20 with a single English product name, 0 of 561 pure
  /// non-English sentences across 17 languages. Window 3 flagged product names; window 5 lost
  /// recall. Cost about 0.23 ms per word, so `englishStretchWordLimit` bounds a pathological
  /// input at about a second while EG-1's own cleanup runs about 25 ms per word; past the
  /// limit the answer is `.scanLimit`, never a guess.
  package enum EnglishStretchScan: Sendable, Equatable {
    case clear, mixed, scanLimit
  }

  package static let englishStretchWindow = 4
  package static let englishStretchConfidence = 0.8
  package static let englishStretchWordLimit = 4000

  package static func englishStretch(in text: String) -> EnglishStretchScan {
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = text
    let recognizer = NLLanguageRecognizer()
    var window: [String] = []
    var words = 0
    var result = EnglishStretchScan.clear
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
      words += 1
      guard words <= englishStretchWordLimit else {
        result = .scanLimit
        return false
      }
      window.append(String(text[range]))
      if window.count > englishStretchWindow { window.removeFirst() }
      guard window.count == englishStretchWindow else { return true }
      recognizer.reset()
      recognizer.processString(window.joined(separator: " "))
      if let top = recognizer.languageHypotheses(withMaximum: 3).max(by: { $0.value < $1.value }),
        top.key == .english, top.value >= englishStretchConfidence
      {
        result = .mixed
        return false
      }
      return true
    }
    return result
  }

  package static func identify(_ text: String) -> (language: String, confidence: Double)? {
    guard !text.isEmpty else { return nil }
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    guard
      let top = recognizer.languageHypotheses(withMaximum: 3)
        .max(by: { $0.value < $1.value }),
      let base = LanguageNormalizer.baseCode(top.key.rawValue)
    else { return nil }
    return (base, top.value)
  }

  /// The dictation's language, or an unresolved answer when nothing establishes it.
  ///
  /// Precedence, strongest evidence first:
  /// 1. **The user told us.** A locked language outranks anything inferred.
  /// 2. **An engine that actually detects.** Only when the engine reports
  ///    `supportsLanguageDetection`; an engine that hard-codes a language is
  ///    reporting a constant, not a detection.
  /// 3. **The text itself**, at or above `minConfidence`. This is the default
  ///    engine's normal path.
  /// 4. **The surrounding document, as a VETO only.**
  ///
  /// - Parameter identify: seam. Real recogniser output cannot reproducibly hit
  ///   0.899 / 0.900 / 0.901 across OS versions, so the boundary is tested
  ///   through this rather than by hunting for input that happens to land there.
  /// - Parameter identifyTextOnAllPaths: #3111. Also read the text on the lock and
  ///   engine rungs, for `Resolution.textLanguage` only; precedence is unchanged.
  ///   Off by default so the cursor-insertion repair keeps its no-recogniser fast
  ///   path inside its deadline; `TextProcessingRunner` turns it on.
  package static func resolve(
    lockedLanguage: String?,
    engineDetectsLanguage: Bool,
    engineReportedLanguage: String?,
    text: String,
    surroundingText: String = "",
    identifyTextOnAllPaths: Bool = false,
    identify: (String) -> (language: String, confidence: Double)? = Self.identify
  ) -> Resolution {
    // `isFinite` at every acceptance gate, not only in the bucket. Infinity
    // satisfies `>= minConfidence` while bucketing to `none`, which would resolve
    // a language while reporting no confidence — a contradiction the field could
    // never explain. Hypothetical from the real recogniser, reachable through the
    // seam, and silent if wrong, which is the shape worth guarding.
    //
    // #3111: one recogniser call per resolution, whichever rung answers. The lock
    // and engine rungs make it only when asked to.
    func identifyText() -> (language: String, confidence: Double)? {
      identify(text).flatMap { $0.confidence.isFinite ? $0 : nil }
    }
    func confident(_ answer: (language: String, confidence: Double)?) -> String? {
      guard let answer, answer.confidence >= minConfidence else { return nil }
      return answer.language
    }

    if let lockedLanguage, !lockedLanguage.isEmpty {
      return Resolution(
        language: lockedLanguage, learnLanguage: lockedLanguage, source: .locked,
        confidenceBucket: .none,
        textLanguage: identifyTextOnAllPaths ? confident(identifyText()) : nil)
    }
    if engineDetectsLanguage, let engineReportedLanguage, !engineReportedLanguage.isEmpty {
      return Resolution(
        language: engineReportedLanguage, learnLanguage: engineReportedLanguage, source: .engine,
        confidenceBucket: .none,
        textLanguage: identifyTextOnAllPaths ? confident(identifyText()) : nil)
    }

    let fromDictation = identifyText()
    let dictationBucket = fromDictation.map { Resolution.Bucket($0.confidence) } ?? .none
    if let fromDictation, fromDictation.confidence >= minConfidence {
      return Resolution(
        language: fromDictation.language, learnLanguage: fromDictation.language, source: .dictation,
        confidenceBucket: dictationBucket, textLanguage: fromDictation.language)
    }

    // The surrounding document may VETO, never authorise.
    //
    // An earlier version let the document decide outright, under a comment
    // claiming both mixed cases were safe. That was false in one direction: an
    // English document with a short GERMAN insertion resolves to English, and
    // English casing then lowercases a German noun — the precise defect this
    // path exists to prevent (cloud review, PR #1802). Re-measured for #1921:
    // 17 of 24 German nouns that are also English words would have been
    // wrongly lowered, and the word-level oracle stops only 7 of them.
    //
    // So the document can only ever make us MORE conservative. If it reads as a
    // language we do not case, we take that and skip casing. If it reads as
    // English we still abstain, because the insertion itself was never
    // identified and English is the one answer that lets recasing proceed.
    guard !surroundingText.isEmpty,
      let fromDocument = identify(surroundingText + " " + text),
      fromDocument.confidence.isFinite,
      fromDocument.confidence >= minConfidence,
      fromDocument.language != "en"
    else {
      // #2614: the abstention. A confident-enough NON-English top hypothesis
      // vetoes English-only cleanup (ITN, the English filler table) without
      // resolving anything. Measured on the language-gate fixture
      // (`docs/feature-requests/issue-2614-artifacts/resolver-on-fixture.txt`):
      // the recogniser was never confidently wrong TOWARD English, so an
      // English top hypothesis keeps today's behaviour and a foreign one at
      // >= f50to70 stops the rules that damage it.
      let englishVeto =
        fromDictation.map { $0.language != "en" && dictationBucket.permitsEnglishVeto } ?? false
      return Resolution(
        language: nil, learnLanguage: englishVeto ? nil : fromDictation?.language, source: .none,
        confidenceBucket: dictationBucket, englishVeto: englishVeto)
    }
    return Resolution(
      language: fromDocument.language,
      learnLanguage: nil,
      source: .document,
      confidenceBucket: Resolution.Bucket(fromDocument.confidence))
  }
}
