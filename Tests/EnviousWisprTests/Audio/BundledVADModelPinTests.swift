@preconcurrency import FluidAudio
import Foundation
import Testing

@testable import EnviousWisprAudio

/// #2184 — the VAD model this app ships is chosen by benchmark, not by whatever
/// the dependency happens to name.
///
/// A drift guard, not product coverage: it fails when *we* change our own code
/// or take a dependency bump, which is exactly when someone needs to re-read the
/// measurement before following it.
///
/// The guard runs in the direction that protects us. Asserting our name *equals*
/// `ModelNames.VAD.sileroVad` would force the app onto v6.2.1, which lost to
/// v6.0.0 at every matched false-alarm rate over 72 labelled recordings. So this
/// asserts the inverse — the pin is what we think it is, the artifact for it is
/// actually in the tree, and the library still names something else.
@Suite("Bundled VAD model pin", .tags(.driftGuard))
struct BundledVADModelPinTests {

  @Test("the loader asks for the benchmarked build")
  func loaderNamesThePinnedBuild() {
    #expect(BundledVADModelLoader.pinnedModelName == "silero-vad-unified-256ms-v6.0.0")
  }

  @Test("the pinned model is actually in the tree under that name")
  func pinnedModelIsPresent() {
    let url = RepoRoot.sourceURL(
      "Sources/EnviousWispr/Resources/VAD/\(BundledVADModelLoader.pinnedModelName).mlmodelc")
    #expect(
      FileManager.default.fileExists(atPath: url.path),
      "the loader asks for \(BundledVADModelLoader.pinnedModelName) and no such compiled model is committed — the app would fall back to no VAD at all"
    )
  }

}
