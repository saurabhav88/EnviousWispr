import ApplicationServices
import EnviousWisprServices
import Foundation
import Testing

/// `paste.landing_observed` (#3106 step 1): one row per committed landing check, shape only.
///
/// When these fail, the reader that decides step 2 counts a paste twice or not at all, joins a
/// verdict to the wrong dictation, or receives the text, the app's bundle id or the host's
/// accessibility flag, which the privacy boundary forbids.
///
/// Two halves, so no test holds the process-wide telemetry hook across an `await` (other suites
/// replace it in parallel; second-pass review, #3106):
/// - the CHECK's row is captured through its injected reporter, across the resolution's await;
/// - the EMITTER's payload is read through `testRawPropertiesHook` around one synchronous call on
///   the main actor, which nothing can interleave.
@MainActor
@Suite(
  "Paste landing check: its telemetry row (#3106)", .tags(.observabilityContract), .serialized)
struct PasteLandingTelemetryTests {

  /// A readable TextEdit-shaped target, as in `PasteLandingLifecycleTests`: pid 42 frontmost, its
  /// field focused and owned by it, the text unchanged across the watch.
  @MainActor
  private final class Rig {
    let ax = PastedRegionFakeAX()
    let clock = PastedRegionFakeScheduler()
    var lines: [String] = []
    var rows: [PasteLandingCheck.Row] = []
    init() {
      ax.focusedByApplication[42] = .element(PastedRegionFakeAX.field(42))
      ax.reads = [.text("Hello"), .text("Hello")]
      ax.selectedRange = .range(location: 5, length: 0)
    }
    func prepare(tier: PasteTier = .cgEvent, takeID: String?) -> PasteLandingCheck? {
      PasteLandingCheck.prepare(
        .init(
          tier: tier, pid: 42, takeID: takeID, bundleID: "com.apple.TextEdit",
          payload: "send the draft to Maya"),
        capturedTarget: PastedRegionFakeAX.field(42), restoringCapturedTimeoutTo: 0, ax: ax,
        scheduler: clock, log: { self.lines.append($0) }, report: { self.rows.append($0) })
    }
    /// Commit, pass the deadline, resolve once.
    func resolved(_ check: PasteLandingCheck) async -> PasteLandingObserved? {
      check.commit()
      clock.advance(ms: 1_500)
      return await check.resolve()
    }
  }

  // MARK: The check's row

  @Test("One row carrying the check's take id, tier, verdict, class, window and timings")
  func rowValues() async throws {
    let rig = Rig()
    let check = try #require(rig.prepare(takeID: "TAKE-ROW"))
    #expect(await rig.resolved(check) == .unchanged(.fieldIdentical))
    #expect(
      rig.rows == [
        PasteLandingCheck.Row(
          takeID: "TAKE-ROW", tier: "cgevent", observed: "unchanged", reason: "field_identical",
          appClass: "native", hostExposedFocus: true, targetWindow: "unknown", beforeMs: 0,
          resolveMs: 1_500)
      ])
  }

  @Test("Each of the three key-paste tiers names itself")
  func threeTiers() async throws {
    for (tier, name) in [
      (PasteTier.cgEvent, "cgevent"), (.appleScript, "applescript"), (.menuPaste, "menu_paste"),
    ] {
      let rig = Rig()
      let check = try #require(rig.prepare(tier: tier, takeID: "TAKE-T"))
      _ = await rig.resolved(check)
      #expect(rig.rows.map(\.tier) == [name])
    }
  }

  @Test("A cancelled or never-committed check reports nothing; its committed control reports one")
  func noRowWithoutCommit() async throws {
    let rig = Rig()
    let cancelled = try #require(rig.prepare(takeID: "TAKE-C"))
    cancelled.cancelUnlessCommitted()
    rig.clock.advance(ms: 1_500)
    #expect(await cancelled.resolve() == nil)
    let uncommitted = try #require(rig.prepare(takeID: "TAKE-C"))
    #expect(await uncommitted.resolve() == nil)
    uncommitted.cancelUnlessCommitted()
    #expect(rig.rows.isEmpty)

    let control = Rig()
    let check = try #require(control.prepare(takeID: "TAKE-C"))
    _ = await control.resolved(check)
    #expect(control.rows.count == 1)
  }

  @Test("Repeated and concurrent resolution report exactly one row")
  func onceUnderRepeatedResolve() async throws {
    let rig = Rig()
    let check = try #require(rig.prepare(takeID: "TAKE-ONCE"))
    check.commit()
    rig.clock.advance(ms: 1_500)
    async let first = check.resolve()
    async let second = check.resolve()
    let verdicts = await [first, second]
    #expect(verdicts[0] == verdicts[1])
    _ = await check.resolve()
    #expect(rig.rows.count == 1)
  }

  @Test("A check with no take id still reports, with none invented, and keeps its log line")
  func missingTakeID() async throws {
    let rig = Rig()
    let check = try #require(rig.prepare(takeID: nil))
    #expect(await rig.resolved(check) == .unchanged(.fieldIdentical))
    #expect(rig.rows.count == 1 && rig.rows[0].takeID == nil)
    #expect(rig.lines.count == 1 && rig.lines[0].hasPrefix("PASTE_LANDING tier=cgevent"))
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

    private static let row = PasteLandingCheck.Row(
      takeID: "TAKE-RAW", tier: "cgevent", observed: "unchanged", reason: "field_identical",
      appClass: "native", hostExposedFocus: true, targetWindow: "unknown", beforeMs: 3,
      resolveMs: 1_512)

    @Test("The live reporter sends exactly nine keys, each of the approved type")
    func rawShape() throws {
      let raws = rawRows { PasteLandingCheck.liveReport(Self.row) }
      #expect(raws.count == 1)
      let raw = try #require(raws.first)
      #expect(
        Set(raw.keys) == [
          "take_id", "tier", "observed", "reason", "app_class", "target_window",
          "host_exposed_focus", "before_ms", "resolve_ms",
        ])
      #expect(raw["take_id"] as? String == "TAKE-RAW")
      #expect(raw["tier"] as? String == "cgevent")
      #expect(raw["observed"] as? String == "unchanged")
      #expect(raw["reason"] as? String == "field_identical")
      #expect(raw["app_class"] as? String == "native")
      #expect(raw["target_window"] as? String == "unknown")
      #expect(raw["host_exposed_focus"] as? Bool == true)
      #expect(raw["before_ms"] as? Int == 3 && raw["resolve_ms"] as? Int == 1_512)
    }

    @Test("A row with no take id is sent without the key, never with an invented one")
    func rawWithoutTakeID() throws {
      let keyless = PasteLandingCheck.Row(
        takeID: nil, tier: "cgevent", observed: "changed", reason: "notified_value",
        appClass: "browser", hostExposedFocus: false, targetWindow: "same", beforeMs: 1,
        resolveMs: 40)
      let raw = try #require(rawRows { PasteLandingCheck.liveReport(keyless) }.first)
      #expect(raw["take_id"] == nil)
      #expect(raw.count == 8)
    }

    @Test("No text, bundle id or manual-accessibility flag leaves in the payload")
    func privacy() throws {
      let raw = try #require(rawRows { PasteLandingCheck.liveReport(Self.row) }.first)
      #expect(Set(raw.keys).isDisjoint(with: ["app", "bundle_id", "manual_ax", "payload", "text"]))
      for value in raw.values.compactMap({ $0 as? String }) {
        #expect(!value.contains("com.apple"), "no bundle id: \(value)")
      }
    }
  #endif
}
