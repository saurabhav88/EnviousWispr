import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline

@MainActor
@Suite("SignalPipelineLogger")
struct SignalPipelineLoggerTests {

  @Test("resolves immediately when a matching entry was already logged")
  func resolvesImmediatelyForExistingEntry() async throws {
    let logger = SignalPipelineLogger()
    await logger.log("step done", level: .info, category: "PipelineTiming")

    let entry = try await logger.waitForEntry { $0.category == "PipelineTiming" }

    #expect(entry.message == "step done")
  }

  @Test("resolves the continuation when a matching entry arrives later")
  func resolvesWhenEntryArrivesLater() async throws {
    let logger = SignalPipelineLogger()

    // The spawned Task body cannot run until `waitForEntry` below suspends,
    // so the waiter is guaranteed registered before the log fires.
    Task { await logger.log("late arrival", level: .info, category: "TextProcessing") }

    let entry = try await logger.waitForEntry(
      matching: { $0.message == "late arrival" },
      timeout: .seconds(2)
    )

    #expect(entry.category == "TextProcessing")
  }

  @Test("throws TimeoutError when no matching entry ever arrives")
  func throwsTimeoutWhenNoMatch() async {
    let logger = SignalPipelineLogger()
    await logger.log("unrelated", level: .info, category: "Other")

    await #expect(throws: TimeoutError.self) {
      _ = try await logger.waitForEntry(
        matching: { $0.category == "NeverLogged" },
        timeout: .milliseconds(100)
      )
    }
  }

  @Test("resumes each waiter exactly once even when multiple entries match")
  func resumesWaiterExactlyOnce() async throws {
    let logger = SignalPipelineLogger()

    // Two entries match the same predicate. If the waiter were resumed twice
    // the second `continuation.resume` would crash the process — this test
    // passing is the proof that removal-before-resume holds.
    let logTask = Task {
      await logger.log("match one", level: .info, category: "CorrectionDebug")
      await logger.log("match two", level: .info, category: "CorrectionDebug")
    }

    let entry = try await logger.waitForEntry(
      matching: { $0.category == "CorrectionDebug" },
      timeout: .seconds(2)
    )
    await logTask.value

    #expect(entry.message == "match one")
    #expect(logger.entries.count == 2)
  }
}
