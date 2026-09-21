import Foundation
import Testing

@testable import EnviousWisprCore

/// #996 chunk 5a: the proposal record is the thing the Pending tab, the card
/// and the Accept path all read back from disk. If its identity or its
/// serialisation lies, the user sees a card for the wrong pair, a rejected
/// pair proposed again, or an Accept landing on a different word.
/// Class: `.productOutcome`.
@Suite(.tags(.productOutcome)) struct CorrectionProposalTests {

  // MARK: - Pair key

  @Test("the same pair in different casing and normalisation forms is ONE key")
  func pairKeyFoldsCaseAndNormalisation() {
    let a = CorrectionPairKey.make(original: "Sarah", corrected: "Saira")
    let b = CorrectionPairKey.make(original: "sarah", corrected: "SAIRA")
    // "é" precomposed versus "e" + combining acute: NFC makes them one.
    let c = CorrectionPairKey.make(original: "Jose", corrected: "Jos\u{00E9}")
    let d = CorrectionPairKey.make(original: "Jose", corrected: "Jose\u{0301}")
    #expect(a == b)
    #expect(c == d)
    #expect(a.hasPrefix("v1:["))
  }

  @Test("different pairs, reversed pairs and separator-bearing strings never collide")
  func pairKeyCannotCollide() {
    let forward = CorrectionPairKey.make(original: "Sarah", corrected: "Saira")
    let reversed = CorrectionPairKey.make(original: "Saira", corrected: "Sarah")
    #expect(forward != reversed)
    // An original containing what a naive `a|b` separator scheme would use.
    let tricky1 = CorrectionPairKey.make(original: "a\",\"b", corrected: "c")
    let tricky2 = CorrectionPairKey.make(original: "a", corrected: "b\",\"c")
    #expect(tricky1 != tricky2)
    let quote = CorrectionPairKey.make(original: "say \"hi\"", corrected: "say \\hi")
    #expect(quote != CorrectionPairKey.make(original: "say \\hi", corrected: "say \"hi\""))
  }

  @Test(
    "the key's array decodes back to exactly the two normalised strings with an independent JSON reader"
  )
  func pairKeyIsRealJSON() throws {
    let cases: [(String, String)] = [
      ("Sarah", "Saira"), ("a\",\"b", "c\\d"), ("tab\there", "new\nline"), ("Müller", "Mueller"),
      ("emoji 🙂", "control \u{01}"),
    ]
    for (o, c) in cases {
      let key = CorrectionPairKey.make(original: o, corrected: c)
      let json = String(key.dropFirst("v1:".count))
      let decoded = try JSONDecoder().decode([String].self, from: Data(json.utf8))
      #expect(
        decoded == [CorrectionPairKey.normalise(o), CorrectionPairKey.normalise(c)], "\(o) -> \(c)")
    }
  }

  // MARK: - Record

  @Test("a proposal round-trips through JSON with its identity and every field intact")
  func proposalRoundTrips() throws {
    let created = Date(timeIntervalSince1970: 1_800_000_000)
    let wordID = UUID()
    var p = CorrectionProposal(
      original: "Sarah", corrected: "Saira", state: .existingWord(wordID), language: "en",
      contextExcerpt: "Ask Sarah to review the draft.", sourceBundleID: "com.apple.mail",
      createdAt: created, advisorySafeAlias: true)
    p.status = .accepting
    p.overlayAttempted = true
    p.acceptingIntent = CorrectionAcceptingIntent(
      pairKey: p.pairKey, operation: .addAlias, targetWordID: wordID)
    p.updatedAt = created.addingTimeInterval(5)
    let ledger = CorrectionProposalLedger(
      proposals: [p],
      rejectedPairs: [
        CorrectionRejectedPair(pairKey: "v1:[\"x\",\"y\"]", rejectedAt: created, language: nil)
      ])
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let back = try decoder.decode(CorrectionProposalLedger.self, from: try encoder.encode(ledger))
    #expect(back == ledger)
    #expect(back.proposals[0].state == .existingWord(wordID))
    #expect(
      back.proposals[0].pairKey == CorrectionPairKey.make(original: "Sarah", corrected: "Saira"))
    #expect(back.version == CorrectionProposalLedger.currentVersion)
    #expect(back.openProposals.count == 1)
    #expect(back.isRejected(pairKey: "v1:[\"x\",\"y\"]"))
  }

  @Test("an unknown status is a typed decoding error, never a plausible default")
  func unknownStatusIsRefused() {
    let json = Data(#"{"status":"paused"}"#.utf8)
    struct Probe: Decodable { let status: CorrectionProposalStatus }
    #expect(throws: CorrectionProposalDecodingError.unknownStatus("paused")) {
      _ = try JSONDecoder().decode(Probe.self, from: json)
    }
    for known in CorrectionProposalStatus.allCases {
      let data = Data(#"{"status":"\#(known.rawValue)"}"#.utf8)
      #expect(throws: Never.self) { _ = try JSONDecoder().decode(Probe.self, from: data) }
    }
    #expect(
      CorrectionProposalStatus.accepted.isTerminal && CorrectionProposalStatus.rejected.isTerminal)
    #expect(
      CorrectionProposalStatus.pending.isTerminal == false
        && CorrectionProposalStatus.accepting.isTerminal == false)
  }

  @Test("refreshing metadata keeps identity, creation time, status, the overlay flag and the intent")
  func refreshKeepsIdentity() {
    let wordID = UUID()
    var p = CorrectionProposal(
      original: "Sarah", corrected: "Saira", state: .existingWord(wordID), language: "en",
      contextExcerpt: "first context", sourceBundleID: "com.apple.mail",
      createdAt: Date(timeIntervalSince1970: 1), advisorySafeAlias: nil)
    p.status = .accepting
    p.overlayAttempted = true
    p.acceptingIntent = CorrectionAcceptingIntent(pairKey: p.pairKey, operation: .addAlias, targetWordID: wordID)
    let before = p
    let later = Date(timeIntervalSince1970: 99)
    p.refreshMetadata(contextExcerpt: String(repeating: "y", count: 500), sourceBundleID: "com.apple.Notes", at: later)
    #expect(p.id == before.id && p.pairKey == before.pairKey && p.createdAt == before.createdAt)
    #expect(p.status == before.status && p.overlayAttempted == before.overlayAttempted)
    #expect(p.acceptingIntent == before.acceptingIntent && p.state == before.state)
    #expect(p.sourceBundleID == "com.apple.Notes" && p.updatedAt == later)
    #expect(p.contextExcerpt == String(repeating: "y", count: CorrectionProposal.contextExcerptLimit))
  }

  @Test("the ledger's validation authority names every shape defect and passes a consistent document")
  func validationAuthority() {
    let wordID = UUID()
    var ok = CorrectionProposal(
      original: "Sarah", corrected: "Saira", state: .existingWord(wordID), language: "en",
      contextExcerpt: nil, sourceBundleID: nil, createdAt: Date(), advisorySafeAlias: nil)
    #expect(CorrectionProposalLedger(proposals: [ok]).validationProblems() == [])
    ok.status = .accepting
    #expect(CorrectionProposalLedger(proposals: [ok]).validationProblems().count == 1)
    ok.acceptingIntent = CorrectionAcceptingIntent(pairKey: "v1:[\"x\",\"y\"]", operation: .addAlias, targetWordID: wordID)
    #expect(CorrectionProposalLedger(proposals: [ok]).validationProblems().count == 1, "intent for another pair")
    ok.acceptingIntent = CorrectionAcceptingIntent(pairKey: ok.pairKey, operation: .addAlias, targetWordID: wordID)
    #expect(CorrectionProposalLedger(proposals: [ok]).validationProblems() == [])
    #expect(CorrectionProposalLedger(proposals: [ok, ok]).validationProblems().count == 1, "duplicate id")
    ok.status = .accepted
    #expect(CorrectionProposalLedger(proposals: [ok]).validationProblems().count == 1, "terminal without resolvedAt")
    ok.resolvedAt = Date()
    #expect(CorrectionProposalLedger(proposals: [ok]).validationProblems() == [])
    let dup = CorrectionRejectedPair(pairKey: "k", rejectedAt: Date(), language: nil)
    #expect(CorrectionProposalLedger(rejectedPairs: [dup, dup]).validationProblems().count == 1)
    #expect(CorrectionProposalLedger(version: 7).validationProblems().count == 1)
  }

  @Test("the context excerpt is clamped to 120 UTF-16 units on a character boundary")
  func excerptIsClamped() throws {
    let long = String(repeating: "word ", count: 40) + "🙂"  // 200 units + a surrogate pair
    let p = CorrectionProposal(
      original: "a", corrected: "b", state: .newWord, language: nil, contextExcerpt: long,
      sourceBundleID: nil, createdAt: Date(), advisorySafeAlias: nil)
    let excerpt = try #require(p.contextExcerpt)
    #expect(excerpt.utf16.count <= CorrectionProposal.contextExcerptLimit)
    #expect(long.hasPrefix(excerpt))
    // A string whose 120th unit falls inside a surrogate pair keeps the pair whole or drops it.
    let edge = String(repeating: "x", count: 119) + "🙂" + "tail"
    let clamped = CorrectionProposal.clampExcerpt(edge)
    #expect(clamped == String(repeating: "x", count: 119))
    #expect(CorrectionProposal.clampExcerpt("short") == "short")
  }
}
