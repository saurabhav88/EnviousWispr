import EnviousWisprServices
import Foundation
import Testing
import os

// MARK: - #1946 chunk 2 — the retry-deadline event's payload
//
// `KernelPhase2RetryTests` proves what the KERNEL computes across the five
// retry schedules. This suite proves what actually reaches the analytics
// pipeline, through the existing telemetry test hook rather than a live
// capture, because a correct computation published under the wrong field names
// answers nobody's question.

@MainActor
@Suite("#1946 retry-deadline telemetry payload", .tags(.observabilityContract))
struct TelemetryServiceRetryDeadlineTests {

  /// Captures one emission and always restores the hook, so a failing case
  /// cannot leave a recorder installed for the rest of the run.
  private func captureEvents(
    _ body: @MainActor () -> Void
  ) -> [CapturedTelemetryEvent] {
    // Under a lock, not a captured `var`: the hook is `@Sendable`, so the
    // compiler refuses a plain capture and a box that ignored that would be
    // hiding a real cross-thread write rather than answering it.
    let captured = OSAllocatedUnfairLock<[CapturedTelemetryEvent]>(initialState: [])
    let prior = TelemetryService.shared.testEventHook
    TelemetryService.shared.testEventHook = { event in
      captured.withLock { $0.append(event) }
    }
    defer { TelemetryService.shared.testEventHook = prior }
    body()
    return captured.withLock { $0 }
  }

  @Test("the started half carries the join key, the backend and the budget")
  func startedPayload() {
    let events = captureEvents {
      TelemetryService.shared.asrRetryDeadlineStarted(
        takeID: "take-1", asrBackend: "parakeet", budgetMs: 1200)
    }
    #expect(events.count == 1)
    guard let event = events.first else { return }
    #expect(event.name == "asr.retry_deadline_observed")
    #expect(event.stringProps["phase"] == "started")
    #expect(
      event.stringProps["take_id"] == "take-1",
      "the join key, without which an accepted retry cannot be tied to its delivery")
    #expect(event.stringProps["asr_backend"] == "parakeet")
    #expect(event.intProps["budget_ms"] == 1200)
  }

  @Test("a timed-out resolution reports no decode time rather than a zero")
  func resolvedPayloadTimeout() {
    let events = captureEvents {
      TelemetryService.shared.asrRetryDeadlineResolved(
        takeID: "take-2", asrBackend: "whisperkit", budgetMs: 900,
        resolution: .timedOut, disposition: .rejected,
        operationReturnMs: nil, callerResumeMs: 950, acceptedAfterCutoff: false)
    }
    #expect(events.count == 1)
    guard let event = events.first else { return }
    #expect(event.stringProps["phase"] == "resolved")
    #expect(event.stringProps["resolution"] == "timeout")
    #expect(event.stringProps["disposition"] == "rejected")
    #expect(
      event.intProps["operation_return_ms"] == nil,
      """
      an absent decode time must stay ABSENT. A zero or a negative stand-in \
      reads as a fast return once it reaches a chart, which is the opposite of \
      what happened
      """)
    #expect(event.intProps["caller_resume_ms"] == 950)
    #expect(event.boolProps["accepted_after_cutoff"] == false)
  }

  @Test("a decode accepted past its budget is flagged, and an on-time one is not")
  func resolvedPayloadAcceptedAfterCutoff() {
    let late = captureEvents {
      TelemetryService.shared.asrRetryDeadlineResolved(
        takeID: "take-3", asrBackend: "parakeet", budgetMs: 100,
        resolution: .operationReturned, disposition: .accepted,
        operationReturnMs: 260, callerResumeMs: 265, acceptedAfterCutoff: true)
    }
    #expect(late.first?.boolProps["accepted_after_cutoff"] == true)
    #expect(late.first?.intProps["operation_return_ms"] == 260)
    #expect(late.first?.stringProps["resolution"] == "operation")
    #expect(late.first?.stringProps["disposition"] == "accepted")

    // The two-way control. Without it a field hardcoded to `true` would pass
    // the case above and the measurement would count every accepted retry.
    let onTime = captureEvents {
      TelemetryService.shared.asrRetryDeadlineResolved(
        takeID: "take-4", asrBackend: "parakeet", budgetMs: 1000,
        resolution: .operationReturned, disposition: .accepted,
        operationReturnMs: 120, callerResumeMs: 125, acceptedAfterCutoff: false)
    }
    #expect(onTime.first?.boolProps["accepted_after_cutoff"] == false)
  }

  @Test("stale and abandoned resolutions keep their own labels")
  func resolvedPayloadNonAcceptanceLabels() {
    let stale = captureEvents {
      TelemetryService.shared.asrRetryDeadlineResolved(
        takeID: "take-5", asrBackend: "parakeet", budgetMs: 1000,
        resolution: .operationReturned, disposition: .stale,
        operationReturnMs: 4000, callerResumeMs: 4010, acceptedAfterCutoff: false)
    }
    #expect(stale.first?.stringProps["disposition"] == "stale")
    #expect(
      stale.first?.boolProps["accepted_after_cutoff"] == false,
      "a late decode nobody used creates no exposure to a stricter cutoff")

    let abandoned = captureEvents {
      TelemetryService.shared.asrRetryDeadlineResolved(
        takeID: "take-6", asrBackend: "parakeet", budgetMs: 1000,
        resolution: .operationReturned, disposition: .abandoned,
        operationReturnMs: 4000, callerResumeMs: 4010, acceptedAfterCutoff: false)
    }
    #expect(abandoned.first?.stringProps["disposition"] == "abandoned")
  }
}
