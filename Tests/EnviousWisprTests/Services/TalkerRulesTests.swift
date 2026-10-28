import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// #4013: when these fail, a broken rules file names the wrong person on Meet, Teams web or Slack,
/// or the app silently ignores a fixed rules file and keeps the old one.
///
/// The fixtures in `website/scripts/talker-rules-fixtures.json` are literal documents that the
/// website check (`check-talker-rules.mjs`) also runs, so the app's decoder and the website's
/// check must agree on every one. The selector tokens in them are fixture text, not verified rules.
@Suite("Talker rules document", .tags(.productOutcome))
struct TalkerRulesTests {

  private static let hostedPath = "website/public/meet/talker-rules.json"
  private static let bundledPath = "Sources/EnviousWisprServices/Resources/talker-rules.json"
  private static let fixturesPath = "website/scripts/talker-rules-fixtures.json"

  private func repoFile(_ path: String) throws -> Data {
    try Data(contentsOf: RepoRoot.url.appending(path: path))
  }

  @Test("the packaged rules file resolves through the app's own lookup and validates")
  func packagedResource() throws {
    let url = try #require(TalkerRulesStore.bundledURL)
    let snapshot = try TalkerRulesSnapshot(validating: Data(contentsOf: url), origin: .bundled)
    #expect(snapshot.rules.schema == TalkerRules.supportedSchema)
  }

  @Test("the hosted file is the bundled file, byte for byte")
  func hostedMatchesBundled() throws {
    let hosted = try repoFile(Self.hostedPath)
    #expect(hosted == (try repoFile(Self.bundledPath)))
    let packaged = try Data(contentsOf: #require(TalkerRulesStore.bundledURL))
    #expect(hosted == packaged)
    _ = try TalkerRules.decode(hosted)
  }

  @Test("every shared fixture is accepted or refused as the website check expects")
  func sharedFixtures() throws {
    let root = try #require(
      try JSONSerialization.jsonObject(with: repoFile(Self.fixturesPath)) as? [String: Any])
    let fixtures = try #require(root["fixtures"] as? [[String: Any]])
    var accepted = 0
    var refused = 0
    for fixture in fixtures {
      let name = try #require(fixture["name"] as? String)
      let accept = try #require(fixture["accept"] as? Bool)
      let document = try #require(fixture["document"])
      let data = try JSONSerialization.data(withJSONObject: document, options: [.fragmentsAllowed])
      let result = Result { () throws(TalkerRules.DecodeError) in try TalkerRules.decode(data) }
      switch (accept, result) {
      case (true, .success): accepted += 1
      case (false, .failure): refused += 1
      case (true, .failure(let error)):
        Issue.record("\(name): refused (\(error)) but the fixture says it is valid")
      case (false, .success):
        Issue.record("\(name): accepted but the fixture says it is invalid")
      }
    }
    #expect(accepted >= 2)
    #expect(refused >= 30)
  }

  @Test("the full fixture decodes to exactly the rules it states")
  func decodedValues() throws {
    let data = Data(
      #"""
      {"schema":1,"revision":7,"lagMs":{"zoom_app":400,"meet":-120},"selectors":[
        {"surface":"meet","tileClass":"dkjMxf","nameSource":"firstStaticText",
         "talkingClasses":["kssMZb"],"participantListClass":"people-list","verification":"verified"},
        {"surface":"teams_web","tileRole":"AXMenuItem","nameSource":"ownLabel",
         "nameSuffix":" Unverified","talkingClasses":[],"verification":"unverified"}]}
      """#.utf8)
    let rules = try TalkerRules.decode(data)
    #expect(rules.revision == 7)
    #expect(rules.lag(for: .zoomApp) == CallSpeakerLag(milliseconds: 400))
    #expect(rules.lag(for: .meet) == CallSpeakerLag(milliseconds: -120))
    // Unmeasured stays absent, never zero.
    #expect(rules.lag(for: .teamsApp) == nil)
    #expect(
      rules.rule(for: .meet)
        == SpeakerSelectorRule(
          surface: .meet, tileRole: nil, tileClass: "dkjMxf", nameSource: .firstStaticText,
          talkingClasses: ["kssMZb"], participantListClass: "people-list", verification: .verified))
    #expect(
      rules.rule(for: .teamsWeb)
        == SpeakerSelectorRule(
          surface: .teamsWeb, tileRole: "AXMenuItem", tileClass: nil,
          nameSource: .ownLabel(removingSuffix: " Unverified"), talkingClasses: [],
          participantListClass: nil, verification: .unverified))
    #expect(rules.rule(for: .slackWeb) == .unconfigured(.slackWeb))
  }

  @Test("text that is too large, not UTF-8 or not JSON is refused before any rule is read")
  func rawRefusals() {
    func error(_ data: Data) -> TalkerRules.DecodeError? {
      do {
        _ = try TalkerRules.decode(data)
        return nil
      } catch {
        return error
      }
    }
    let padded =
      #"{"schema":1,"revision":1,"lagMs":{},"selectors":[]}"#
      + String(repeating: " ", count: TalkerRules.maximumBytes)
    #expect(error(Data(padded.utf8)) == .tooLarge)
    #expect(error(Data([0xFF, 0xFE, 0x7B, 0x7D])) == .notUTF8)
    #expect(error(Data("{schema: 1}".utf8)) == .notJSON)
    #expect(
      error(Data(#"{"schema":2,"revision":1,"lagMs":{},"selectors":[]}"#.utf8))
        == .unsupportedSchema)
  }

  @Test("the empty snapshot's frozen text decodes to its own rules")
  func emptySnapshot() throws {
    let empty = TalkerRulesSnapshot.empty
    #expect(try TalkerRules.decode(Data(empty.frozen.payload.utf8)) == empty.rules)
    #expect(empty.frozen.version == TalkerRules.supportedSchema)
    #expect(CallSpeakerSurface.allCases.allSatisfy { empty.rules.lag(for: $0) == nil })
    #expect(
      CallSpeakerSurface.allCases.allSatisfy { empty.rules.rule(for: $0) == .unconfigured($0) })
  }

  @Test("a frozen snapshot thaws to the same rules; a newer schema does not thaw")
  func thaw() throws {
    let text = #"{"schema":1,"revision":2,"lagMs":{"meet":80},"selectors":[]}"#
    let snapshot = try TalkerRulesSnapshot(validating: Data(text.utf8), origin: .downloaded)
    #expect(snapshot.frozen.payload == text)
    #expect(TalkerRulesSnapshot.thaw(snapshot.frozen) == snapshot.rules)
    #expect(
      TalkerRulesSnapshot.thaw(FrozenTalkerRules(version: 2, payload: #"{"schema":2}"#)) == nil)
    // An envelope whose version disagrees with its valid schema-1 text does not thaw either.
    #expect(TalkerRulesSnapshot.thaw(FrozenTalkerRules(version: 2, payload: text)) == nil)
    #expect(TalkerRulesSnapshot.thaw(FrozenTalkerRules(version: 0, payload: text)) == nil)
  }
}
