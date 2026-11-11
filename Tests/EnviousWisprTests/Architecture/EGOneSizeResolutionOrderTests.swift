import Foundation
import Testing

/// #4473 (plan §3.1.1 S4): the EG-1 size preference is set at launch BEFORE model delivery is
/// built, so the install records it reads are the ones the last run left.
///
/// When this fails, an existing EG-1 user can be treated as new: launch work replaces or
/// cleans up the old EG-1 install first, the record is gone when the preference is set, and
/// the user is started on a smaller model. The order lives in one long initializer, so it is
/// held here as the order of the two statements in the source.
@Suite("The EG-1 size preference is set before model delivery starts (#4473)", .tags(.driftGuard))
struct EGOneSizeResolutionOrderTests {
  @Test func thePreferenceIsSetAfterSettingsLoadAndBeforeModelDeliveryIsBuilt() throws {
    let source = try String(
      contentsOf: RepoRoot.sourceURL("Sources/EnviousWisprAppKit/App/WisprBootstrapper.swift"),
      encoding: .utf8)
    func only(_ text: String) throws -> String.Index {
      let ranges = source.ranges(of: text)
      try #require(ranges.count == 1, "\(text) appears \(ranges.count) times")
      return ranges[0].lowerBound
    }
    let settings = try only("let settings = SettingsManager()")
    let resolution = try only("settings.resolveEGOneSizeIfNeeded(")
    let delivery = try only("let modelDelivery = ModelDeliveryHome(")
    #expect(settings < resolution && resolution < delivery)
  }

  // A leftover server of any size is cleared before the launch size starts, or the user's first polish hits a stale one.
  @Test func theLaunchSweepCoversBothServersAndRunsBeforeAnyRuntimeStarts() throws {
    let source = try String(
      contentsOf: RepoRoot.sourceURL("Sources/EnviousWisprAppKit/App/WisprBootstrapper.swift"),
      encoding: .utf8)
    let sweeps = source.ranges(of: "reapOrphansIfIdle(")
    try #require(sweeps.count == 1, "reapOrphansIfIdle( appears \(sweeps.count) times")
    let sweep = sweeps[0].lowerBound

    // The loop that makes the call names both server binaries.
    let loopHeads = source.ranges(of: "for binary in [llamaServerBinaryURL, egOneHelperURL]")
    try #require(loopHeads.count == 1, "the sweep loop appears \(loopHeads.count) times")
    #expect(loopHeads[0].lowerBound < sweep)
    #expect(source.distance(from: loopHeads[0].lowerBound, to: sweep) < 400, "the call is in that loop")

    let starts = source.ranges(of: "startIfActiveProvider()").map(\.lowerBound)
    #expect(starts.allSatisfy { $0 > sweep }, "a runtime starts before the sweep")
    #expect(starts.contains { $0 > sweep }, "no runtime start follows the sweep")
  }
}
