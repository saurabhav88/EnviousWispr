import EnviousWisprServices
import Testing

/// The one table deciding which landing results are misses (#3106). Every result against every
/// destination class: the table is small enough to state whole, and a new case must be placed.
@Suite(.tags(.productOutcome))
struct PasteLandingPolicyTests {
  typealias AppClass = TelemetryService.LearnFromEditsTelemetry.AppClass

  static let eligibleAbsent: Set<AppClass> = [.native, .browser, .manualAccessibility]
  static let eligibleNoTarget: Set<AppClass> = [.native, .browser]

  @Test("absent is a miss in a readable-before class; no_target only where focus is honest")
  func misses() {
    for appClass in AppClass.allCases {
      #expect(
        PasteLandingPolicy.isMiss(.absent, appClass: appClass) == Self.eligibleAbsent.contains(appClass),
        "absent in \(appClass.rawValue)")
      #expect(
        PasteLandingPolicy.isMiss(.noTarget, appClass: appClass)
          == Self.eligibleNoTarget.contains(appClass),
        "no_target in \(appClass.rawValue)")
    }
  }

  @Test("found, cannot_read and inconclusive are never misses")
  func neverMisses() {
    var others: [PasteArrivalLanding] = PasteArrivalLanding.Found.allCases.map { .found($0) }
    others += PasteArrivalLanding.CannotRead.allCases.map { .cannotRead($0) }
    others += PasteArrivalLanding.Inconclusive.allCases.map { .inconclusive($0) }
    #expect(others.count == 1 + 5 + 17)
    for landing in others {
      for appClass in AppClass.allCases {
        #expect(
          PasteLandingPolicy.isMiss(landing, appClass: appClass) == false,
          "\(landing.observed)/\(landing.reason) in \(appClass.rawValue)")
      }
    }
  }
}
