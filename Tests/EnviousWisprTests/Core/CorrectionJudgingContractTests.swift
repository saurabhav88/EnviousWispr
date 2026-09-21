import EnviousWisprCore
import Foundation
import Testing

/// The correction-judge contract (#996): the shape every judge arm answers
/// through. Drift guard: when this fails we changed the seam, not what the
/// user sees.
@Suite("CorrectionJudging contract (#996)", .tags(.driftGuard))
struct CorrectionJudgingContractTests {

  private func request(
    _ candidates: [CorrectionCandidate], context: String = "send it to Elena today"
  )
    throws -> CorrectionJudgeRequest
  {
    try CorrectionJudgeRequest(candidates: candidates, context: context, language: "en")
  }

  @Test("the three classes map to the two booleans and (false, true) is not a class")
  func classMapping() {
    #expect(CorrectionJudgeClass.notCorrection.vocabularyCorrection == false)
    #expect(CorrectionJudgeClass.notCorrection.safeAlias == false)
    #expect(CorrectionJudgeClass.correctionButUnsafe.vocabularyCorrection == true)
    #expect(CorrectionJudgeClass.correctionButUnsafe.safeAlias == false)
    #expect(CorrectionJudgeClass.correctionAndSafe.vocabularyCorrection == true)
    #expect(CorrectionJudgeClass.correctionAndSafe.safeAlias == true)
    for cls in CorrectionJudgeClass.allCases {
      #expect(
        CorrectionJudgeClass(
          vocabularyCorrection: cls.vocabularyCorrection, safeAlias: cls.safeAlias) == cls)
    }
    #expect(CorrectionJudgeClass(vocabularyCorrection: false, safeAlias: true) == nil)
    #expect(CorrectionJudgeClass.allCases.count == 3)
  }

  @Test("a request keeps 1 to 4 unique, non-empty, changed candidates sorted by id")
  func requestShape() throws {
    let r = try request([
      CorrectionCandidate(id: 2, original: "Elena", replacement: "Alina"),
      CorrectionCandidate(id: 1, original: "cuber netties", replacement: "Kubernetes"),
    ])
    #expect(r.candidates.map(\.id) == [1, 2])
    #expect(r.language == "en")
    #expect(CorrectionJudgeRequest.maxCandidates == 4)
  }

  @Test("every malformed request shape is refused by name")
  func requestRefusals() {
    let ok = CorrectionCandidate(id: 1, original: "a", replacement: "b")
    #expect(throws: CorrectionJudgeRequestError.noCandidates) { try request([]) }
    #expect(throws: CorrectionJudgeRequestError.tooManyCandidates(5)) {
      try request(
        (1...5).map { CorrectionCandidate(id: $0, original: "a\($0)", replacement: "b\($0)") })
    }
    #expect(throws: CorrectionJudgeRequestError.duplicateID(1)) {
      try request([ok, CorrectionCandidate(id: 1, original: "c", replacement: "d")])
    }
    #expect(throws: CorrectionJudgeRequestError.idOutOfRange(0)) {
      try request([CorrectionCandidate(id: 0, original: "a", replacement: "b")])
    }
    #expect(throws: CorrectionJudgeRequestError.idOutOfRange(5)) {
      try request([CorrectionCandidate(id: 5, original: "a", replacement: "b")])
    }
    #expect(throws: CorrectionJudgeRequestError.emptyRun(id: 1)) {
      try request([CorrectionCandidate(id: 1, original: "  ", replacement: "b")])
    }
    #expect(throws: CorrectionJudgeRequestError.unchangedRun(id: 1)) {
      try request([CorrectionCandidate(id: 1, original: "same ", replacement: "same")])
    }
    let long = String(repeating: "x", count: CorrectionJudgeRequest.maxContextUTF16 + 1)
    #expect(throws: CorrectionJudgeRequestError.contextTooLong(long.utf16.count)) {
      try request([ok], context: long)
    }
    // Exactly at the cap is accepted; the unit is UTF-16, so an emoji counts two.
    let atCap = String(repeating: "x", count: CorrectionJudgeRequest.maxContextUTF16)
    #expect((try? request([ok], context: atCap)) != nil)
    let emoji = String(repeating: "x", count: CorrectionJudgeRequest.maxContextUTF16 - 1) + "😀"
    #expect(emoji.utf16.count == CorrectionJudgeRequest.maxContextUTF16 + 1)
    #expect((try? request([ok], context: emoji)) == nil)
  }

  @Test(
    "validated() accepts exactly one decision per id and rejects missing, extra, duplicate and padded sets"
  )
  func validatedOutcome() throws {
    let r = try request([
      CorrectionCandidate(id: 1, original: "a", replacement: "b"),
      CorrectionCandidate(id: 3, original: "c", replacement: "d"),
    ])
    let complete = [
      CorrectionJudgeDecision(id: 3, verdict: .notCorrection),
      CorrectionJudgeDecision(id: 1, verdict: .correctionAndSafe),
    ]
    #expect(
      CorrectionJudgeOutcome.validated(complete, for: r)
        == .verdict([
          CorrectionJudgeDecision(id: 1, verdict: .correctionAndSafe),
          CorrectionJudgeDecision(id: 3, verdict: .notCorrection),
        ]))
    #expect(CorrectionJudgeOutcome.validated([complete[1]], for: r) == .bypass(.malformed))
    #expect(
      CorrectionJudgeOutcome.validated(
        complete + [CorrectionJudgeDecision(id: 2, verdict: .notCorrection)], for: r)
        == .bypass(.malformed))
    #expect(
      CorrectionJudgeOutcome.validated([complete[1], complete[1]], for: r) == .bypass(.malformed))
    #expect(CorrectionJudgeOutcome.validated([], for: r) == .bypass(.malformed))
    // Duplicate id with a differing verdict cannot be repaired into a verdict.
    #expect(
      CorrectionJudgeOutcome.validated(
        [complete[0], CorrectionJudgeDecision(id: 3, verdict: .correctionAndSafe)], for: r)
        == .bypass(.malformed))
  }

  @Test("the bypass set is the five typed reasons and nothing else")
  func bypassSet() {
    #expect(
      CorrectionJudgeBypass.allCases.map(\.rawValue) == [
        "unavailable", "notGranted", "deadline", "cancelled", "malformed",
      ])
  }

  @Test("capabilities carry an execution identity and a nil language set grants nothing")
  func capabilities() {
    let caps = CorrectionJudgeCapabilities(
      canRunOnThisMac: true, supportedLanguages: nil, executionIdentity: ["config_sha256": "abc"])
    #expect(caps.supportedLanguages == nil)
    #expect(caps.executionIdentity["config_sha256"] == "abc")
  }
}
