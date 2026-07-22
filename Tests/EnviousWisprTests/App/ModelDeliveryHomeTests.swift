import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit

/// #1741 Chunk 6 — pins the gate-refusal contract for `ModelDeliveryHome`'s
/// two Settings-row mutation sites (Parakeet Cancel/Resume).
@MainActor
@Suite("ModelDeliveryHome — engine mutation gate refusal")
struct ModelDeliveryHomeTests {

  /// Production's trust root is the signed app's own `Bundle.main` (contract
  /// §4a), which a unit-test process cannot see — these resources ride the
  /// `EnviousWispr` app target, not any framework or test bundle. Rather than
  /// author a divergent fixture, point at a `Bundle` over the SAME committed
  /// manifest files `ModelDeliveryHome` loads in production. Same repo-root
  /// discovery as `ParakeetShippedManifestTests.repoRoot`
  /// (`Tests/EnviousWisprTests/ModelDelivery/DeliveryManifestTests.swift`).
  private static func manifestBundle() throws -> Bundle {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // (file)
      .deletingLastPathComponent()  // App
      .deletingLastPathComponent()  // EnviousWisprTests
      .deletingLastPathComponent()  // Tests
    let resourcesDir = repoRoot.appendingPathComponent("Sources/EnviousWispr/Resources")
    return try #require(Bundle(url: resourcesDir))
  }

  @Test("a gate-refused cancel reports the site and never releases or wakes")
  func aGateRefusedCancelReportsTheSiteAndNeverReleasesOrWakes() async throws {
    final class Box: @unchecked Sendable {
      var endCalls = 0
      var wakeCalls = 0
      var refusedSites: [String] = []
    }
    let box = Box()
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { false },
        end: {
          box.endCalls += 1
          return false
        },
        wake: { box.wakeCalls += 1 },
        onRefused: { box.refusedSites.append($0) }),
      manifestBundle: try Self.manifestBundle())

    home.cancelParakeetDownload()
    // Signal, not clock: wait for the gate's own refusal telemetry, proving
    // the Task actually reached and was refused by the claim, before
    // asserting the negatives that a refusal implies.
    for _ in 0..<200 where box.refusedSites.isEmpty { await Task.yield() }

    #expect(box.refusedSites == ["parakeetCancelDownload"])
    #expect(box.endCalls == 0, "a refused claim is never released")
    #expect(box.wakeCalls == 0, "a refused claim never owes a wake")
  }

  @Test("a gate-refused resume reports the site and never releases or wakes")
  func aGateRefusedResumeReportsTheSiteAndNeverReleasesOrWakes() async throws {
    final class Box: @unchecked Sendable {
      var endCalls = 0
      var wakeCalls = 0
      var refusedSites: [String] = []
    }
    let box = Box()
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { false },
        end: {
          box.endCalls += 1
          return false
        },
        wake: { box.wakeCalls += 1 },
        onRefused: { box.refusedSites.append($0) }),
      manifestBundle: try Self.manifestBundle())

    home.resumeParakeetDownload()
    // Signal, not clock: wait for the gate's own refusal telemetry, proving
    // the Task actually reached and was refused by the claim, before
    // asserting the negatives that a refusal implies.
    for _ in 0..<200 where box.refusedSites.isEmpty { await Task.yield() }

    #expect(box.refusedSites == ["parakeetResumeDownload"])
    #expect(box.endCalls == 0, "a refused claim is never released")
    #expect(box.wakeCalls == 0, "a refused claim never owes a wake")
  }
}
