import Foundation
import Testing

@testable import EnviousWisprASR

/// #1386 PR-2b. The Settings-row presenter over the injected delivery actions.
@Suite @MainActor struct WhisperKitSetupServiceTests {

  /// Codex 2b-r1 P2: a REFUSED download (kill switch off, no wiring) publishes no
  /// delivery state, so the optimistic "Starting download..." would stick forever.
  /// The refusal must re-detect back to honest truth.
  @Test func aRefusedDownloadReturnsTheRowToHonestStateInsteadOfStickingForever() async throws {
    let service = WhisperKitSetupService(
      readAvailability: { .notDownloaded },
      startDownload: { false })

    service.downloadModel()
    if case .downloading = service.setupState {
    } else {
      Issue.record("the optimistic state shows first: \(service.setupState)")
    }

    // Signal, not clock: the refusal path ends in forceDetectState, whose result
    // is the observable we wait on.
    for _ in 0..<200 where service.setupState != .notDownloaded {
      await Task.yield()
    }
    #expect(service.setupState == .notDownloaded)
  }

  /// An ACCEPTED download keeps the optimistic state — progress arrives via the
  /// delivery-state projection, not via detection.
  @Test func anAcceptedDownloadKeepsTheOptimisticStateForTheProjection() async throws {
    let service = WhisperKitSetupService(
      readAvailability: { .notDownloaded },
      startDownload: { true })

    service.downloadModel()
    for _ in 0..<50 { await Task.yield() }

    if case .downloading = service.setupState {
    } else {
      Issue.record("accepted download must not re-detect away: \(service.setupState)")
    }
  }

  /// Codex 2b-r3 P2: a REFUSED cancel (the coordinator could not clear the owed
  /// marker) means the fetch is still running — re-detecting to "not downloaded"
  /// would lie. The row must keep showing the live download.
  @Test func aRefusedCancelKeepsShowingTheRunningFetch() async throws {
    let service = WhisperKitSetupService(
      readAvailability: { .notDownloaded },
      cancelActiveDownload: { false })
    service.applyDeliveryState(.downloading(progress: 0.5, status: "Downloading model files..."))

    service.cancelDownload()
    for _ in 0..<50 { await Task.yield() }

    if case .downloading = service.setupState {} else {
      Issue.record("refused cancel must not re-detect away: \(service.setupState)")
    }
  }

  /// An ACCEPTED cancel re-detects to honest truth.
  @Test func anAcceptedCancelReturnsTheRowToDetectedTruth() async throws {
    let service = WhisperKitSetupService(
      readAvailability: { .notDownloaded },
      cancelActiveDownload: { true })
    service.applyDeliveryState(.downloading(progress: 0.5, status: "Downloading model files..."))

    service.cancelDownload()
    for _ in 0..<200 where service.setupState != .notDownloaded {
      await Task.yield()
    }
    #expect(service.setupState == .notDownloaded)
  }
}
