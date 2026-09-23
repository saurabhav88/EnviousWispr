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
/// The hook is process-wide and other suites resolve checks too, so every assertion reads only the
/// rows carrying THIS test's take id (or, for the missing-id case, rows with none, which no other
/// suite produces). Events come from the real `TelemetryService` emitter, never a copy of it.
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
        scheduler: clock,
        log: { self.lines.append($0) })
    }
  }

  #if DEBUG
    /// Every `paste.landing_observed` row emitted while `body` runs.
    private func landingRows(_ body: () async throws -> Void) async rethrows
      -> [CapturedTelemetryEvent]
    {
      let box = Box()
      TelemetryService.shared.testEventHook = { @Sendable event in
        guard event.name == "paste.landing_observed" else { return }
        MainActor.assumeIsolated { box.events.append(event) }
      }
      defer { TelemetryService.shared.testEventHook = nil }
      try await body()
      return box.events
    }

    @MainActor private final class Box { var events: [CapturedTelemetryEvent] = [] }

    /// The RAW property dictionaries of every `paste.landing_observed` row emitted while `body`
    /// runs: what `capture` receives, before the typed projection drops anything it cannot type.
    private func rawLandingRows(_ body: () async throws -> Void) async rethrows -> [[String: Any]] {
      let box = RawBox()
      TelemetryService.shared.testRawPropertiesHook = { @Sendable name, props in
        guard name == "paste.landing_observed" else { return }
        nonisolated(unsafe) let props = props
        MainActor.assumeIsolated { box.rows.append(props) }
      }
      defer { TelemetryService.shared.testRawPropertiesHook = nil }
      try await body()
      return box.rows
    }

    @MainActor private final class RawBox { var rows: [[String: Any]] = [] }

    private static func mine(_ rows: [CapturedTelemetryEvent], _ takeID: String)
      -> [CapturedTelemetryEvent]
    {
      rows.filter { $0.stringProps["take_id"] == takeID }
    }

    @Test("One row with exactly the approved properties, types and values")
    func exactShape() async throws {
      let take = UUID().uuidString
      let rows = try await landingRows {
        let rig = Rig()
        let check = try #require(rig.prepare(takeID: take))
        check.commit()
        rig.clock.advance(ms: 1_500)
        #expect(await check.resolve() == .unchanged(.fieldIdentical))
      }
      let row = try #require(Self.mine(rows, take).first)
      #expect(Self.mine(rows, take).count == 1)
      #expect(
        row.stringProps == [
          "take_id": take, "tier": "cgevent", "observed": "unchanged", "reason": "field_identical",
          "app_class": "native", "target_window": "unknown",
        ])
      #expect(row.intProps == ["before_ms": 0, "resolve_ms": 1_500])
      #expect(row.boolProps == ["host_exposed_focus": true])
      #expect(row.doubleProps.isEmpty)
    }

    @Test("The raw payload has exactly nine keys, each of the approved type, and nothing else")
    func rawShape() async throws {
      let take = UUID().uuidString
      let raws = try await rawLandingRows {
        let rig = Rig()
        let check = try #require(rig.prepare(takeID: take))
        check.commit()
        rig.clock.advance(ms: 1_500)
        _ = await check.resolve()
      }
      let raw = try #require(raws.first { $0["take_id"] as? String == take })
      #expect(raws.filter { $0["take_id"] as? String == take }.count == 1)
      #expect(
        Set(raw.keys) == [
          "take_id", "tier", "observed", "reason", "app_class", "target_window",
          "host_exposed_focus", "before_ms", "resolve_ms",
        ])
      for key in ["take_id", "tier", "observed", "reason", "app_class", "target_window"] {
        #expect(raw[key] is String, "\(key) is a String")
      }
      #expect(raw["host_exposed_focus"] is Bool)
      #expect(raw["before_ms"] is Int && raw["resolve_ms"] is Int)
    }

    @Test("No text, bundle id or manual-accessibility flag leaves in the row")
    func privacy() async throws {
      let take = UUID().uuidString
      let rows = try await landingRows {
        let rig = Rig()
        let check = try #require(rig.prepare(takeID: take))
        check.commit()
        rig.clock.advance(ms: 1_500)
        _ = await check.resolve()
      }
      let row = try #require(Self.mine(rows, take).first)
      let keys =
        Set(row.stringProps.keys).union(row.intProps.keys).union(row.boolProps.keys)
        .union(row.doubleProps.keys)
      #expect(keys.isDisjoint(with: ["app", "bundle_id", "manual_ax", "payload", "text"]))
      for value in row.stringProps.values {
        #expect(!value.contains("Maya") && !value.contains("Hello"), "no text: \(value)")
        #expect(!value.contains("com.apple"), "no bundle id: \(value)")
      }
    }

    @Test("Each of the three key-paste tiers names itself")
    func threeTiers() async throws {
      var seen: [String] = []
      for (tier, name) in [
        (PasteTier.cgEvent, "cgevent"), (.appleScript, "applescript"),
        (.menuPaste, "menu_paste"),
      ] {
        let take = UUID().uuidString
        let rows = try await landingRows {
          let rig = Rig()
          let check = try #require(rig.prepare(tier: tier, takeID: take))
          check.commit()
          rig.clock.advance(ms: 1_500)
          _ = await check.resolve()
        }
        #expect(Self.mine(rows, take).map { $0.stringProps["tier"] } == [name])
        seen.append(name)
      }
      #expect(seen.count == 3)
    }

    @Test(
      "A cancelled or never-committed check emits nothing; its paired committed control emits one")
    func noRowWithoutCommit() async throws {
      let take = UUID().uuidString
      let rows = try await landingRows {
        let rig = Rig()
        let cancelled = try #require(rig.prepare(takeID: take))
        cancelled.cancelUnlessCommitted()
        rig.clock.advance(ms: 1_500)
        #expect(await cancelled.resolve() == nil)
        let uncommitted = try #require(rig.prepare(takeID: take))
        #expect(await uncommitted.resolve() == nil)
        uncommitted.cancelUnlessCommitted()
      }
      #expect(Self.mine(rows, take).isEmpty)

      let control = UUID().uuidString
      let controlRows = try await landingRows {
        let rig = Rig()
        let check = try #require(rig.prepare(takeID: control))
        check.commit()
        rig.clock.advance(ms: 1_500)
        _ = await check.resolve()
      }
      #expect(Self.mine(controlRows, control).count == 1)
    }

    @Test("Repeated and concurrent resolution emit exactly one row")
    func onceUnderRepeatedResolve() async throws {
      let take = UUID().uuidString
      let rows = try await landingRows {
        let rig = Rig()
        let check = try #require(rig.prepare(takeID: take))
        check.commit()
        rig.clock.advance(ms: 1_500)
        async let first = check.resolve()
        async let second = check.resolve()
        let verdicts = await [first, second]
        #expect(verdicts[0] == verdicts[1])
        _ = await check.resolve()
      }
      #expect(Self.mine(rows, take).count == 1)
    }

    @Test("A check with no take id still emits, without take_id, and keeps its log line")
    func missingTakeID() async throws {
      var lines: [String] = []
      let rows = try await landingRows {
        let rig = Rig()
        let check = try #require(rig.prepare(takeID: nil))
        check.commit()
        rig.clock.advance(ms: 1_500)
        #expect(await check.resolve() == .unchanged(.fieldIdentical))
        lines = rig.lines
      }
      let keyless = rows.filter { $0.stringProps["take_id"] == nil }
      #expect(keyless.count == 1, "never invented, never suppressed")
      #expect(keyless.first?.stringProps["observed"] == "unchanged")
      #expect(lines.count == 1 && lines[0].hasPrefix("PASTE_LANDING tier=cgevent"))
    }
  #endif
}
