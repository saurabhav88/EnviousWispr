@preconcurrency import AVFoundation
import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprStorage
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// Phase G3 — locks the new `internal init` overload on `TranscriptionPipeline`.
/// The seam lets `@testable` callers swap in a `TranscriptFinalizer` built from
/// closure mocks, so future heart-path tests can drive end-to-end through the
/// pipeline (paste, persistence, finalization) instead of around it via the
/// HeartPathHarness side-channel that PR #391 was forced to use.
///
/// Full state-machine scenarios stay in `HeartPathIntegrationTests`. G3 only
/// needs to demonstrate the seam is reachable from `@testable import`.
@MainActor
@Suite("TranscriptionPipeline injection (Phase G3)")
struct TranscriptionPipelineInjectionTests {

  @Test("Internal init wires an injected TranscriptFinalizer instead of the default one")
  func internalInitWiresInjectedFinalizer() async throws {
    let fixture = try SyntheticAudioFixture.make(
      fileName: "g3-injection-smoke.wav",
      pattern: .toneBurst
    )
    let audioCapture = try FixtureAudioCapture(fixtureURL: fixture.url)
    let asrManager = MockASRManager(
      transcribeBehavior: .success(
        ASRResult(
          text: "hello",
          language: "en",
          duration: fixture.durationSeconds,
          processingTime: 0.01,
          backendType: .parakeet
        )
      )
    )

    // Closure-mocked finalizer — same shape as TranscriptFinalizerTests uses.
    // The init only needs to ACCEPT this; verifying the pipeline drives it
    // end-to-end is HeartPathIntegrationTests' job.
    let saved = SavedBox()
    let pasteCount = CountBox()
    let finalizer = TranscriptFinalizer(
      save: { saved.append($0) },
      deliverPaste: { _ in
        pasteCount.increment()
        return PasteDeliveryResult(
          tier: .axDirect,
          durationMs: 0,
          outcome: .delivered(tier: .axDirect, durationMs: 0))
      }
    )

    let pipeline = TranscriptionPipeline(
      audioCapture: audioCapture,
      asrManager: asrManager,
      transcriptStore: TranscriptStore(),
      transcriptFinalizer: finalizer
    )

    // Pipeline starts idle; no transcription/paste invoked yet.
    #expect(pipeline.state == .idle)
    #expect(pipeline.currentTranscript == nil)
    #expect(saved.count == 0)
    #expect(pasteCount.value == 0)
  }

  @Test("Public convenience init still produces a working default-finalizer pipeline")
  func publicInitStillWorksAfterG3Split() async throws {
    let fixture = try SyntheticAudioFixture.make(
      fileName: "g3-public-init-smoke.wav",
      pattern: .toneBurst
    )
    let audioCapture = try FixtureAudioCapture(fixtureURL: fixture.url)
    let asrManager = MockASRManager(
      transcribeBehavior: .success(
        ASRResult(
          text: "hello",
          language: "en",
          duration: fixture.durationSeconds,
          processingTime: 0.01,
          backendType: .parakeet
        )
      )
    )

    let pipeline = TranscriptionPipeline(
      audioCapture: audioCapture,
      asrManager: asrManager,
      transcriptStore: TranscriptStore()
    )
    #expect(pipeline.state == .idle)
    #expect(pipeline.currentTranscript == nil)
  }
}

@MainActor
private final class SavedBox {
  private(set) var transcripts: [Transcript] = []
  var count: Int { transcripts.count }
  func append(_ t: Transcript) { transcripts.append(t) }
}

@MainActor
private final class CountBox {
  private(set) var value: Int = 0
  func increment() { value += 1 }
}
