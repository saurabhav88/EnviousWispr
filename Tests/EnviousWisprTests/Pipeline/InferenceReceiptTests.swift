import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// Waits for the inference notification a test expects (a subject signal).
/// The deadline only fails a notification that never arrives. Neither this
/// wait nor an immediate count assertion proves absence of a later duplicate.
@MainActor
func waitForInferenceNotification(
  _ received: () -> Bool,
  sourceLocation: SourceLocation = #_sourceLocation
) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))  // deadline-fallback: bounds the signal wait
  while received() == false {
    try Task.checkCancellation()
    guard ContinuousClock.now < deadline else {
      Issue.record("inference notification did not arrive", sourceLocation: sourceLocation)
      throw InferenceNotificationWaitError.timedOut
    }
    await Task.yield()
  }
}

private enum InferenceNotificationWaitError: Error {
  case timedOut
}

/// #3546 §3.7 T1 (amendment §2.2): a take's inference entry is committed once, by the first
/// vendor call, into that take's own receipt. When this fails, a take is credited with a
/// later call's model, notifies the kernel once per window, or a late call from an old take
/// marks a newer one.
@Suite("Inference receipt (#3546)", .tags(.observabilityContract))
struct InferenceReceiptTests {

  static let ultra = ASRModelIdentity(
    name: "parakeet-ultra-coreml", revision: "95eaa59a", variant: "int8")
  static let v3 = ASRModelIdentity(
    name: "parakeet-tdt-0.6b-v3-coreml", revision: "aed02740", variant: "int8")

  @Test("the first record wins and later records change nothing")
  func firstRecordWins() {
    let receipt = InferenceReceipt<ASRInferenceEntry>()
    let sid = SessionID()
    #expect(receipt.read() == nil)
    #expect(receipt.record(ASRInferenceEntry(session: sid, identity: Self.ultra)))
    #expect(receipt.record(ASRInferenceEntry(session: sid, identity: Self.v3)) == false)
    #expect(receipt.read() == ASRInferenceEntry(session: sid, identity: Self.ultra))
  }

  /// Concurrent vendor calls (stream windows on the vendor actor, a rescue on a backend
  /// actor) race the commit: exactly one wins.
  @Test("concurrent records have exactly one winner")
  func concurrentRecordsHaveOneWinner() async {
    let receipt = InferenceReceipt<Int>()
    let winners = await withTaskGroup(of: Bool.self) { group in
      for value in 0..<64 {
        group.addTask { receipt.record(value) }
      }
      var count = 0
      for await won in group where won { count += 1 }
      return count
    }
    #expect(winners == 1)
    #expect(receipt.read() != nil)
  }

  @MainActor
  @Test("a session's observer records into that session only and notifies once")
  func observerIsBoundToItsSession() async throws {
    let book = InferenceReceiptBook()
    let first = SessionID()
    let second = SessionID()
    book.open(first)
    var notified: [SessionID] = []
    let observer = try #require(
      book.observer(session: first, identity: Self.ultra) { notified.append($0) })
    book.open(second)
    observer()
    observer()
    try await waitForInferenceNotification { notified.isEmpty == false }
    #expect(book.entry(for: first)?.identity == Self.ultra)
    #expect(book.entry(for: second) == nil)
    #expect(notified == [first])
  }

  @MainActor
  @Test("no observer exists for an unknown or evicted session")
  func noObserverWithoutAnOpenReceipt() {
    let book = InferenceReceiptBook()
    #expect(book.observer(session: nil, identity: nil) { _ in } == nil)
    #expect(book.observer(session: SessionID(), identity: nil) { _ in } == nil)
    let oldest = SessionID()
    book.open(oldest)
    for _ in 0..<4 { book.open(SessionID()) }
    #expect(book.observer(session: oldest, identity: nil) { _ in } == nil)
    #expect(book.entry(for: oldest) == nil)
  }
}
