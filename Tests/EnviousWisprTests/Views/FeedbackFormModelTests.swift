import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// #3269: the "Include diagnostics" consent in Send Feedback. Loads are gated by the test, so
/// every ordering (a slow load, a switch flip, a close) is driven explicitly with no sleeps.
@MainActor
@Suite("Feedback form diagnostics consent (#3269)", .tags(.productOutcome))
struct FeedbackFormModelTests {

  /// A loader that parks each call until the test releases it. The arrival signal is sent in the
  /// same main-actor step as the park, so a release never races an empty gate.
  @MainActor
  final class GatedLoader {
    private var waiting: [CheckedContinuation<FeedbackDiagnosticsSnapshot?, Never>] = []
    /// Parked loads nobody has waited for yet, and the one test waiting for the next park.
    private var unclaimedArrivals = 0
    private var arrivalWaiter: CheckedContinuation<Void, Never>?

    func load() async -> FeedbackDiagnosticsSnapshot? {
      await withCheckedContinuation { continuation in
        waiting.append(continuation)
        if let waiter = arrivalWaiter {
          arrivalWaiter = nil
          waiter.resume()
        } else {
          unclaimedArrivals += 1
        }
      }
    }

    /// Waits for the next load to park and leaves it parked.
    func waitForArrival() async {
      if unclaimedArrivals > 0 {
        unclaimedArrivals -= 1
        return
      }
      await withCheckedContinuation { arrivalWaiter = $0 }
    }

    /// Waits for the next load to park, then answers the oldest parked load.
    func answerNext(with snapshot: FeedbackDiagnosticsSnapshot?) async {
      await waitForArrival()
      answerOldest(with: snapshot)
    }

    func answerOldest(with snapshot: FeedbackDiagnosticsSnapshot?) {
      waiting.removeFirst().resume(returning: snapshot)
    }
  }

  static let first = FeedbackDiagnosticsSnapshot(data: Data(#"{"first":true}"#.utf8))
  static let second = FeedbackDiagnosticsSnapshot(data: Data(#"{"second":true}"#.utf8))

  private func makeModel() -> (FeedbackFormModel, GatedLoader) {
    let loader = GatedLoader()
    return (FeedbackFormModel(loadSnapshot: { await loader.load() }), loader)
  }

  @Test("Metrics ON: the box starts ticked, and Send attaches exactly the previewed bytes")
  func metricsOnDefaultsTicked() async {
    let (model, loader) = makeModel()
    model.open(usageMetrics: true)
    #expect(model.includeDiagnostics == true)
    #expect(model.diagnostics == .loading)

    await loader.answerNext(with: Self.first)
    await model.loadTask?.value

    #expect(model.previewSnapshot == Self.first)
    #expect(model.decideSend(currentUsageMetrics: true) == .send(Self.first))
  }

  @Test("Metrics OFF: the box starts unticked and sends nothing until the user ticks it")
  func metricsOffDefaultsUnticked() async {
    let (model, loader) = makeModel()
    model.open(usageMetrics: false)
    await loader.answerNext(with: Self.first)
    await model.loadTask?.value

    #expect(model.includeDiagnostics == false)
    #expect(model.previewSnapshot == nil)
    #expect(model.decideSend(currentUsageMetrics: false) == .send(nil))

    model.setIncludeDiagnostics(true)
    #expect(model.previewSnapshot == Self.first)
    #expect(model.decideSend(currentUsageMetrics: false) == .send(Self.first))
  }

  @Test("No snapshot: the box is unticked and locked, and plain feedback still sends")
  func unavailableLocksTheBox() async {
    let (model, loader) = makeModel()
    model.open(usageMetrics: true)
    await loader.answerNext(with: nil)
    await model.loadTask?.value

    #expect(model.diagnostics == .unavailable)
    #expect(model.includeDiagnostics == false)
    model.setIncludeDiagnostics(true)
    #expect(model.includeDiagnostics == false)
    #expect(model.decideSend(currentUsageMetrics: true) == .send(nil))
  }

  @Test("While loading, a ticked box waits; an unticked report sends at once")
  func loadingBlocksOnlyTicked() async {
    let (model, loader) = makeModel()
    model.open(usageMetrics: true)
    await loader.waitForArrival()

    #expect(model.isWaitingForDiagnostics == true)
    #expect(model.decideSend(currentUsageMetrics: true) == .waitingForDiagnostics)

    model.setIncludeDiagnostics(false)
    #expect(model.decideSend(currentUsageMetrics: true) == .send(nil))
    loader.answerOldest(with: Self.first)
    await model.loadTask?.value
  }

  @Test("A metrics flip while open resets the box to the new default and drops the old load")
  func metricsFlipResetsAndDropsStaleLoad() async {
    let (model, loader) = makeModel()
    model.open(usageMetrics: true)
    await loader.waitForArrival()

    model.usageMetricsChanged(to: false)
    #expect(model.includeDiagnostics == false)
    // The first load finishes late: its bytes must not land.
    loader.answerOldest(with: Self.first)
    await loader.answerNext(with: Self.second)
    await model.loadTask?.value

    model.setIncludeDiagnostics(true)
    #expect(model.previewSnapshot == Self.second)

    model.usageMetricsChanged(to: true)
    #expect(model.includeDiagnostics == true)
    #expect(model.diagnostics == .loading)
    await loader.answerNext(with: Self.first)
    await model.loadTask?.value
    #expect(model.previewSnapshot == Self.first)
  }

  @Test("Send rechecks the live switch: a change the form missed resets it and sends nothing")
  func sendTimeRecheck() async throws {
    let (model, loader) = makeModel()
    model.open(usageMetrics: true)
    await loader.answerNext(with: Self.first)
    await model.loadTask?.value

    // #require, not #expect: without the reset no second load ever starts, and the wait below
    // would hang the whole suite instead of failing this test.
    try #require(model.decideSend(currentUsageMetrics: false) == .metricsChanged)
    #expect(model.includeDiagnostics == false)
    #expect(model.diagnostics == .loading)
    await loader.answerNext(with: Self.second)
    await model.loadTask?.value
  }

  @Test("A load that finishes after the form closed changes nothing")
  func closeDropsLateLoad() async {
    let (model, loader) = makeModel()
    model.open(usageMetrics: true)
    await loader.waitForArrival()
    let pending = model.loadTask

    model.formDidClose()
    loader.answerOldest(with: Self.first)
    await pending?.value

    #expect(model.diagnostics == .loading)
    #expect(model.previewSnapshot == nil)
  }

  @Test("Reopening forgets the last choice and starts from the switch again")
  func reopenForgetsTheChoice() async {
    let (model, loader) = makeModel()
    model.open(usageMetrics: false)
    await loader.answerNext(with: Self.first)
    await model.loadTask?.value
    model.setIncludeDiagnostics(true)
    model.formDidClose()

    model.open(usageMetrics: false)
    #expect(model.includeDiagnostics == false)
    await loader.answerNext(with: Self.second)
    await model.loadTask?.value
    #expect(model.previewSnapshot == nil)
  }
}
