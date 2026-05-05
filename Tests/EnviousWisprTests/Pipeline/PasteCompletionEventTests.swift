import EnviousWisprServices
import Foundation
import Testing

/// Phase 0 (#640) — pins the paste-complete event seam.
/// Subscriber registration, weak storage, emission, dead-ref pruning.
@MainActor
@Suite("PasteCompletionRegistry — Phase 0 event seam")
struct PasteCompletionEventTests {

  private final class CapturingObserver: PasteCompletionObserver {
    var receivedEvents: [PasteCompletionEvent] = []
    func pasteCompleted(_ event: PasteCompletionEvent) {
      receivedEvents.append(event)
    }
  }

  private final class DeinitFlag: @unchecked Sendable {
    var fired: Bool = false
  }

  private final class DeinitProbeObserver: PasteCompletionObserver {
    let flag: DeinitFlag
    init(flag: DeinitFlag) { self.flag = flag }
    nonisolated deinit { flag.fired = true }
    func pasteCompleted(_ event: PasteCompletionEvent) {}
  }

  @Test("Subscriber receives emitted events")
  func subscriberReceivesEvents() {
    let registry = PasteCompletionRegistry()
    let observer = CapturingObserver()
    registry.subscribe(observer)

    let event = PasteCompletionEvent(
      pastedText: "hello world",
      destinationBundleID: "com.apple.Notes"
    )
    registry.emit(event)

    #expect(observer.receivedEvents.count == 1)
    #expect(observer.receivedEvents.first?.pastedText == "hello world")
    #expect(observer.receivedEvents.first?.destinationBundleID == "com.apple.Notes")
  }

  @Test("Multiple subscribers all receive event")
  func multipleSubscribers() {
    let registry = PasteCompletionRegistry()
    let a = CapturingObserver()
    let b = CapturingObserver()
    let c = CapturingObserver()
    registry.subscribe(a)
    registry.subscribe(b)
    registry.subscribe(c)

    registry.emit(PasteCompletionEvent(pastedText: "ping", destinationBundleID: nil))

    #expect(a.receivedEvents.count == 1)
    #expect(b.receivedEvents.count == 1)
    #expect(c.receivedEvents.count == 1)
  }

  @Test("Duplicate subscribe is idempotent")
  func duplicateSubscribeIdempotent() {
    let registry = PasteCompletionRegistry()
    let observer = CapturingObserver()
    registry.subscribe(observer)
    registry.subscribe(observer)
    registry.subscribe(observer)

    registry.emit(PasteCompletionEvent(pastedText: "x", destinationBundleID: nil))
    #expect(observer.receivedEvents.count == 1, "Same observer must fire once per emit")
  }

  @Test("Observer stored weakly — deallocated observer pruned")
  func weakStorageProvenByDeinit() {
    let registry = PasteCompletionRegistry()
    let flag = DeinitFlag()
    autoreleasepool {
      let probe = DeinitProbeObserver(flag: flag)
      registry.subscribe(probe)
      #expect(registry.observerCount == 1)
    }
    #expect(flag.fired, "Probe must be deallocated — proves weak storage")
    #expect(registry.observerCount == 0, "Dead refs pruned on next access")
  }

  @Test("nil destinationBundleID supported")
  func nilDestinationBundleID() {
    let registry = PasteCompletionRegistry()
    let observer = CapturingObserver()
    registry.subscribe(observer)

    registry.emit(PasteCompletionEvent(pastedText: "no app", destinationBundleID: nil))
    #expect(observer.receivedEvents.first?.destinationBundleID == nil)
  }

  @Test("Timestamp populated on event")
  func timestampPopulated() {
    let before = Date()
    let event = PasteCompletionEvent(pastedText: "t", destinationBundleID: nil)
    let after = Date()

    #expect(event.timestamp >= before)
    #expect(event.timestamp <= after)
  }
}
