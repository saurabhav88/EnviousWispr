import ApplicationServices
import EnviousWisprServices
import Foundation
import Testing

/// `paste.landing_observed` (#3106): one row per committed arrival session, shape only.
///
/// When these fail, the reader that decides step 2 counts a paste twice or not at all, joins a
/// landing to the wrong dictation, or receives the text, the app's bundle id or the host's
/// accessibility flag, which the privacy boundary forbids.
///
/// Two halves, so no test holds the process-wide telemetry hook across an `await` (other suites
/// replace it in parallel; second-pass review, #3106):
/// - the SESSION's observation is captured through its injected reporter;
/// - the EMITTER's payload is read through `testRawPropertiesHook` around one synchronous call on
///   the main actor, which nothing can interleave.
@MainActor
@Suite(
  "Paste arrival session: its telemetry row (#3106)", .tags(.observabilityContract), .serialized)
struct PasteLandingTelemetryTests {

  /// A readable TextEdit-shaped target, as in `PasteLandingLifecycleTests`: pid 42 frontmost, its
  /// field focused and owned by it, the text unchanged across the watch.
  @MainActor
  private final class Rig {
    let ax = PastedRegionFakeAX()
    let clock = PastedRegionFakeScheduler()
    var lines: [String] = []
    var rows: [PasteArrivalObservation] = []
    init() {
      ax.focusedByApplication[42] = .element(PastedRegionFakeAX.field(42))
      ax.focused[42] = .element(PastedRegionFakeAX.field(42))
      ax.reads = [.text("Hello")]
      ax.selectedRange = .range(location: 5, length: 0)
    }
    func prepare(tier: PasteTier = .cgEvent, takeID: String?) -> PasteArrivalCapture? {
      PasteArrivalCapture.prepare(
        .init(
          tier: tier, pid: 42, takeID: takeID, bundleID: "com.apple.TextEdit",
          payload: "send the draft to Maya"),
        capturedTarget: PastedRegionFakeAX.field(42), restoringCapturedTimeoutTo: 0, ax: ax,
        scheduler: clock, report: { self.rows.append($0) }, log: { self.lines.append($0) })
    }
    var registration: PastedRegionFakeRegistration? { ax.landingRegistrations.last }
    /// Commit, then run the clock past the deadline and the whole late-hit shadow.
    func ran(_ session: PasteArrivalCapture) {
      session.commit()
      clock.advance(ms: 1_500)
    }
  }

  private struct NotPrepared: Error {}
  private func prepared(_ session: PasteArrivalCapture?) throws -> PasteArrivalCapture {
    guard let session else { throw NotPrepared() }
    return session
  }

  // MARK: The session's row

  @Test("One row carrying the session's take id, tier, landing, class, window, timings and late check")
  func rowValues() throws {
    let rig = Rig()
    rig.ran(try prepared(rig.prepare(takeID: "TAKE-ROW")))
    #expect(
      rig.rows == [
        PasteArrivalObservation(
          takeID: "TAKE-ROW", tier: "cgevent", landing: .absent, appClass: .native,
          hostExposedFocus: true, targetWindow: .unknown, beforeMs: 0, resolveMs: 300,
          lateCheck: .completedNoHit)
      ])
  }

  @Test("Each of the three key-paste tiers names itself")
  func threeTiers() throws {
    for (tier, name) in [
      (PasteTier.cgEvent, "cgevent"), (.appleScript, "applescript"), (.menuPaste, "menu_paste"),
    ] {
      let rig = Rig()
      rig.ran(try prepared(rig.prepare(tier: tier, takeID: "TAKE-T")))
      #expect(rig.rows.map(\.tier) == [name])
    }
  }

  @Test("A cancelled or never-committed session reports nothing; its committed control reports one")
  func noRowWithoutCommit() throws {
    let rig = Rig()
    let cancelled = try prepared(rig.prepare(takeID: "TAKE-C"))
    cancelled.cancelUnlessCommitted()
    rig.clock.advance(ms: 1_500)
    let uncommitted = try prepared(rig.prepare(takeID: "TAKE-C"))
    rig.clock.advance(ms: 1_500)
    uncommitted.cancelUnlessCommitted()
    #expect(rig.rows.isEmpty)

    let control = Rig()
    control.ran(try prepared(control.prepare(takeID: "TAKE-C")))
    #expect(control.rows.count == 1)
  }

  @Test("An early find, a full-shadow miss and a cancellation each report exactly one row")
  func onceOnEveryTerminalPath() throws {
    let found = Rig()
    let early = try prepared(found.prepare(takeID: "TAKE-F"))
    found.ax.reads = [.text("Hello send the draft to Maya")]
    early.commit()
    found.registration?.fire(.valueChanged)
    found.clock.advance(ms: 2_000)
    #expect(found.rows.map(\.lateCheck) == [.notApplicable])

    let miss = Rig()
    miss.ran(try prepared(miss.prepare(takeID: "TAKE-M")))
    miss.clock.advance(ms: 2_000)
    #expect(miss.rows.map(\.lateCheck) == [.completedNoHit])

    let cancel = Rig()
    let session = try prepared(cancel.prepare(takeID: "TAKE-X"))
    session.commit()
    cancel.clock.advance(ms: 400)
    session.cancel()
    session.cancel()
    cancel.clock.advance(ms: 2_000)
    #expect(cancel.rows.map(\.lateCheck) == [.censored])
  }

  @Test("A session with no take id still reports, with none invented, and keeps its log line")
  func missingTakeID() throws {
    let rig = Rig()
    rig.ran(try prepared(rig.prepare(takeID: nil)))
    #expect(rig.rows.count == 1 && rig.rows[0].takeID == nil)
    #expect(rig.lines.count == 1 && rig.lines[0].hasPrefix("PASTE_LANDING tier=cgevent observed=absent"))
  }

  // MARK: The emitter's payload (DEBUG hook, read synchronously)

  #if DEBUG
    /// The raw dictionaries `capture` receives during one synchronous main-actor call. The hook in
    /// place before is kept: every other event still reaches it during the call, and it is put
    /// back after, so a suite waiting on its own hook is never left with a cleared one.
    private func rawRows(_ emit: () -> Void) -> [[String: Any]] {
      let box = RawBox()
      let prior = TelemetryService.shared.testRawPropertiesHook
      TelemetryService.shared.testRawPropertiesHook = { @Sendable name, props in
        guard name == "paste.landing_observed" else {
          prior?(name, props)
          return
        }
        nonisolated(unsafe) let props = props
        MainActor.assumeIsolated { box.rows.append(props) }
      }
      defer { TelemetryService.shared.testRawPropertiesHook = prior }
      emit()
      return box.rows
    }

    @MainActor private final class RawBox { var rows: [[String: Any]] = [] }

    private static let row = PasteArrivalObservation(
      takeID: "TAKE-RAW", tier: "cgevent", landing: .absent, appClass: .native,
      hostExposedFocus: true, targetWindow: .unknown, beforeMs: 3, resolveMs: 312,
      lateCheck: .completedNoHit)

    @Test("The live reporter sends exactly ten keys, each of the approved type")
    func rawShape() throws {
      let raws = rawRows { PasteArrivalCapture.liveReport(Self.row) }
      #expect(raws.count == 1)
      let raw = try #require(raws.first)
      #expect(
        Set(raw.keys) == [
          "take_id", "tier", "observed", "reason", "app_class", "target_window",
          "host_exposed_focus", "before_ms", "resolve_ms", "late_check_status",
        ])
      #expect(raw["take_id"] as? String == "TAKE-RAW")
      #expect(raw["tier"] as? String == "cgevent")
      #expect(raw["observed"] as? String == "absent")
      #expect(raw["reason"] as? String == "absent")
      #expect(raw["app_class"] as? String == "native")
      #expect(raw["target_window"] as? String == "unknown")
      #expect(raw["host_exposed_focus"] as? Bool == true)
      #expect(raw["before_ms"] as? Int == 3 && raw["resolve_ms"] as? Int == 312)
      #expect(raw["late_check_status"] as? String == "completed_no_hit")
    }

    @Test("A late hit adds late_found_ms as a number; a row with no take id omits the key")
    func rawLateHitAndMissingTakeID() throws {
      let late = PasteArrivalObservation(
        takeID: nil, tier: "menu_paste", landing: .noTarget, appClass: .browser,
        hostExposedFocus: false, targetWindow: .same, beforeMs: 1, resolveMs: 300,
        lateCheck: .found(ms: 640))
      let raw = try #require(rawRows { PasteArrivalCapture.liveReport(late) }.first)
      #expect(raw["take_id"] == nil)
      #expect(raw["observed"] as? String == "no_target" && raw["reason"] as? String == "no_target")
      #expect(raw["late_check_status"] as? String == "found")
      #expect(raw["late_found_ms"] as? Int == 640)
      #expect(raw.count == 10)
    }

    @Test("No text, bundle id or manual-accessibility flag leaves in the payload")
    func privacy() throws {
      let raw = try #require(rawRows { PasteArrivalCapture.liveReport(Self.row) }.first)
      #expect(Set(raw.keys).isDisjoint(with: ["app", "bundle_id", "manual_ax", "payload", "text"]))
      for value in raw.values.compactMap({ $0 as? String }) {
        #expect(!value.contains("com.apple"), "no bundle id: \(value)")
      }
    }
  #endif
}
