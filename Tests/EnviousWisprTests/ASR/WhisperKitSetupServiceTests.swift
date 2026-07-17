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

  /// Cloud review P2 (PR #1606): an instant Cancel must beat a download task
  /// that has not entered startDownload yet — otherwise the cancel finds
  /// nothing to cancel and the multi-GB fetch starts AFTER it.
  @Test func aCancelBeatingTheDownloadTaskPreventsTheStartEntirely() async throws {
    final class Box: @unchecked Sendable { var started = 0 }
    let box = Box()
    let service = WhisperKitSetupService(
      readAvailability: { .notDownloaded },
      startDownload: {
        box.started += 1
        return true
      },
      cancelActiveDownload: { true })

    service.downloadModel()
    service.cancelDownload()  // same tick — before the download task body runs

    for _ in 0..<200 where service.setupState != .notDownloaded {
      await Task.yield()
    }
    #expect(box.started == 0, "the outrun download must never start")
    #expect(service.setupState == .notDownloaded)
  }

  /// An ACCEPTED cancel leaves the row to the delivery-state projection —
  /// re-detecting here wiped the paused presentation (founder ruling
  /// 2026-07-17; Codex 2c-r7 P2). The projection then publishes paused and it
  /// STICKS.
  @Test func anAcceptedCancelLeavesTheRowToTheProjection() async throws {
    let service = WhisperKitSetupService(
      readAvailability: { .notDownloaded },
      cancelActiveDownload: { true })
    service.applyDeliveryState(.downloading(progress: 0.5, status: "Downloading model files..."))

    service.cancelDownload()
    for _ in 0..<100 { await Task.yield() }
    if case .downloading = service.setupState {} else {
      Issue.record("cancel itself must not rewrite the row: \(service.setupState)")
    }

    service.applyDeliveryState(.paused)
    #expect(service.setupState == .paused, "the projection's paused sticks")
  }

  // MARK: - 2c: Remove refusal (founder ruling 2.5.4 — refuse, never defer)

  @Test func removeDuringADictationRefusesAndTouchesNothing() async throws {
    final class Box: @unchecked Sendable { var actionCalls = 0 }
    let box = Box()
    let service = WhisperKitSetupService(
      readAvailability: { .ready },
      removeModelAction: {
        box.actionCalls += 1
        return nil
      })
    service.isDictationInFlight = { true }

    service.removeModel()
    for _ in 0..<50 { await Task.yield() }

    #expect(service.removeNotice == .refusedDictationInFlight)
    #expect(box.actionCalls == 0, "a refusal reaches NOTHING downstream")
  }

  @Test func endingTheDictationQueuesNoDeferredDeletion() async throws {
    final class Box: @unchecked Sendable { var actionCalls = 0 }
    let box = Box()
    let service = WhisperKitSetupService(
      readAvailability: { .ready },
      removeModelAction: {
        box.actionCalls += 1
        return nil
      })
    final class Flag: @unchecked Sendable { var inFlight = true }
    let flag = Flag()
    service.isDictationInFlight = { flag.inFlight }

    service.removeModel()
    for _ in 0..<50 { await Task.yield() }
    #expect(service.removeNotice == .refusedDictationInFlight)

    // The dictation ends. NOTHING may fire on its own — the founder's
    // "what the hell" case. A deliberate second press is required.
    flag.inFlight = false
    for _ in 0..<100 { await Task.yield() }
    #expect(box.actionCalls == 0, "no deferred deletion after the dictation ends")

    service.removeModel()
    for _ in 0..<100 where box.actionCalls == 0 { await Task.yield() }
    #expect(box.actionCalls == 1, "the second deliberate press works")
    #expect(service.removeNotice == nil)
  }

  @Test func twoRefusalsInARowAccumulateNoState() async throws {
    final class Box: @unchecked Sendable { var actionCalls = 0 }
    let box = Box()
    let service = WhisperKitSetupService(
      readAvailability: { .ready },
      removeModelAction: {
        box.actionCalls += 1
        return nil
      })
    service.isDictationInFlight = { true }

    service.removeModel()
    service.removeModel()
    for _ in 0..<50 { await Task.yield() }

    #expect(service.removeNotice == .refusedDictationInFlight)
    #expect(box.actionCalls == 0)
  }

  @Test func anUnwiredSessionAuthorityRefusesFailSafe() async throws {
    final class Box: @unchecked Sendable { var actionCalls = 0 }
    let box = Box()
    let service = WhisperKitSetupService(
      readAvailability: { .ready },
      removeModelAction: {
        box.actionCalls += 1
        return nil
      })
    // isDictationInFlight never wired (nil): Remove must refuse, not guess.

    service.removeModel()
    for _ in 0..<50 { await Task.yield() }

    #expect(service.removeNotice == .refusedDictationInFlight)
    #expect(box.actionCalls == 0)
  }

  @Test func aFailedRemovalShowsTheFailureNoticeAndReDetectsDiskTruth() async throws {
    let service = WhisperKitSetupService(
      readAvailability: { .notDownloaded },  // partial deletion: marker gone
      removeModelAction: { .failed })
    service.isDictationInFlight = { false }

    service.removeModel()
    for _ in 0..<200 where service.removeNotice == nil {
      await Task.yield()
    }
    #expect(service.removeNotice == .failed)
    // The row re-detects to DISK truth alongside the notice (Codex 2c-r1 P2):
    // the notice explains the failure; the state shows what is actually there.
    for _ in 0..<200 where service.setupState != .notDownloaded {
      await Task.yield()
    }
    #expect(service.setupState == .notDownloaded)
  }

  // MARK: - 2c founder rulings (2026-07-17)

  @Test func removeCannotBeSpammedWhileTheDrainRuns() async throws {
    final class Box: @unchecked Sendable {
      var calls = 0
      var release: CheckedContinuation<Void, Never>?
    }
    let box = Box()
    let service = WhisperKitSetupService(
      readAvailability: { .notDownloaded },
      removeModelAction: {
        box.calls += 1
        await withCheckedContinuation { box.release = $0 }
        return nil
      })
    service.isDictationInFlight = { false }

    service.removeModel()
    for _ in 0..<50 where box.calls == 0 { await Task.yield() }
    #expect(service.isRemoving, "the row shows Removing while the drain runs")

    // The spam: pressing again while removing reaches NOTHING.
    service.removeModel()
    service.removeModel()
    for _ in 0..<50 { await Task.yield() }
    #expect(box.calls == 1, "one drain, however many presses")

    box.release?.resume()
    box.release = nil
    for _ in 0..<200 where service.isRemoving { await Task.yield() }
    #expect(service.isRemoving == false, "the Removing state clears when the drain ends")
  }

  @Test func aResumableCancelPresentsPausedNotNotDownloaded() async throws {
    let service = WhisperKitSetupService(readAvailability: { .notDownloaded })
    service.applyDeliveryState(.paused)
    #expect(service.setupState == .paused, "paused survives as its own presentation")
  }
}
