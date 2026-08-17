import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprLLM
@testable import EnviousWisprModelDelivery

/// The analytics vocabulary for `eg1.paused_install_state_changed` (#2109).
///
/// The event exists because `updatePaused` is a state a user can sit in for
/// days with polish silently off, and nothing else proves residency. Its value
/// therefore depends entirely on the vocabulary being stable and on the two
/// update situations being distinguishable.
@Suite struct EGOneInstallStateTelemetryTests {

  /// The analytics values are declared on the enum as raw strings, not derived
  /// from Swift case names, precisely so a rename cannot silently change them.
  /// A shifted value splits every historical comparison in two, and the break
  /// is invisible until someone wonders why a number halved.
  @Test func pausedStateNamesArePinned() {
    #expect(EGOnePausedInstallState.paused.rawValue == "paused")
    #expect(EGOnePausedInstallState.updatePaused.rawValue == "update_paused")
    #expect(EGOnePausedInstallState.updatePausedResumable.rawValue == "update_paused_resumable")
  }

  /// Only paused states have a projection. Everything else is nil, which the
  /// bridge reports as "none" — an EXIT from a paused state, which is half the
  /// residency question.
  @Test func onlyPausedStatesProject() {
    #expect(EGOnePausedInstallState.projection(of: .paused) == .paused)
    #expect(
      EGOnePausedInstallState.projection(of: .updatePaused(resumable: true, targetVersion: "1.1"))
        == .updatePausedResumable)
    #expect(
      EGOnePausedInstallState.projection(of: .updatePaused(resumable: false, targetVersion: "1.1")) == .updatePaused)
    for state: EGOneInstallState in [
      .notInstalled, .downloading(fractionCompleted: 0.5), .verifying,
      .installed(version: "1.1"), .failed(.network),
    ] {
      #expect(EGOnePausedInstallState.projection(of: state) == nil, "\(state) must not project")
    }
  }

  /// The two update situations stay distinguishable. Someone who STARTED the
  /// upgrade and stopped is a different problem from someone who never began:
  /// the first suggests the download is failing, the second that the prompt is
  /// not landing. One name would hide which.
  @Test func theTwoUpdateSituationsAreDistinguishable() {
    #expect(
      EGOnePausedInstallState.projection(of: .updatePaused(resumable: true, targetVersion: "1.1"))
        != EGOnePausedInstallState.projection(of: .updatePaused(resumable: false, targetVersion: "1.1")))
  }

  /// The version never reaches telemetry: the projection carries no payload,
  /// so a free-form version string cannot make the property unbounded.
  @Test func theVersionNeverReachesTelemetry() {
    #expect(EGOnePausedInstallState.projection(of: .installed(version: "1.1")) == nil)
    #expect(EGOnePausedInstallState.projection(of: .installed(version: nil)) == nil)
  }

  /// THE test this event exists to survive, and the one that refuted the
  /// original design.
  ///
  /// `adoptIfPresent` runs on every settings-open and CYCLES the state:
  /// measured as update_paused, verifying, update_paused, verifying,
  /// update_paused, verifying, update_paused across three probes. Under the
  /// first design — a general install-state-changed event — that emitted twice
  /// per settings visit, so the metric would have read as a growing population
  /// of affected users while actually counting panel opens.
  ///
  /// Now `.verifying` is skipped before the comparison, so a cycle returning
  /// to the same paused state is silent. One entry event, no matter how many
  /// times the user opens the panel.
  @MainActor
  @Test func settingsProbeCyclesDoNotInflateTheCount() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("eg1-tel-\(UUID().uuidString)", isDirectory: true)
    let install = root.appendingPathComponent("Models/eg-1", isDirectory: true)
    let metadata = root.appendingPathComponent("ModelDelivery", isDirectory: true)
    try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let registration = try EGOneDeliveryAdapterMappingTests.shardedFixtureRegistration(
      install: install, metadata: metadata)

    // A surviving older revision: the launch state under test.
    let identity = registration.manifest.identity
    let older = "\(identity.family.rawValue)-\(identity.name)-v1-legacy-\(identity.variant)"
    let legacy = install.appendingPathComponent("eg-1-v1-legacy.gguf")
    try Data([0xAB, 0xCD]).write(to: legacy)
    let attrs = try FileManager.default.attributesOfItem(atPath: legacy.path)
    try JSONSerialization.data(withJSONObject: [
      "manifestDigest": "older", "admittedAt": 0,
      "files": [
        [
          "path": "eg-1-v1-legacy.gguf",
          "sizeBytes": attrs[.size] as? Int64 ?? 2,
          "mtime": (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
        ]
      ],
    ]).write(to: metadata.appendingPathComponent("\(older).admission.json"))

    let suite = "eg1-tel-\(UUID().uuidString)"
    let store = try #require(UserDefaults(suiteName: suite))
    defer { store.removePersistentDomain(forName: suite) }

    let recorded = Recorded()
    let adapter = EGOneDeliveryAdapter(
      controller: ModelDeliveryController(defaults: UserDefaults(suiteName: suite)!),
      registration: registration, version: "1.1", defaults: store)
    let runtime = EGOneRuntime(
      manifest: EGOneManifest(
        modelName: LLMProvider.egOneModelName, version: "v2-sharded", contextTokens: 4096,
        promptTemplateID: "eg1-v1", minAppVersion: "0",
        downloadURL: URL(string: "https://example.invalid/eg1.gguf")!, displayVersion: "1.1"),
      serverBinaryURL: nil, delivery: adapter, defaults: store)
    runtime.onEvent = { event in
      if case .pausedInstallStateChanged(let projection) = event {
        recorded.append(projection?.rawValue ?? "none")
      }
    }

    let settled = await withDeadline(seconds: 5) {
      while true {
        if await MainActor.run(body: { runtime.installState == .updatePaused(resumable: false, targetVersion: "1.1") }) {
          return true
        }
        await Task.yield()
      }
    }
    try #require(settled == true, "the launch state under test was never reached")

    // Three settings-open probes, each of which cycles the state through
    // verifying and back. This is the exact sequence that broke the first
    // design; it must now produce no additional events.
    for _ in 0..<3 {
      _ = await adapter.adoptIfPresent()
      await Task.yield()
    }
    let stillPaused = await MainActor.run {
      runtime.installState == .updatePaused(resumable: false, targetVersion: "1.1")
    }
    try #require(stillPaused == true, "the probe changed the resting state, so this proves nothing")

    #expect(
      recorded.all == ["update_paused"],
      "settings-open probes inflated the count, got \(recorded.all)")

    // THE EXIT HALF. Entry alone identifies the affected population; only the
    // exit bounds how long they stayed there, which is the residency question
    // the event exists to answer. Without this, half the measurement is
    // unproven and a user who resolved their pause would look permanently
    // stuck.
    runtime.startDownload()
    let exited = await withDeadline(seconds: 5) {
      while true {
        if await MainActor.run(body: { recorded.all == ["update_paused", "none"] }) { return true }
        await Task.yield()
      }
    }
    #expect(
      exited == true,
      "leaving the paused state emitted no exit event, got \(recorded.all)")

    // Drain the attempt this test started. An undrained fetch outlives the
    // test and keeps touching a temp directory the defer above is about to
    // delete, which surfaces later as an unrelated suite failing for reasons
    // nobody can trace back here.
    await adapter.cancel()
  }

  private final class Recorded: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func append(_ n: String) {
      lock.lock()
      names.append(n)
      lock.unlock()
    }
    var all: [String] {
      lock.lock()
      defer { lock.unlock() }
      return names
    }
  }

  // MARK: - Residency across launches (whole-diff review)

  /// A pause OUTLIVES the process, and the tracker has to as well.
  ///
  /// Without persistence a user who leaves an upgrade paused and quits emits a
  /// fresh ENTRY on every launch with no matching exit. After a week that is
  /// seven entries and eventually one exit, and no query can say which entry
  /// the exit belongs to — so the duration this event exists to measure is
  /// uncomputable from data that looks perfectly healthy.
  @MainActor
  @Test func aPauseCarriedAcrossLaunchesDoesNotReEmitEntry() async throws {
    let suite = "eg1-tel-\(UUID().uuidString)"
    let store = try #require(UserDefaults(suiteName: suite))
    defer { store.removePersistentDomain(forName: suite) }

    // First launch: enters the paused state and records one entry.
    let first = Recorded()
    let runtimeA = EGOneRuntime(
      manifest: nil, serverBinaryURL: nil, delivery: nil, defaults: store)
    runtimeA.onEvent = { event in
      if case .pausedInstallStateChanged(let p) = event { first.append(p?.rawValue ?? "none") }
    }
    runtimeA.applyInstallStateForTesting(.updatePaused(resumable: false, targetVersion: "1.1"))
    #expect(first.all == ["update_paused"])

    // SECOND LAUNCH: a brand-new runtime over the same storage, seeing the same
    // paused state. It must stay silent — the user never left the pause.
    let second = Recorded()
    let runtimeB = EGOneRuntime(
      manifest: nil, serverBinaryURL: nil, delivery: nil, defaults: store)
    runtimeB.onEvent = { event in
      if case .pausedInstallStateChanged(let p) = event { second.append(p?.rawValue ?? "none") }
    }
    runtimeB.applyInstallStateForTesting(.updatePaused(resumable: false, targetVersion: "1.1"))
    #expect(
      second.all.isEmpty,
      "a relaunch into the SAME pause re-emitted an entry, so the exit cannot be paired: \(second.all)")
  }

  /// The other half: a pause resolved while the app was CLOSED must still
  /// close. At launch `installState` starts `.notInstalled` and the seed
  /// publishes `.notInstalled` too — the same value — so a reconciliation
  /// placed after the UI dedupe would early-return and leave the entry open
  /// forever.
  @MainActor
  @Test func aPauseResolvedWhileClosedEmitsItsExitOnNextLaunch() async throws {
    let suite = "eg1-tel-\(UUID().uuidString)"
    let store = try #require(UserDefaults(suiteName: suite))
    defer { store.removePersistentDomain(forName: suite) }

    let first = EGOneRuntime(manifest: nil, serverBinaryURL: nil, delivery: nil, defaults: store)
    first.applyInstallStateForTesting(.updatePaused(resumable: true, targetVersion: "1.1"))

    // Relaunch into `.notInstalled`, which equals the runtime's initial value.
    let recorded = Recorded()
    let second = EGOneRuntime(manifest: nil, serverBinaryURL: nil, delivery: nil, defaults: store)
    second.onEvent = { event in
      if case .pausedInstallStateChanged(let p) = event { recorded.append(p?.rawValue ?? "none") }
    }
    second.applyInstallStateForTesting(.notInstalled)

    #expect(
      recorded.all == ["none"],
      "a pause resolved while the app was closed never emitted its exit: \(recorded.all)")
  }
}
