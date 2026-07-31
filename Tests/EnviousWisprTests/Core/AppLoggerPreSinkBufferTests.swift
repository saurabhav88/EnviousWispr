import EnviousWisprCore
import Foundation
import Testing

/// #1361 — lines logged BEFORE the file sink opens used to vanish.
///
/// The cause is the `isDebugModeEnabled` guard in `AppLogger.log(...)`, not a
/// FileHandle race: that flag stays false until `setDebugMode(true)` runs at
/// launch, so everything emitted earlier reached OSLog and nothing else. A
/// launch-window `finishFailed` never made it to `app.log` while the identical
/// call at press-time did.
///
/// `AppLogger` is a process-wide singleton writing to the developer's real log
/// directory, so every test here restores the prior debug mode and log level,
/// and resets the latch through the `#if DEBUG` seam so the pre-sink window is
/// reachable regardless of suite ordering.
#if DEBUG
  /// `.serialized` is load-bearing, not tidiness. Swift Testing runs tests in
  /// parallel by default and every case here mutates the ONE process-wide
  /// `AppLogger.shared`. Run concurrently, a sibling enabling the sink midway
  /// through `bufferIsBoundedAndHonest` would flush and empty the buffer under
  /// it, and the count assertions would fail for a reason that has nothing to do
  /// with the code under test. Serializing the suite is the only way these
  /// assertions mean what they say.
  @Suite("AppLogger pre-sink buffer (#1361)", .serialized)
  struct AppLoggerPreSinkBufferTests {

    /// Runs `body` with AppLogger returned to its prior state afterwards.
    ///
    /// Restoration is AWAITED, not fired into a detached `Task`. A `defer` that
    /// only launches restoration returns before any of it lands, so the next
    /// test could start against half-restored state and the developer's own
    /// persisted debug mode could be left wrong after the run.
    private func withRestoredLogger(
      _ body: () async throws -> Void
    ) async throws {
      let priorMode = await AppLogger.shared.isDebugModeEnabled
      let priorLevel = await AppLogger.shared.logLevel

      await AppLogger.shared.setDebugMode(false)
      await AppLogger.shared.resetPreSinkBufferForTesting()

      // `defer` cannot await, so the restore is done on both exits explicitly.
      do {
        try await body()
      } catch {
        await restore(mode: priorMode, level: priorLevel)
        throw error
      }
      await restore(mode: priorMode, level: priorLevel)
    }

    /// Reset FIRST, then re-apply the mode. The reverse order leaves the
    /// pre-sink window OPEN: `resetPreSinkBufferForTesting` clears
    /// `hasAppliedInitialDebugMode`, so running it after `setDebugMode` undoes
    /// the latch that call just closed, and every later log line in the process
    /// would start buffering again for output that can never be flushed.
    private func restore(mode: Bool, level: DebugLogLevel) async {
      await AppLogger.shared.resetPreSinkBufferForTesting()
      await AppLogger.shared.setLogLevel(level)
      await AppLogger.shared.setDebugMode(mode)
    }

    /// Reads the live `app.log`. Missing or unreadable reads back as empty, so a
    /// `contains` assertion fails loudly rather than throwing something unrelated.
    private func readLog() -> String {
      let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/EnviousWispr", isDirectory: true)
        .appendingPathComponent("app.log")
      return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @Test("a line logged before the sink opens survives and reaches the file")
    func preSinkLineSurvives() async throws {
      try await withRestoredLogger {
        let marker = "EW1361-presink-\(UUID().uuidString)"

        // Sink is OFF: this is the launch window that used to lose lines.
        await AppLogger.shared.log(marker, level: .info, category: "AppLogger1361")

        // Control: it is buffered, not written — nothing can have reached the
        // file yet, so a later hit proves the FLUSH delivered it.
        let buffered = await AppLogger.shared.pendingPreSinkLineCount
        #expect(buffered >= 1, "the pre-sink line must be held, not dropped")

        await AppLogger.shared.setDebugMode(true)

        let contents = readLog()
        #expect(
          contents.contains(marker),
          "the pre-sink line must reach app.log once the sink opens")
        #expect(
          contents.contains("buffered before the log file opened"),
          "the flush must announce itself so the ordering is explainable")

        // The flushed entry must appear ABOVE the notice that describes it, and
        // above "Debug mode enabled". Writing the notice first stamped it with
        // `now` and put older entries beneath it, so the file ran backward in
        // time while a comment claimed it ascended.
        //
        // Scope the search to the text AFTER this run's unique marker. app.log
        // is appended across every run, so a whole-file `range(of:)` finds a
        // "Debug mode enabled" from some previous session and compares offsets
        // from different runs — which is how the first version of this
        // assertion failed against correct code.
        guard let markerIdx = contents.range(of: marker) else {
          Issue.record("the buffered line never reached app.log")
          return
        }
        let afterMarker = contents[markerIdx.upperBound...]
        guard let noticeIdx = afterMarker.range(of: "were buffered before the log file opened")
        else {
          Issue.record("the flush notice must follow the entries it describes")
          return
        }
        guard let enabledIdx = afterMarker.range(of: "Debug mode enabled") else {
          Issue.record("the debug-mode-enabled marker must follow the flush")
          return
        }
        #expect(
          noticeIdx.lowerBound < enabledIdx.lowerBound,
          "the flush notice must precede the debug-mode-enabled marker")
      }
    }

    @Test("a line rejected by the level filter is NOT buffered")
    func levelFilteredLineIsNotBuffered() async throws {
      try await withRestoredLogger {
        // Sink ON at the default .info threshold: a .debug line is a deliberate
        // filter, not a lost line. Buffering it would resurrect output the user
        // asked not to have.
        await AppLogger.shared.setDebugMode(true)
        await AppLogger.shared.setLogLevel(.info)
        let before = await AppLogger.shared.pendingPreSinkLineCount

        await AppLogger.shared.log(
          "EW1361-filtered-\(UUID().uuidString)", level: .debug, category: "AppLogger1361")

        let after = await AppLogger.shared.pendingPreSinkLineCount
        #expect(after == before, "a level-filtered line must never enter the pre-sink buffer")
      }
    }

    @Test("after an explicit disable, lines are dropped rather than re-buffered")
    func disableDoesNotReopenTheBuffer() async throws {
      try await withRestoredLogger {
        // Enable then disable: the user has asked logging to STOP. A later
        // re-enable must not resurrect what was written in between.
        await AppLogger.shared.setDebugMode(true)
        await AppLogger.shared.setDebugMode(false)
        let before = await AppLogger.shared.pendingPreSinkLineCount

        await AppLogger.shared.log(
          "EW1361-afterdisable-\(UUID().uuidString)", level: .info, category: "AppLogger1361")

        let after = await AppLogger.shared.pendingPreSinkLineCount
        #expect(
          after == before,
          "the buffer covers only the window before the initial setting is applied")
      }
    }

    /// The steady-state cost guard. Applying a persisted `false` at launch is
    /// the overwhelmingly common case in a DEBUG build, and it must CLOSE the
    /// window — otherwise every one of the ~148 log call sites formats a
    /// timestamp and allocates forever, for output that can never be flushed,
    /// and past the cap pays an O(n) `removeFirst` per call on top.
    @Test("applying a persisted OFF setting closes the window and frees the buffer")
    func applyingDisabledClosesTheWindow() async throws {
      try await withRestoredLogger {
        // Pre-sink window is open: this line buffers.
        await AppLogger.shared.log(
          "EW1361-beforeapply-\(UUID().uuidString)", level: .info, category: "AppLogger1361")
        let buffered = await AppLogger.shared.pendingPreSinkLineCount
        #expect(buffered >= 1, "the window must be open before the setting is applied")

        // Launch applies the persisted setting — and it is OFF.
        await AppLogger.shared.setDebugMode(false)

        let afterApply = await AppLogger.shared.pendingPreSinkLineCount
        #expect(afterApply == 0, "an applied OFF must release the buffer, not hold it")

        await AppLogger.shared.log(
          "EW1361-steadystate-\(UUID().uuidString)", level: .info, category: "AppLogger1361")
        let steady = await AppLogger.shared.pendingPreSinkLineCount
        #expect(steady == 0, "no buffering may continue once the setting has been applied")
      }
    }

    @Test("the buffer is bounded and reports what it dropped")
    func bufferIsBoundedAndHonest() async throws {
      try await withRestoredLogger {
        // 600 > the 500 cap, so the oldest 100 must be dropped and counted.
        let runID = UUID().uuidString
        for i in 0..<600 {
          await AppLogger.shared.log(
            "EW1361-bound-\(runID)-\(i)", level: .info, category: "AppLogger1361")
        }
        let held = await AppLogger.shared.pendingPreSinkLineCount
        #expect(held == 500, "the buffer must cap at 500, got \(held)")

        await AppLogger.shared.setDebugMode(true)
        let contents = readLog()
        #expect(
          contents.contains("dropped at the 500 cap"),
          "an overflowing buffer must say so rather than silently truncate")
        #expect(
          contents.contains("EW1361-bound-\(runID)-599"),
          "the NEWEST line must survive the cap")
        #expect(
          !contents.contains("EW1361-bound-\(runID)-0 "),
          "the OLDEST line is the one dropped")
      }
    }
  }
#endif
