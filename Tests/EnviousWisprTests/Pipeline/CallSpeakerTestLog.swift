import EnviousWisprCore
import Foundation

@testable import EnviousWisprServices

/// SYNTHETIC saved speaker evidence in the shape the observer will save (#4013 chunk 12A): a
/// Google Meet log read through the bundled rules, with the +500 ms configured correction, one
/// talking name every 500 ms. Names and times are made up; only the rules file is real.
enum CallSpeakerTestLog {
  static func meet(
    roster: [String] = ["Alex Rivera", "Priya Shah"], talking: String = "Alex Rivera",
    fromMs: Int = 1_000, toMs: Int = 9_000
  ) throws -> CallSpeakerLog {
    let bundled = try Data(
      contentsOf: RepoRoot.url.appending(
        path: "Sources/EnviousWisprServices/Resources/talker-rules.json"))
    let snapshot = try TalkerRulesSnapshot(validating: bundled, origin: .bundled)
    return CallSpeakerLog(
      surface: .meet, source: .rules, status: .observed,
      lag: CallSpeakerLag(milliseconds: 500), rules: snapshot.frozen,
      roster: CallSpeakerRoster(names: roster, selfNames: []), rosterFromParticipantList: false,
      observations: stride(from: fromMs, through: toMs, by: 500).map {
        CallSpeakerObservation(observationMs: $0, speaking: [talking])
      })
  }
}
