import EnviousWisprCore
import Testing

@testable import EnviousWisprASR

/// #2714: `ParakeetBackend.startStreaming()`'s generation-guard race (#1908 chunk A+B round 8, PR #2712)
/// shipped with no test that reaches the actor-level generation counter it protects.
/// `ParakeetEngineAdapterTests` drives a fake ASR manager whose own "generation" is a different, kernel-
/// level retry counter; `ASRManagerBackendInjectionTests`' `FakeASRBackend` is not a `ParakeetBackend`, so
/// `reserveStreamingGeneration()` is never reached there either.
///
/// **What the user sees when this fails:** two dictations started close together cross wires — an older
/// attempt resumes after a newer one has already started streaming, publishes its own manager over the
/// newer one's, and the newer dictation's audio is silently fed into the wrong transcript.
@Suite("ParakeetBackend streaming-generation guard (#2714)", .serialized, .tags(.productOutcome))
struct ParakeetStreamingGenerationTests {

  @Test("reserve/invalidate is a monotonic, single-consumer counter")
  func generationCounterIsMonotonicAndSingleConsumer() async {
    let backend = ParakeetBackend()
    let a = backend.reserveStreamingGeneration()
    let b = backend.reserveStreamingGeneration()
    #expect(b == a &+ 1)

    // A stale attempt's own invalidation is a no-op: nothing current to bump, nothing published to reclaim.
    #expect(backend.invalidateStreamingGeneration(a) == nil)

    // The current attempt's invalidation bumps the counter and hands back a reclaim Task.
    let reclaim = backend.invalidateStreamingGeneration(b)
    #expect(reclaim != nil)
    await reclaim?.value

    // The one bump since `b` was reserved came from invalidating `b`.
    let c = backend.reserveStreamingGeneration()
    #expect(c == b &+ 2)
  }

  @Test(
    "a stale generation never publishes a streaming manager",
    .enabled(if: ParakeetRealBoundaryFixture.shippedModelIsInstalled),
    .tags(.realBoundary)
  )
  func staleGenerationNeverPublishes() async throws {
    try await withParakeetOfflineModeExclusion {
      let backend = ParakeetBackend()
      do {
        try await backend.prepare(
          cacheOnly: true, modelDirectory: ParakeetRealBoundaryFixture.installDirectory,
          progressCallback: nil)

        // Reserve two attempts, A then B, and hand STALE A to the internal entry directly — the
        // deterministic collapse of "A resumes after B already reserved" to its one observable:
        // a stale number must never publish.
        let staleGeneration = backend.reserveStreamingGeneration()
        _ = backend.reserveStreamingGeneration()

        await #expect(throws: CancellationError.self) {
          try await backend.startStreaming(options: .default, generation: staleGeneration)
        }

        do {
          _ = try await backend.finalizeStreaming()
          Issue.record("expected ASRError.streamingNotSupported, got success")
        } catch let error as ASRError {
          switch error {
          case .streamingNotSupported:
            break
          default:
            Issue.record("expected ASRError.streamingNotSupported, got \(error)")
          }
        } catch {
          Issue.record("expected ASRError.streamingNotSupported, got \(error)")
        }

        await backend.unload()
      } catch {
        await backend.unload()
        throw error
      }
    }
  }

  @Test(
    "an abandoned attempt's late arrival still publishes nothing once its generation is reclaimed",
    .enabled(if: ParakeetRealBoundaryFixture.shippedModelIsInstalled),
    .tags(.realBoundary)
  )
  func abandonedAttemptLateArrivalPublishesNothing() async throws {
    try await withParakeetOfflineModeExclusion {
      let backend = ParakeetBackend()
      do {
        try await backend.prepare(
          cacheOnly: true, modelDirectory: ParakeetRealBoundaryFixture.installDirectory,
          progressCallback: nil)

        // The closure `ASRManager.cancelInFlightStreamingStart()` triggers: abandon an attempt
        // BEFORE it publishes, reclaim it (a no-op here, since nothing published yet), then let
        // it enter late anyway.
        let abandonedGeneration = backend.reserveStreamingGeneration()
        let reclaim = backend.invalidateStreamingGeneration(abandonedGeneration)
        #expect(reclaim != nil)
        await reclaim?.value

        await #expect(throws: CancellationError.self) {
          try await backend.startStreaming(options: .default, generation: abandonedGeneration)
        }

        do {
          _ = try await backend.finalizeStreaming()
          Issue.record("expected ASRError.streamingNotSupported, got success")
        } catch let error as ASRError {
          switch error {
          case .streamingNotSupported:
            break
          default:
            Issue.record("expected ASRError.streamingNotSupported, got \(error)")
          }
        } catch {
          Issue.record("expected ASRError.streamingNotSupported, got \(error)")
        }

        await backend.unload()
      } catch {
        await backend.unload()
        throw error
      }
    }
  }
}
