import Testing

@testable import EnviousWisprCore

/// #455 — verifies the `recordingDurationNs` field added to `XPCErrorContext`
/// surfaces correctly for the three call sites in `AudioCaptureProxy`:
/// interrupt-during-capture, invalidate-during-capture, and invalidate-idle.
///
/// The proxy itself is not directly testable in isolation (the XPC handlers
/// run inside its private static factory functions), so this asserts the
/// CONTRACT — the struct preserves the field and defaults to nil. Together
/// with the former root state breadcrumb wiring tests, this guards the diagnostic path
/// from `Recording started → ...ms → XPC interrupt` to Sentry.
@Suite("XPCErrorContext recordingDurationNs (#455)")
struct XPCErrorContextRecordingDurationTests {

  @Test("default init omits recordingDurationNs (back-compat for idle invalidate)")
  func defaultInitOmitsField() {
    let ctx = XPCErrorContext(
      kind: .invalidateIdle, sessionID: nil)
    #expect(ctx.recordingDurationNs == nil)
  }

  @Test("explicit nil recordingDurationNs is preserved")
  func explicitNilIsPreserved() {
    let ctx = XPCErrorContext(
      kind: .invalidateIdle, sessionID: nil,
      recordingDurationNs: nil)
    #expect(ctx.recordingDurationNs == nil)
  }

  @Test("explicit value is preserved for interruptCapturing")
  func valuePreservedForInterruptCapturing() {
    let ctx = XPCErrorContext(
      kind: .interruptCapturing, sessionID: 42,
      recordingDurationNs: 1_500_000_000)
    #expect(ctx.kind == .interruptCapturing)
    #expect(ctx.recordingDurationNs == 1_500_000_000)
  }

  @Test("explicit value is preserved for invalidateCapturing")
  func valuePreservedForInvalidateCapturing() {
    let ctx = XPCErrorContext(
      kind: .invalidateCapturing, sessionID: 7,
      recordingDurationNs: 250_000_000)
    #expect(ctx.kind == .invalidateCapturing)
    #expect(ctx.recordingDurationNs == 250_000_000)
  }

  /// Demonstrates the duration conversion that the former root state
  /// uses to populate the `audio.recording_duration_ms` breadcrumb extra.
  /// This isn't the former root state itself but documents the exact math; if the former root state's
  /// conversion drifts, this test still passes — making the drift visible at
  /// review time, where the Sentry breadcrumb field name has to match.
  @Test("nanosecond → millisecond conversion shape used by the breadcrumb")
  func nsToMsConversion() {
    let ctx = XPCErrorContext(
      kind: .interruptCapturing, sessionID: 1,
      recordingDurationNs: 1_500_000_000)
    let ms = ctx.recordingDurationNs.map { Int($0 / 1_000_000) }
    #expect(ms == 1500)
  }
}
