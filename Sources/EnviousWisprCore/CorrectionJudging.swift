import Foundation

// MARK: - Correction judging contract (#996, learn custom words from edits)
//
// The narrow seam every correction judge answers through: the deterministic
// rules arm, the Apple FoundationModels comparison arms and the Core ML
// cross-encoder classifiers all take one `CorrectionJudgeRequest` and return
// one `CorrectionJudgeOutcome`. Value types and validation only; which judge
// runs, how it is loaded and what it learns from are decided by the modules
// that implement it (PostProcessing, LLM) and composed by the App shell.

/// One changed run the user made inside a pasted dictation: what the
/// recogniser wrote and what the user typed instead. Ids are 1-based and
/// unique inside a request so a judge's decisions can be matched back.
package struct CorrectionCandidate: Sendable, Equatable, Hashable {
  package let id: Int
  package let original: String
  package let replacement: String

  package init(id: Int, original: String, replacement: String) {
    self.id = id
    self.original = original
    self.replacement = replacement
  }
}

/// The three mutually exclusive answers a judge can give for one candidate.
/// `safeAlias` implies `vocabularyCorrection` by construction: there is no
/// class for "not a correction, but replace it automatically anyway".
package enum CorrectionJudgeClass: String, Sendable, CaseIterable, Equatable {
  /// A rewording, grammar, formatting, punctuation or temporary-typo edit.
  case notCorrection
  /// A name, term or spelling fix whose original is itself a real word or
  /// name someone else could mean (Elena → Alina): learn the canonical, add
  /// no alias.
  case correctionButUnsafe
  /// A name, term or spelling fix whose original should always become the
  /// replacement in future dictations ("cuber netties" → Kubernetes).
  case correctionAndSafe

  package var vocabularyCorrection: Bool { self != .notCorrection }
  package var safeAlias: Bool { self == .correctionAndSafe }

  /// The class named by the two booleans; `nil` for (false, true), which is
  /// not a class and is treated as malformed wherever it appears.
  package init?(vocabularyCorrection: Bool, safeAlias: Bool) {
    switch (vocabularyCorrection, safeAlias) {
    case (false, false): self = .notCorrection
    case (true, false): self = .correctionButUnsafe
    case (true, true): self = .correctionAndSafe
    case (false, true): return nil
    }
  }
}

package struct CorrectionJudgeDecision: Sendable, Equatable {
  package let id: Int
  package let verdict: CorrectionJudgeClass

  package init(id: Int, verdict: CorrectionJudgeClass) {
    self.id = id
    self.verdict = verdict
  }
}

/// Why a judge gave no verdict. Every bypass is a counted outcome; the
/// watcher learns nothing and the eval scorer counts the row against recall.
package enum CorrectionJudgeBypass: String, Sendable, Equatable, CaseIterable {
  /// The judge cannot run on this Mac right now (framework absent, model
  /// not enabled, resource missing or failed verification).
  case unavailable
  /// The shared permit was never granted (the caller was cancelled while
  /// queued behind other model work).
  case notGranted
  /// The deadline elapsed after enqueue, queue wait included.
  case deadline
  /// The caller was cancelled after the permit was granted.
  case cancelled
  /// The judge answered, but not one decision per candidate id.
  case malformed
}

package enum CorrectionJudgeOutcome: Sendable, Equatable {
  case verdict([CorrectionJudgeDecision])
  case bypass(CorrectionJudgeBypass)

  /// A verdict only when `decisions` covers every candidate id exactly once
  /// and names nothing else; otherwise `.bypass(.malformed)`. Every judge
  /// funnels its raw answer through this so no arm can return a partial or
  /// padded verdict.
  package static func validated(
    _ decisions: [CorrectionJudgeDecision], for request: CorrectionJudgeRequest
  ) -> CorrectionJudgeOutcome {
    let expected = Set(request.candidates.map(\.id))
    let seen = decisions.map(\.id)
    guard seen.count == expected.count, Set(seen) == expected else {
      return .bypass(.malformed)
    }
    return .verdict(decisions.sorted { $0.id < $1.id })
  }
}

package enum CorrectionJudgeRequestError: Error, Equatable {
  case noCandidates
  case tooManyCandidates(Int)
  case duplicateID(Int)
  case idOutOfRange(Int)
  case emptyRun(id: Int)
  case unchangedRun(id: Int)
  case contextTooLong(Int)

  /// A closed, content-free cause for Sentry (#3105); counts stay out of it.
  package var causeCode: String {
    switch self {
    case .noCandidates: "no_candidates"
    case .tooManyCandidates: "too_many_candidates"
    case .duplicateID: "duplicate_id"
    case .idOutOfRange: "id_out_of_range"
    case .emptyRun: "empty_run"
    case .unchangedRun: "unchanged_run"
    case .contextTooLong: "context_too_long"
    }
  }
}

/// What a judge is asked: up to `maxCandidates` changed runs plus the
/// bounded sentence they occurred in. Validated at construction so every
/// judge can assume the shape.
package struct CorrectionJudgeRequest: Sendable, Equatable {
  /// Plan §3.1 step 5: at most four candidates per settled paste.
  package static let maxCandidates = 4
  /// Bounded context: the pasted sentence around the edits, capped so a
  /// long document never reaches a model. Measured in UTF-16 units, the unit
  /// the AX value read uses.
  package static let maxContextUTF16 = 600

  package let candidates: [CorrectionCandidate]
  package let context: String
  /// BCP-47 base code of the dictation, when the pipeline knows it.
  package let language: String?

  package init(candidates: [CorrectionCandidate], context: String, language: String?) throws {
    guard !candidates.isEmpty else { throw CorrectionJudgeRequestError.noCandidates }
    guard candidates.count <= Self.maxCandidates else {
      throw CorrectionJudgeRequestError.tooManyCandidates(candidates.count)
    }
    var seen = Set<Int>()
    for candidate in candidates {
      guard (1...Self.maxCandidates).contains(candidate.id) else {
        throw CorrectionJudgeRequestError.idOutOfRange(candidate.id)
      }
      guard seen.insert(candidate.id).inserted else {
        throw CorrectionJudgeRequestError.duplicateID(candidate.id)
      }
      let original = candidate.original.trimmingCharacters(in: .whitespacesAndNewlines)
      let replacement = candidate.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !original.isEmpty, !replacement.isEmpty else {
        throw CorrectionJudgeRequestError.emptyRun(id: candidate.id)
      }
      guard original != replacement else {
        throw CorrectionJudgeRequestError.unchangedRun(id: candidate.id)
      }
    }
    guard context.utf16.count <= Self.maxContextUTF16 else {
      throw CorrectionJudgeRequestError.contextTooLong(context.utf16.count)
    }
    self.candidates = candidates.sorted { $0.id < $1.id }
    self.context = context
    self.language = language
  }
}

/// What a judge can do on this Mac, read once by the composer and refreshed
/// on availability transitions (plan §3.2).
package struct CorrectionJudgeCapabilities: Sendable, Equatable {
  /// False when the judge can never run here (framework or OS floor).
  ///
  /// No language set: every dictation language is eligible (founder decision
  /// 2026-09-21, "roll this out for every language, no restrictions"; the
  /// toggle is the safety). The dictation language still travels in the
  /// request and the eval record as evidence, never as a gate.
  package let canRunOnThisMac: Bool
  /// What actually runs: immutable digests (checkpoint, tokenizer, decision
  /// configuration) or, for an AFM arm, the OS/model environment and the
  /// prompt digest. Carried into every eval record so a result can never be
  /// scored under another build's training declaration.
  package let executionIdentity: [String: String]

  package init(canRunOnThisMac: Bool, executionIdentity: [String: String]) {
    self.canRunOnThisMac = canRunOnThisMac
    self.executionIdentity = executionIdentity
  }
}

package protocol CorrectionJudging: Sendable {
  var capabilities: CorrectionJudgeCapabilities { get async }
  /// Answers within the caller's deadline or returns a typed bypass; never
  /// throws, never retries, never alters the text it was asked about.
  func judge(_ request: CorrectionJudgeRequest) async -> CorrectionJudgeOutcome
}
