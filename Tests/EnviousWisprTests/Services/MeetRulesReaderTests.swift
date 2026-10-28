import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// #4013 r5 step 3: when these fail, a Meet call in Chrome names the wrong person, treats one
/// person shown twice as two, loses an unnamed talker, or the shipped rules stop reading Meet.
///
/// CAPTURED: the Meet rule in the bundled rules file and the tile shapes below come from the C1
/// Meet runs of 2026-10-28 (`docs/audits/2026-10-27-4013/c1m-receipt.txt`): in Chrome and in
/// Safari each participant has one AXGroup tile with class `oZRSLe` holding the name as its first
/// static text; while that person talks, Chrome adds `kssMZb` and `BlxGDf` inside the tile and
/// Safari adds `BlxGDf`. SYNTHETIC: the duplicate, unnamed and nested cases, which those runs did
/// not show.
@Suite("Meet through the talker rules", .tags(.productOutcome))
struct MeetRulesReaderTests {

  private static let good = CallCaptureContext(completeness: .complete, scope: .resolved)
  private static let callURL = "https://meet.google.com/jrh-jmzt-mfn"

  private func bundledRules() throws -> TalkerRules {
    try TalkerRules.decode(
      Data(
        contentsOf: RepoRoot.url.appending(
          path: "Sources/EnviousWisprServices/Resources/talker-rules.json")))
  }

  /// Chrome's shape: the indicator group gains `kssMZb` and `BlxGDf` while talking.
  private func tile(_ name: String?, talking: Bool, inner: [CallAXNode] = []) -> CallAXNode {
    let indicator = CallAXNode(
      role: "AXGroup",
      domClassList: talking ? ["qg7mD", "xm86Be", "BlxGDf", "kssMZb"] : ["qg7mD", "xm86Be"])
    let label = name.map { [CallAXNode(role: "AXStaticText", value: $0)] } ?? []
    return CallAXNode(
      role: "AXGroup", domClassList: ["oZRSLe"], children: label + [indicator] + inner)
  }

  /// Safari's shape: the same tile class; only `BlxGDf` appears while talking.
  private func safariTile(_ name: String, talking: Bool) -> CallAXNode {
    CallAXNode(
      role: "AXGroup", domClassList: ["oZRSLe"],
      children: [
        CallAXNode(role: "AXStaticText", value: name),
        CallAXNode(
          role: "AXGroup",
          domClassList: talking
            ? ["qg7mD", "r6DyN", "xm86Be", "JBY0Kc", "eXUaib", "BlxGDf", "KXY1yb"]
            : ["qg7mD", "r6DyN", "xm86Be", "JBY0Kc", "eXUaib", "KXY1yb"]),
      ])
  }

  private func read(_ tiles: [CallAXNode], rule: SpeakerSelectorRule? = nil) throws
    -> CallSpeakerReading
  {
    let meet = try rule ?? bundledRules().rule(for: .meet)
    return try #require(
      RulesSpeakerReader.read(
        documents: [
          CallAXDocument(url: Self.callURL, root: CallAXNode(role: "AXWebArea", children: tiles))
        ], rule: meet))
  }

  @Test("CAPTURED: the shipped rules read Meet: quiet tiles, then Alex talking")
  func capturedQuietAndTalking() throws {
    let rule = try bundledRules().rule(for: .meet)
    #expect(rule.verification == .verified && rule.tilesAreParticipants && rule.mayReportTalker)
    let quiet = try read([
      tile("Alex Rivera", talking: false), tile("Priya Shah", talking: false),
      tile("Saurabh Vaish", talking: false),
    ])
    #expect(CallSpeakerAdmission.observationSpeaking(quiet, context: Self.good) == [])
    let talking = try read([
      tile("Alex Rivera", talking: true), tile("Priya Shah", talking: false),
      tile("Saurabh Vaish", talking: false),
    ])
    #expect(
      CallSpeakerAdmission.observationSpeaking(talking, context: Self.good) == ["Alex Rivera"])
    #expect(talking.roster.names == ["Alex Rivera", "Priya Shah", "Saurabh Vaish"])
    #expect(!talking.rosterFromParticipantList, "tiles, not a participant list")
    #expect(talking.roster.selfNames.isEmpty, "no self evidence in the capture")
  }

  @Test("CAPTURED: Safari's shape is read by the same rule")
  func capturedSafari() throws {
    let reading = try read([
      safariTile("Saurabh Vaish", talking: false), safariTile("Alex Rivera", talking: false),
      safariTile("Priya Shah", talking: true), safariTile("Sam Safari", talking: false),
    ])
    #expect(CallSpeakerAdmission.observationSpeaking(reading, context: Self.good) == ["Priya Shah"])
    #expect(reading.participants.count == 4)
  }

  @Test("SYNTHETIC: two tiles named Alex are two people; a talking Alex is withheld")
  func duplicateNames() throws {
    let reading = try read([
      tile("Alex Rivera", talking: true), tile("Alex Rivera", talking: false),
    ])
    #expect(reading.roster.names == ["Alex Rivera", "Alex Rivera"])
    #expect(
      CallSpeakerAdmission.admission(of: reading, context: Self.good) == .withheld(.ambiguousTalker)
    )
  }

  @Test("SYNTHETIC: a duplicated quiet name does not stop a unique talker")
  func unrelatedDuplicate() throws {
    let reading = try read([
      tile("Alex Rivera", talking: false), tile("Alex Rivera", talking: false),
      tile("Priya Shah", talking: true),
    ])
    #expect(CallSpeakerAdmission.observationSpeaking(reading, context: Self.good) == ["Priya Shah"])
  }

  @Test("SYNTHETIC: an unnamed talking tile withholds; an unnamed quiet tile does not")
  func unnamedTiles() throws {
    let activeUnnamed = try read([tile(nil, talking: true), tile("Priya Shah", talking: true)])
    #expect(
      CallSpeakerAdmission.admission(of: activeUnnamed, context: Self.good)
        == .withheld(.unnamedTalker))
    let quietUnnamed = try read([tile(nil, talking: false), tile("Priya Shah", talking: true)])
    #expect(
      CallSpeakerAdmission.observationSpeaking(quietUnnamed, context: Self.good) == ["Priya Shah"])
  }

  @Test("SYNTHETIC: a nested tile's name and talking class stay its own")
  func nestedTiles() throws {
    let reading = try read([
      tile(nil, talking: false, inner: [tile("Priya Shah", talking: true)])
    ])
    #expect(reading.participants.map(\.name) == [nil, "Priya Shah"])
    #expect(CallSpeakerAdmission.observationSpeaking(reading, context: Self.good) == ["Priya Shah"])
  }

  @Test("an incomplete, unreadable or unresolved capture of Meet names no one")
  func captureContexts() throws {
    let reading = try read([tile("Alex Rivera", talking: true)])
    for context in [
      CallCaptureContext(completeness: .truncated, scope: .resolved),
      CallCaptureContext(completeness: .unreadable, scope: .resolved),
      CallCaptureContext(completeness: .complete, scope: .unresolved),
    ] {
      #expect(CallSpeakerAdmission.observationSpeaking(reading, context: context) == nil)
    }
  }

  @Test("SYNTHETIC: the same selectors without the declaration leave identity unknown")
  func undeclaredIdentity() throws {
    let declared = try bundledRules().rule(for: .meet)
    let undeclared = SpeakerSelectorRule(
      surface: .meet, tileRole: declared.tileRole, tileClass: declared.tileClass,
      nameSource: declared.nameSource, talkingClasses: declared.talkingClasses,
      participantListClass: nil, verification: declared.verification)
    let reading = try read(
      [tile("Alex Rivera", talking: true), tile("Alex Rivera", talking: false)], rule: undeclared)
    #expect(!reading.participantIdentityEstablished)
    #expect(reading.roster.names == ["Alex Rivera"], "unknown identity: de-duplicated for renaming")
    #expect(
      CallSpeakerAdmission.admission(of: reading, context: Self.good)
        == .withheld(.identityUnestablished))
  }

  @Test("the declaration survives freezing into a recording and thawing for Transcribe again")
  func frozenRoundTrip() throws {
    let data = try Data(
      contentsOf: RepoRoot.url.appending(
        path: "Sources/EnviousWisprServices/Resources/talker-rules.json"))
    let snapshot = try TalkerRulesSnapshot(validating: data, origin: .bundled)
    let thawed = try #require(TalkerRulesSnapshot.thaw(snapshot.frozen))
    #expect(thawed == snapshot.rules)
    #expect(thawed.rule(for: .meet).tilesAreParticipants)
    #expect(thawed.revision == 3)
  }
}
