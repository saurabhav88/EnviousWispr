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
}
