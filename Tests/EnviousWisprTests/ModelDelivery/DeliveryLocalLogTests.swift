import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprModelDelivery

/// #2135 — every `DeliveryEvent` reaches the LOCAL log.
///
/// **Observability Contract, not product coverage.** When these fail, no user
/// sees anything; what breaks is our ability to explain a download from a log
/// someone sends us. Declared so the count is never cited as product safety.
///
/// The whole surface is `#if DEBUG`, because the renderer and its writer are:
/// `AppLogger` compiles to a no-op in release, so building the string and
/// scheduling the write there would be cost paid for a sink that is not present.
#if DEBUG

  @Suite(.tags(.observabilityContract))
  struct DeliveryLocalLogTests {

    private static let identity = ModelIdentity(
      family: .parakeet, name: "test-model", revision: "v1", variant: "unit",
      runtimeABI: "test")

    /// This suite's OWN defaults suite, never the shared one. A controller
    /// reading the real store would make these assertions depend on whatever
    /// delivery flags a developer happens to have set.
    private func testDefaults() -> UserDefaults {
      UserDefaults(suiteName: "ew-2135-local-log-\(UUID().uuidString)") ?? .standard
    }

    /// Pins the EXACT line for every case the enum currently has.
    ///
    /// **Deliberately not "distinct and non-empty".** Eight garbage strings
    /// satisfy that, and so does any renderer that silently drops a field. The
    /// fields ARE the diagnostic — "a failover happened" without naming which
    /// mirror fell over is the shape this issue exists to remove.
    ///
    /// This is SEMANTIC coverage and makes no claim to enumerate the enum: the
    /// exhaustiveness mechanism is the `switch` in `deliveryLogLine`, which the
    /// compiler owns. A ninth case fails to BUILD there; it does not fail here,
    /// and a test that counted cases would be a number that must track code.
    ///
    /// `Model delivery admitted` and `Model delivery failed` are asserted
    /// verbatim because two ad-hoc call sites used to print exactly those words
    /// and someone greps for them today.
    @Test("every delivery event renders its own line, with its own fields")
    func everyEventRendersItsFields() {
      let key = Self.identity.cacheKey
      func line(_ event: DeliveryEvent, _ sequence: UInt64 = 1) -> String {
        ModelDeliveryController.deliveryLogLine(
          identity: Self.identity, event: event, sequence: sequence)
      }

      #expect(
        line(.attemptStarted(resumed: true))
          == "[#1] Model delivery attempt started \(key): resumed=true")

      #expect(
        line(
          .attemptCompleted(
            durationBucket: "10_30s", bytesDownloadedBucket: "100_500mb", sourcesUsed: 2,
            finalSourceID: "backup", repairedComponentsCount: 1))
          == "[#1] Model delivery admitted \(key): duration=10_30s "
            + "bytes=100_500mb sources=2 final_source=backup repaired=1")

      #expect(
        line(
          .attemptFailed(
            reason: .sourceTimeout, failingSourceID: "primary", detail: "read_timeout"))
          == "[#1] Model delivery failed \(key): source_timeout (read_timeout) "
            + "source=primary")

      #expect(
        line(.attemptFailed(reason: .insufficientDisk, failingSourceID: nil, detail: nil))
          == "[#1] Model delivery failed \(key): insufficient_disk",
        "an absent source and detail must add nothing, not empty parentheses")

      #expect(
        line(
          .sourceFailover(reason: .source5xx, fromSourceID: "primary", toSourceID: "backup"))
          == "[#1] Model delivery source failover \(key): primary -> backup, "
            + "reason=source_5xx",
        "naming the transition IS the diagnostic: reason alone cannot say which mirror fell over")

      #expect(
        line(.validationRepair(componentsCount: 3, trigger: .loadMiss))
          == "[#1] Model delivery validation repair \(key): components=3 "
            + "trigger=load_miss")

      #expect(
        line(.cancel(phaseAtCancel: "downloading", resumable: true))
          == "[#1] Model delivery cancelled \(key): phase=downloading resumable=true")

      #expect(
        line(.flagActive(flag: "modelDelivery.parakeet.sourceOrder", value: "backup_first"))
          == "[#1] Model delivery flag active \(key): "
            + "modelDelivery.parakeet.sourceOrder=backup_first")

      #expect(
        line(.admittedWithoutFetch(reason: .markerFastPath))
          == "[#1] Model delivery admitted \(key) without fetch: "
            + "reason=marker_fast_path")

      #expect(
        line(.attemptStarted(resumed: false), 42).hasPrefix("[#42] "),
        "the sequence is the line's own, not a constant")
    }

    /// The local log is written ABOVE the telemetry observer guard, and in order.
    ///
    /// **Both halves are load-bearing and the case is built to prove them
    /// together, because either alone is satisfiable by the wrong code.**
    ///
    /// NO event observer is attached. `emit` returns early into a bounded
    /// 64-entry buffer in that state, so a log call placed below that guard —
    /// or hung off an observer — would produce NOTHING here. That is the
    /// failure this case exists to catch, and it is exactly the state a
    /// launch-window delivery problem happens in.
    ///
    /// **100 events, not 8, and the number is chosen rather than round.** It
    /// exceeds the 64-entry buffer, which keeps its FIRST 64 and discards the
    /// rest. So an implementation that logged from the buffer instead of at the
    /// door would deliver 64 lines and pass any assertion that only counted
    /// "some". Asserting all 100 arrive proves the local path is independent of
    /// that bound rather than merely appearing to be.
    ///
    /// Order is asserted, not just arrival: the sequence is minted on the
    /// controller actor in emit order, and the writer chains each write behind
    /// its predecessor. Separate unstructured Tasks are not FIFO, so without the
    /// chain this arrives shuffled — a log whose whole value is being readable
    /// top to bottom.
    ///
    /// The recorder is installed at the PRODUCTION enqueue path, so this drives
    /// the real renderer and the real chain. It never reads the shared
    /// `app.log`, which two processes write with no rotation lock (#2159).
    @Test("100 events reach the local log in order, with no telemetry observer attached")
    func localLogIsIndependentOfTelemetryAndOrdered() async {
      let controller = ModelDeliveryController(defaults: testDefaults())

      actor Recorder {
        var lines: [String] = []
        func record(_ line: String) { lines.append(line) }
      }
      let recorder = Recorder()
      await controller.setDeliveryLogSinkForTesting { line in await recorder.record(line) }

      let total = 100
      for index in 0..<total {
        await controller.noteFlagActive(
          identity: Self.identity, flag: "probe", value: String(index))
      }
      await controller.flushDeliveryLogsForTesting()

      let lines = await recorder.lines
      #expect(
        lines.count == total,
        """
        expected \(total) lines with NO observer attached; got \(lines.count). Fewer than 100 \
        (and 64 in particular) means the local log is riding the bounded telemetry buffer \
        instead of sitting above it
        """)

      let values = lines.compactMap { line -> Int? in
        guard let equals = line.lastIndex(of: "=") else { return nil }
        return Int(line[line.index(after: equals)...])
      }
      #expect(
        values == Array(0..<total),
        "lines must land in emit order; a shuffled result means the writes are not chained")

      let sequences = lines.compactMap { line -> UInt64? in
        guard let hash = line.firstIndex(of: "#"), let close = line.firstIndex(of: "]") else {
          return nil
        }
        return UInt64(line[line.index(after: hash)..<close])
      }
      #expect(
        sequences == Array(1...UInt64(total)),
        "the sequence must be dense and monotonic, so a reader can see a gap")
    }
  }

#endif
