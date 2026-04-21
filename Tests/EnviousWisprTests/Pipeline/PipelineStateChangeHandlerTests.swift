import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprPipeline

/// Unit tests for `PipelineStateChangeHandler` — the stateful wrapper that
/// drives plan execution through injected dependencies.
///
/// These tests complement `PipelineStateChangePlannerTests` (which pin the
/// pure decision logic). These verify that each `PipelineStateSideEffect`
/// maps to the correct injected callback and that transcript-conditional
/// effects honour their guards.
@MainActor
@Suite("PipelineStateChangeHandler — execution contract")
struct PipelineStateChangeHandlerTests {

  // MARK: - Test doubles

  /// Spy that captures every `showOverlay` callback invocation. Replaces
  /// the protocol-existential overlay of earlier designs — static dispatch,
  /// no @MainActor class boundary to cross.
  final class OverlaySpy {
    struct Call: Equatable {
      let intent: OverlayIntent
    }
    var calls: [Call] = []

    func record(_ intent: OverlayIntent) {
      calls.append(Call(intent: intent))
    }
  }

  /// Callback bundle — counts invocations and captures payloads so tests can
  /// assert against effect routing.
  final class CallbackRecorder {
    var cancelWarningCount = 0
    var scheduleWarningCount = 0
    var appendedCalls: [Transcript] = []
    var completedCalls: [Transcript] = []
    var failedCalls: [String] = []
  }

  private static func makeHandler(
    overlay: OverlaySpy,
    callbacks: CallbackRecorder
  ) -> PipelineStateChangeHandler {
    PipelineStateChangeHandler(
      showOverlay: { intent in overlay.record(intent) },
      cancelPendingWarning: { callbacks.cancelWarningCount += 1 },
      schedulePolishFailedWarning: { callbacks.scheduleWarningCount += 1 },
      appendCompletedTranscript: { callbacks.appendedCalls.append($0) },
      reportDictationCompleted: { callbacks.completedCalls.append($0) },
      reportPipelineFailed: { callbacks.failedCalls.append($0) }
    )
  }

  private static func makeTranscript(pasteTier: String? = nil) -> Transcript {
    Transcript(
      text: "hello world",
      processingTime: 0.05,
      backendType: .parakeet,
      metrics: pasteTier.map {
        ExecutionMetrics(
          asrLatencySeconds: 0.1, llmLatencySeconds: 0.2,
          pasteTier: $0, pasteLatencyMs: 12, targetApp: "test.app",
          e2eSeconds: 0.8)
      }
    )
  }

  // MARK: - Happy paths

  @Test("complete + success transcript: show overlay, reload, report completed")
  func completeSuccessRoutesEffects() {
    let spy = OverlaySpy()
    let calls = CallbackRecorder()
    let handler = Self.makeHandler(overlay: spy, callbacks: calls)
    let transcript = Self.makeTranscript(pasteTier: "direct")

    handler.handle(
      to: PipelineState.complete,
      pipelineOverlayIntent: .hidden,
      lastPolishError: nil,
      currentTranscript: transcript
    )

    #expect(spy.calls == [OverlaySpy.Call(intent: .hidden)])
    #expect(calls.appendedCalls.count == 1)
    #expect(calls.completedCalls.count == 1)
    #expect(calls.completedCalls.first?.id == transcript.id)
    #expect(calls.failedCalls.isEmpty)
    #expect(calls.cancelWarningCount == 0)
    #expect(calls.scheduleWarningCount == 0)
  }

  @Test("complete + polish failed: schedule warning before showing overlay, then reload + report")
  func completePolishFailedRoutesWarningSchedule() {
    let spy = OverlaySpy()
    let calls = CallbackRecorder()
    let handler = Self.makeHandler(overlay: spy, callbacks: calls)
    let transcript = Self.makeTranscript(pasteTier: "direct")

    handler.handle(
      to: PipelineState.complete,
      pipelineOverlayIntent: .hidden,
      lastPolishError: "openai_timeout",
      currentTranscript: transcript
    )

    #expect(calls.scheduleWarningCount == 1)
    #expect(calls.cancelWarningCount == 0)
    #expect(spy.calls == [OverlaySpy.Call(intent: .hidden)])
    #expect(calls.appendedCalls.count == 1)
    #expect(calls.completedCalls.count == 1)
  }

  @Test("complete + clipboard fallback wins over polish warning")
  func completeClipboardFallbackRoutesEffects() {
    let spy = OverlaySpy()
    let calls = CallbackRecorder()
    let handler = Self.makeHandler(overlay: spy, callbacks: calls)
    let transcript = Self.makeTranscript(pasteTier: "clipboard_only")

    handler.handle(
      to: PipelineState.complete,
      pipelineOverlayIntent: .hidden,
      lastPolishError: "still set but fallback wins",
      currentTranscript: transcript
    )

    #expect(spy.calls == [OverlaySpy.Call(intent: .clipboardFallback)])
    #expect(calls.scheduleWarningCount == 0)
    #expect(calls.appendedCalls.count == 1)
    #expect(calls.completedCalls.count == 1)
  }

  // MARK: - Transcript-conditional guards

  @Test("complete without current transcript: neither append nor telemetry fires (Phase C)")
  func completeWithoutTranscriptSkipsBothAppendAndTelemetry() {
    // Phase C (#428): `.complete` with nil transcript emits overlay only.
    // The in-memory cache is stale until next `load()`; finalizer has
    // already persisted the row, so disk is authoritative.
    let spy = OverlaySpy()
    let calls = CallbackRecorder()
    let handler = Self.makeHandler(overlay: spy, callbacks: calls)

    handler.handle(
      to: PipelineState.complete,
      pipelineOverlayIntent: .hidden,
      lastPolishError: nil,
      currentTranscript: nil
    )

    #expect(calls.appendedCalls.isEmpty)
    #expect(calls.completedCalls.isEmpty)
    #expect(spy.calls.count == 1)
  }

  // MARK: - Non-complete transitions cancel warning

  @Test("recording transition cancels pending warning and shows overlay")
  func recordingCancelsWarning() {
    let spy = OverlaySpy()
    let calls = CallbackRecorder()
    let handler = Self.makeHandler(overlay: spy, callbacks: calls)

    handler.handle(
      to: PipelineState.recording,
      pipelineOverlayIntent: .recording(audioLevel: 0),
      lastPolishError: nil,
      currentTranscript: nil
    )

    #expect(calls.cancelWarningCount == 1)
    #expect(calls.scheduleWarningCount == 0)
    #expect(spy.calls == [OverlaySpy.Call(intent: .recording(audioLevel: 0))])
    #expect(calls.appendedCalls.count == 0)
    #expect(calls.completedCalls.isEmpty)
    #expect(calls.failedCalls.isEmpty)
  }

  @Test("WhisperKit .ready cancels warning and does not emit completion telemetry")
  func whisperKitReadyCancelsWarning() {
    let spy = OverlaySpy()
    let calls = CallbackRecorder()
    let handler = Self.makeHandler(overlay: spy, callbacks: calls)

    handler.handle(
      to: WhisperKitPipelineState.ready,
      pipelineOverlayIntent: .hidden,
      lastPolishError: nil,
      currentTranscript: nil
    )

    #expect(calls.cancelWarningCount == 1)
    #expect(calls.appendedCalls.count == 0)
    #expect(calls.completedCalls.isEmpty)
  }

  // MARK: - Error path

  @Test("error state cancels warning, shows overlay, reports pipelineFailed with code")
  func errorStateRoutesReportFailed() {
    let spy = OverlaySpy()
    let calls = CallbackRecorder()
    let handler = Self.makeHandler(overlay: spy, callbacks: calls)

    handler.handle(
      to: PipelineState.error("mic_disconnected"),
      pipelineOverlayIntent: .error(message: "mic_disconnected"),
      lastPolishError: nil,
      currentTranscript: nil
    )

    #expect(calls.cancelWarningCount == 1)
    #expect(
      spy.calls == [OverlaySpy.Call(intent: .error(message: "mic_disconnected"))])
    #expect(calls.failedCalls == ["mic_disconnected"])
    #expect(calls.appendedCalls.count == 0)
    #expect(calls.completedCalls.isEmpty)
  }

  // MARK: - Cumulative lifecycle

  @Test("two successive complete calls route two telemetry reports and two history reloads")
  func handlerIsStateless() {
    let spy = OverlaySpy()
    let calls = CallbackRecorder()
    let handler = Self.makeHandler(overlay: spy, callbacks: calls)
    let first = Self.makeTranscript(pasteTier: "direct")
    let second = Self.makeTranscript(pasteTier: "direct")

    handler.handle(
      to: PipelineState.complete,
      pipelineOverlayIntent: .hidden,
      lastPolishError: nil,
      currentTranscript: first
    )
    handler.handle(
      to: PipelineState.complete,
      pipelineOverlayIntent: .hidden,
      lastPolishError: nil,
      currentTranscript: second
    )

    #expect(calls.appendedCalls.count == 2)
    #expect(calls.completedCalls.count == 2)
    #expect(calls.completedCalls.map(\.id) == [first.id, second.id])
  }
}
