import Foundation
import Testing
#if DEBUG
  @testable import EnviousWisprPipeline
#endif

/// #4896 release containment: `fail_whisper_backend` helpers must never ship in a Release `.app`
/// (`SWIFT_PACKAGE` builds no `.app` bundle, so only Xcode Release runs the bundle scan).
#if DEBUG || !SWIFT_PACKAGE
  @Suite("Whisper debug fault release containment (#4896)", .tags(.productOutcome))
  struct WhisperDebugFaultReleaseContainmentTests {
    #if DEBUG
      @Test("DEBUG build exercises the status-8 fault controller") @MainActor
      func debugBuildProvidesStatus8FaultController() {
        let c = BatchDecodeFaultController(whisperBackend: nil, asrManager: nil)
        c.failWhisperBackendStatus8(count: 1)
        #expect(c.shouldForceWhisperStatus8() && !c.shouldForceWhisperStatus8())
      }
    #elseif !SWIFT_PACKAGE
      private final class Anchor {}

      @Test("fail_whisper_backend strings are absent from the Release app executable")
      func releaseArtifactCarriesNoWhisperFaultSeam() throws {
        let app = Bundle.main.bundleURL.pathExtension == "app"
          ? Bundle.main.bundleURL
          : Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("EnviousWispr.app")
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/MacOS/EnviousWispr"), options: .mappedIfSafe)
        for s in ["fail_whisper_backend", "failWhisperBackendStatus8", "shouldForceWhisperStatus8", "whisperStatus8Remaining"] {
          #expect(data.range(of: Data(s.utf8)) == nil, "Release binary leaked \(s)")
        }
      }
    #endif
  }
#endif
