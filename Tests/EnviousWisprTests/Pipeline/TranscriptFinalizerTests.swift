import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

// Contract tests for `TranscriptFinalizer`. Locks the six heart-path invariants
// that let the orchestrator keep raw transcription flowing when optional limbs
// fail. See `docs/feature-requests/issue-326-2026-04-18-transcript-finalizer-contract-tests.md`.

@MainActor
@Suite("TranscriptFinalizer contracts")
struct TranscriptFinalizerTests {

  // MARK: - 1. Step failures do not prevent finalization

  @Test("Step failures preserve raw ASR text and call store exactly once")
  func stepFailurePreservesRawAsrText() async throws {
    let savedTranscripts = Box<[Transcript]>([])
    let pasteCount = Box(0)
    let step = FakeStep(name: "AlwaysFails") { _ in
      throw FakeStepError.simulated
    }
    let finalizer = TranscriptFinalizer(
      save: { savedTranscripts.value.append($0) },
      deliverPaste: { _ in
        pasteCount.value += 1
        return Self.deliveredResult()
      }
    )

    let rawText = "hello world"
    let result = try await finalizer.finalize(Self.request(asrText: rawText, steps: [step]))

    #expect(result.transcript.text == rawText)
    #expect(result.transcript.polishedText == nil)
    #expect(savedTranscripts.value.count == 1)
    #expect(savedTranscripts.value.first?.text == rawText)
    #expect(result.polishError == nil)
  }

  // MARK: - 2. Whitespace-only processed text throws .emptyAfterProcessing

  @Test("Whitespace-only processed text throws .emptyAfterProcessing without saving")
  func whitespaceOnlyThrowsEmptyAfterProcessing() async {
    let savedTranscripts = Box<[Transcript]>([])
    let step = FakeStep(name: "Whitespacer") { ctx in
      var next = ctx
      next.text = "   \n\t  "
      return next
    }
    let finalizer = TranscriptFinalizer(
      save: { savedTranscripts.value.append($0) },
      deliverPaste: { _ in Self.deliveredResult() }
    )

    do {
      _ = try await finalizer.finalize(Self.request(asrText: "hello", steps: [step]))
      Issue.record("expected finalize to throw")
    } catch FinalizationError.emptyAfterProcessing {
      // ok
    } catch {
      Issue.record("expected .emptyAfterProcessing, got \(error)")
    }
    #expect(savedTranscripts.value.isEmpty)
  }

  // MARK: - 3. Store throw wraps as .storageFailed(underlying:)

  @Test("Store throw wraps error as .storageFailed(underlying:) and preserves underlying type")
  func storeThrowWrapsAsStorageFailed() async {
    let finalizer = TranscriptFinalizer(
      save: { _ in throw FakeStoreError.diskFull },
      deliverPaste: { _ in Self.deliveredResult() }
    )

    do {
      _ = try await finalizer.finalize(Self.request(asrText: "hello", steps: []))
      Issue.record("expected finalize to throw")
    } catch let FinalizationError.storageFailed(underlying) {
      #expect(underlying is FakeStoreError)
      if let fake = underlying as? FakeStoreError {
        #expect(fake == .diskFull)
      }
    } catch {
      Issue.record("expected .storageFailed, got \(error)")
    }
  }

  // MARK: - 4. Cancellation during text processing (deterministic gate)

  @Test("Cancellation mid-processing throws CancellationError without saving")
  func cancellationMidProcessingThrowsWithoutSaving() async {
    let savedTranscripts = Box<[Transcript]>([])
    let pasteCount = Box(0)
    let started = AsyncStream.makeStream(of: Void.self)

    let step = FakeStep(
      name: "Suspends",
      maxDuration: .seconds(120)
    ) { ctx in
      started.continuation.yield(())
      started.continuation.finish()
      // Cancellation-aware sleep. Throws CancellationError when the outer
      // task is cancelled, which the runner's `catch is CancellationError`
      // branch rethrows up through `finalize`.
      try await Task.sleep(for: .seconds(60))
      return ctx
    }
    let finalizer = TranscriptFinalizer(
      save: { savedTranscripts.value.append($0) },
      deliverPaste: { _ in
        pasteCount.value += 1
        return Self.deliveredResult()
      }
    )

    let task = Task { @MainActor in
      try await finalizer.finalize(Self.request(asrText: "hello", steps: [step]))
    }

    var iterator = started.stream.makeAsyncIterator()
    _ = await iterator.next()
    task.cancel()

    let outcome = await task.result
    switch outcome {
    case .success:
      Issue.record("expected cancellation, got success")
    case .failure(let error):
      #expect(error is CancellationError, "expected CancellationError, got \(error)")
    }

    #expect(savedTranscripts.value.isEmpty)
    #expect(pasteCount.value == 0)
  }

  // MARK: - 5. Paste clipboard-only is non-fatal

  @Test("Paste clipboard-only outcome still returns a FinalizationResult")
  func pasteClipboardOnlyIsNonFatal() async throws {
    let rawText = "paste me"
    let finalizer = TranscriptFinalizer(
      save: { _ in },
      deliverPaste: { _ in Self.clipboardOnlyResult() }
    )

    let result = try await finalizer.finalize(Self.request(asrText: rawText, steps: []))

    #expect(result.transcript.text == rawText)
    #expect(result.pasteResult?.tier == .clipboardOnly)
    if case .clipboardOnly = result.pasteResult?.outcome {
      // ok
    } else {
      Issue.record(
        "expected clipboardOnly outcome, got \(String(describing: result.pasteResult?.outcome))")
    }
  }

  // MARK: - 6. Store failure short-circuits paste (ordering lock)

  @Test("Store failure short-circuits paste (m13v data-loss invariant, strengthened)")
  func storeFailureShortCircuitsPaste() async {
    let pasteCount = Box(0)
    let finalizer = TranscriptFinalizer(
      save: { _ in throw FakeStoreError.diskFull },
      deliverPaste: { _ in
        pasteCount.value += 1
        return Self.deliveredResult()
      }
    )

    do {
      _ = try await finalizer.finalize(Self.request(asrText: "hello", steps: []))
      Issue.record("expected finalize to throw")
    } catch FinalizationError.storageFailed {
      // ok
    } catch {
      Issue.record("expected .storageFailed, got \(error)")
    }

    #expect(
      pasteCount.value == 0,
      "paste must not run when store fails (locks store-before-paste ordering)")
  }

  // MARK: - Phase 0 (#640) — paste-completion event gating

  private final class CapturingObserver: PasteCompletionObserver {
    var events: [PasteCompletionEvent] = []
    func pasteCompleted(_ event: PasteCompletionEvent) {
      events.append(event)
    }
  }

  @Test("PasteCompletionEvent emitted ONCE on .delivered outcome")
  func pasteCompleteEmitsOnDelivered() async throws {
    let registry = PasteCompletionRegistry()
    let observer = CapturingObserver()
    registry.subscribe(observer)
    let finalizer = TranscriptFinalizer(
      save: { _ in },
      deliverPaste: { _ in Self.deliveredResult() },
      pasteCompletionRegistry: registry
    )
    _ = try await finalizer.finalize(Self.request(asrText: "hello", steps: []))
    #expect(observer.events.count == 1, "Delivered paste must emit exactly one event")
    #expect(observer.events.first?.pastedText.contains("hello") == true)
  }

  @Test("PasteCompletionEvent NOT emitted on .clipboardOnly fallback (Codex P2)")
  func pasteCompleteSilentOnClipboardOnly() async throws {
    let registry = PasteCompletionRegistry()
    let observer = CapturingObserver()
    registry.subscribe(observer)
    let finalizer = TranscriptFinalizer(
      save: { _ in },
      deliverPaste: { _ in Self.clipboardOnlyResult() },
      pasteCompletionRegistry: registry
    )
    _ = try await finalizer.finalize(Self.request(asrText: "hello", steps: []))
    #expect(
      observer.events.isEmpty,
      "Clipboard-only fallback must not emit — Phase 7 auto-learn would falsely watch a destination where nothing was pasted"
    )
  }

  @Test("PasteCompletionEvent NOT emitted on copy-only branch")
  func pasteCompleteSilentOnCopyOnly() async throws {
    let registry = PasteCompletionRegistry()
    let observer = CapturingObserver()
    registry.subscribe(observer)
    let finalizer = TranscriptFinalizer(
      save: { _ in },
      deliverPaste: { _ in
        Issue.record("deliverPaste must not be called on copy-only path")
        return Self.deliveredResult()
      },
      pasteCompletionRegistry: registry
    )
    _ = try await finalizer.finalize(
      Self.request(asrText: "hello", steps: [], autoPaste: false))
    #expect(observer.events.isEmpty, "Copy-only path must not emit")
  }

  // MARK: - Helpers

  private static func request(
    asrText: String,
    steps: [any TextProcessingStep],
    autoPaste: Bool = true
  ) -> FinalizationRequest {
    FinalizationRequest(
      asrText: asrText,
      language: "en",
      duration: 1.0,
      processingTime: 0.1,
      backendType: .parakeet,
      targetApp: nil,
      targetElement: nil,
      autoCopyToClipboard: false,
      autoPasteToActiveApp: autoPaste,
      restoreClipboardAfterPaste: false,
      steps: steps
    )
  }

  private static func deliveredResult() -> PasteDeliveryResult {
    PasteDeliveryResult(
      tier: .cgEvent,
      durationMs: 12,
      outcome: .delivered(tier: .cgEvent, durationMs: 12)
    )
  }

  private static func clipboardOnlyResult() -> PasteDeliveryResult {
    PasteDeliveryResult(
      tier: .clipboardOnly,
      durationMs: 3,
      outcome: .clipboardOnly(
        tiersAttempted: [],
        focus: .missing,
        targetBundleID: nil
      )
    )
  }
}

// MARK: - Test doubles

/// Mutable box so `@MainActor` closures can accumulate state that the test
/// reads afterwards. `Transcript` / scalar captures escape via this holder.
@MainActor
private final class Box<T> {
  var value: T
  init(_ value: T) { self.value = value }
}

@MainActor
private final class FakeStep: TextProcessingStep {
  let name: String
  let isEnabled: Bool
  let maxDuration: Duration
  private let transform: @MainActor (TextProcessingContext) async throws -> TextProcessingContext

  init(
    name: String,
    isEnabled: Bool = true,
    maxDuration: Duration = .seconds(5),
    transform: @escaping @MainActor (TextProcessingContext) async throws -> TextProcessingContext
  ) {
    self.name = name
    self.isEnabled = isEnabled
    self.maxDuration = maxDuration
    self.transform = transform
  }

  func process(_ context: TextProcessingContext) async throws -> TextProcessingContext {
    try await transform(context)
  }
}

private enum FakeStepError: Error { case simulated }
private enum FakeStoreError: Error, Equatable { case diskFull }
