import Foundation
import Testing

@testable import EnviousWisprWordCheck

/// The real word-check model on this Mac gives its memory back when its last holder lets go
/// (#3289). When this fails, the app unloads Kev after ten idle minutes and MLX still holds the
/// model's buffers. Runs where the model has been downloaded; skipped elsewhere, including CI, which
/// has no model.
///
/// MLX's counters are process-wide and other suites may evaluate MLX in parallel, so the test
/// asserts on the drop across the model's own release, measured inside its deinit, with a margin far
/// below the weights' size rather than an exact figure.
@Suite("Kev word check: releasing the model frees its MLX memory (#3289)", .tags(.productOutcome))
struct KevModelReleaseTests {
  struct Release: Sendable {
    let activeBefore: Int
    let activeAfter: Int
    let cacheAfter: Int
  }

  @Test(
    "the last holder letting go drops the weights and empties MLX's cache",
    .enabled(if: KevBatchParityTests.modelPresent))
  func releaseFreesMemory() async throws {
    let (released, signal) = AsyncStream.makeStream(of: Release.self)
    var model: KevWordCheckModel? = try await KevWordCheckModel(
      folder: KevBatchParityTests.folder,
      onRelease: { before, after, cache in
        signal.yield(Release(activeBefore: before, activeAfter: after, cacheAfter: cache))
      })
    // Evaluate once, so the release has working buffers to clear as well as weights.
    try await model?.warmUp()
    model = nil
    // The last reference may be dropped on another executor, so the deinit can land after this
    // line: wait for the model's own signal, bounded only so a broken build cannot hang the suite.
    let release = await withTaskGroup(of: Release?.self) { group in
      group.addTask {
        for await release in released { return release }
        return nil
      }
      group.addTask {
        // settle: deadline fallback around the release signal above; never asserted on
        try? await Task.sleep(for: .seconds(10))
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
    let observed = try #require(
      release, "the model was never released after its last holder let go")
    let freed = observed.activeBefore - observed.activeAfter
    // The weights alone are about 486 MB; a release that frees under 300 MB kept them.
    #expect(freed > 300 << 20, "released only \(freed >> 20) MB of MLX memory")
    #expect(
      observed.cacheAfter < 64 << 20,
      "MLX kept \(observed.cacheAfter >> 20) MB cached after release")
  }
}
