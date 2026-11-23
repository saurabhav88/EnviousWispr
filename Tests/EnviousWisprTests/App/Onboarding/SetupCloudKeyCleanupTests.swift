import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprLLM

/// #4528 D3b integration review r1 (plan M82, T6/§7): a key See all's cloud panel stored that did
/// not pass leaves the store when the person leaves that provider, even when its check ends after
/// they left; a passed key and a newer replacement stay. The live checks run the real
/// CredentialWriter, SavedKeyPresence and discovery owners over an isolated file key store (never
/// the Keychain), with a scripted provider answer.
@MainActor
@Suite("Setup cloud key cleanup", .tags(.productOutcome))
struct SetupCloudKeyCleanupTests {
  // MARK: Ledger

  private final class Discards {
    var log: [String] = []
  }

  private static func ledger(_ d: Discards) -> SetupCloudKeyLedger {
    SetupCloudKeyLedger { provider, revision in d.log.append("\(provider.rawValue)#\(revision)") }
  }

  @Test("a write that did not pass goes when its provider is left; a passed write stays")
  func ledgerSettlesOnLeave() {
    let d = Discards()
    let ledger = Self.ledger(d)
    let rejected = ledger.begin(.openAI)
    ledger.finish(rejected, revision: 3, passed: false)
    let passed = ledger.begin(.claude)
    ledger.finish(passed, revision: 7, passed: true)
    #expect(d.log.isEmpty)  // nothing goes before the person leaves
    ledger.leave(.claude)
    #expect(d.log.isEmpty, "a passed key was removed")
    ledger.leave(.openAI)
    #expect(d.log == ["openAI#3"])
    ledger.leave(.openAI)
    #expect(d.log == ["openAI#3"], "one write was removed twice")
  }

  @Test(
    "leaving during a pending check removes the write when it ends unpassed, keeps it when it passes"
  )
  func ledgerPendingLeave() {
    let d = Discards()
    let ledger = Self.ledger(d)
    let pendingFail = ledger.begin(.gemini)
    let pendingPass = ledger.begin(.openAI)
    ledger.leave(nil)  // See all closed while both checks run
    #expect(d.log.isEmpty)
    ledger.finish(pendingPass, revision: 2, passed: true)
    ledger.finish(pendingFail, revision: 5, passed: false)
    #expect(d.log == ["gemini#5"])
  }

  @Test("a replaced write and a failed store remove nothing")
  func ledgerReplacedAndUnstored() {
    let d = Discards()
    let ledger = Self.ledger(d)
    let old = ledger.begin(.openAI)
    let new = ledger.begin(.openAI)  // the person checked again before the first ended
    ledger.finish(old, revision: 1, passed: false)
    ledger.finish(new, revision: nil, passed: false)  // the store failed: nothing known stored
    ledger.leave(.openAI)
    #expect(d.log.isEmpty)
  }

  @Test("a write left while still queued is never adopted, so nothing is stored or removed")
  func ledgerQueuedLeave() {
    let d = Discards()
    let ledger = Self.ledger(d)
    ledger.begin(.openAI)
    ledger.leave(.openAI)
    #expect(ledger.adopt(.openAI) == nil, "a queued write that was left went on to store")
    #expect(d.log.isEmpty)
  }

  @Test("a write that re-stores the unchanged saved key is never removed")
  func ledgerKeepsUnchangedSavedKey() {
    let d = Discards()
    let ledger = Self.ledger(d)
    let write = ledger.begin(.openAI, keep: true)
    _ = ledger.adopt(.openAI)
    ledger.finish(write, revision: 4, passed: false)
    ledger.leave(nil)
    #expect(d.log.isEmpty)
  }

  // MARK: Live owners

  private enum Answer { case accept, reject, inconclusive }

  private final class Script: @unchecked Sendable {
    var answer = Answer.reject
    var gate: BoundedWait.Signal?
    let entered = BoundedWait.Signal()
  }

  @MainActor
  private struct Fixture {
    let settings: SettingsManager
    let presence: SavedKeyPresence
    let access: CredentialAccessLane
    let discovery: LLMModelDiscoveryCoordinator
    let writer: CredentialWriter
    /// No published list: no file, no network.
    let list = CloudModelListHolder(
      store: CloudModelListStore(
        bundled: nil,
        persistedURL: TestTemporaryDirectory.url.appending(path: "\(UUID().uuidString).json"),
        fetch: { throw URLError(.notConnectedToInternet) }),
      log: { _ in })
    let script = Script()

    init() {
      let defaults = TestDefaults.suite("ew.tests.setup-cloud-cleanup.\(UUID().uuidString)")!
      settings = SettingsManager(defaults: defaults)
      presence = SavedKeyPresence()
      let manager = KeychainManager(
        backend: .legacyFiles,
        legacyStore: FileLegacyKeyStore(
          storageDirectory: TestTemporaryDirectory.url.appending(path: UUID().uuidString)))
      access = CredentialAccessLane()
      let script = script
      discovery = LLMModelDiscoveryCoordinator(
        keychainManager: manager, cacheDefaults: defaults, savedKeyPresence: presence,
        credentialAccess: access, validationEmitter: { _, _, _, _, _ in },
        setupDiscovery: { provider, _, didList in
          script.entered.fire()
          if let gate = script.gate { try await BoundedWait.until(gate) }
          switch script.answer {
          case .accept:
            await didList()
            return [
              LLMModelInfo(
                id: "example", displayName: "Example", provider: provider,
                availability: .available, isRemote: true)
            ]
          case .reject: throw LLMError.invalidAPIKey
          case .inconclusive: throw URLError(.timedOut)
          }
        },
        discoverModels: { _, _ in [] })
      writer = CredentialWriter(
        keychainManager: manager, presence: presence, discovery: discovery, access: access,
        emit: { _, _, _ in })
    }

    func panel(_ events: Events) -> SetupCloudPanelModel {
      SetupCloudPanelModel.live(
        settings: settings, writer: writer, list: list, report: { events.log.append($0) })
    }

    /// Every credential operation queued before this call has finished (the shared lane runs
    /// them in order).
    func drained() async { await access.run {} }
  }

  private final class Events {
    var log: [SetupKeyEvent] = []
  }

  private static func type(_ key: String, into panel: SetupCloudPanelModel) {
    panel.edit(key)
  }

  @Test(
    "a rejected key leaves the store on Add my key later; the events read saved, then rejected, then skipped"
  )
  func rejectedKeyRemovedOnLater() async throws {
    let f = Fixture()
    let events = Events()
    let panel = f.panel(events)
    Self.type("sk-not-a-real-key", into: panel)
    let check = try #require(panel.check())
    await check.value
    #expect(panel.phase == .rejected)
    #expect(f.presence.savedFlag(for: .openAI) == true)  // stored until the person leaves
    panel.later()
    panel.dispose()
    await f.drained()
    #expect(f.presence.savedFlag(for: .openAI) == false, "the rejected key stayed saved")
    guard case .rejected(.openAI, _) = events.log.dropFirst().first else {
      Issue.record("events: \(events.log)")
      return
    }
    #expect(events.log.first == .saved && events.log.last == .skipped)
  }

  @Test("a passed key stays when the person switches provider and when See all closes")
  func passedKeyStays() async throws {
    let f = Fixture()
    f.script.answer = .accept
    let events = Events()
    let panel = f.panel(events)
    Self.type("sk-good", into: panel)
    let check = try #require(panel.check())
    await check.value
    #expect(panel.phase == .picker && events.log == [.saved, .passed])
    panel.provider = .claude
    panel.dispose()
    await f.drained()
    #expect(f.presence.savedFlag(for: .openAI) == true, "a passed key was removed")
  }

  @Test("an inconclusive check's key goes when the person switches provider")
  func inconclusiveKeyRemovedOnSwitch() async throws {
    let f = Fixture()
    f.script.answer = .inconclusive
    let panel = f.panel(Events())
    Self.type("sk-maybe", into: panel)
    let check = try #require(panel.check())
    await check.value
    #expect(panel.phase == .retry)
    panel.provider = .gemini
    await f.drained()
    #expect(f.presence.savedFlag(for: .openAI) == false)
  }

  @Test(
    "leaving during a pending check removes the key once the check rejects it, and reports nothing")
  func pendingCheckCleanedAfterLeave() async throws {
    let f = Fixture()
    let gate = BoundedWait.Signal()
    f.script.gate = gate
    let events = Events()
    let panel = f.panel(events)
    Self.type("sk-slow", into: panel)
    let check = try #require(panel.check())
    try await BoundedWait.until(f.script.entered)
    panel.dispose()  // See all closed mid-check
    gate.fire()
    await check.value
    await f.drained()
    #expect(f.presence.savedFlag(for: .openAI) == false, "the late-rejected key stayed saved")
    #expect(events.log == [.saved], "a disposed panel reported its stale answer: \(events.log)")
  }

  @Test("leaving before the check task runs stores no key and reports nothing")
  func queuedLeaveStoresNothing() async throws {
    let f = Fixture()
    let events = Events()
    let panel = f.panel(events)
    Self.type("sk-never", into: panel)
    let check = try #require(panel.check())
    panel.dispose()  // same main-actor turn: the check task has not started
    await check.value
    await f.drained()
    #expect(f.presence.savedFlag(for: .openAI) != true, "a key was stored after the person left")
    #expect(events.log.isEmpty, "events: \(events.log)")
    #expect(panel.check() == nil, "a disposed panel started a check")
  }

  @Test("Add my key later while the save is held: the key is removed and nothing follows skipped")
  func saveHeldLeave() async throws {
    let f = Fixture()
    let events = Events()
    let panel = f.panel(events)
    Self.type("sk-held", into: panel)
    let hold = f.access.reserve()  // an earlier credential operation holds the lane
    let queued = BoundedWait.Signal()
    f.access.onQueuedForTesting = { queued.fire() }
    let check = try #require(panel.check())
    // The save has begun its mutation and queued behind the held lane.
    try await BoundedWait.until(queued)
    try #require(f.presence.hasPendingMutation(for: .openAI), "the save never started")
    panel.later()
    panel.dispose()
    await f.access.run(turn: hold) {}  // release: the held save now stores, then is checked
    await check.value
    await f.drained()
    #expect(f.presence.savedFlag(for: .openAI) == false, "the save-held key stayed saved")
    #expect(events.log == [.skipped], "a late row followed skipped: \(events.log)")
  }

  @Test("re-checking the already-saved key offline, then Add my key later, keeps that key")
  func savedKeyRecheckSurvivesInconclusive() async throws {
    let f = Fixture()
    f.script.answer = .accept
    let stored = await f.writer.save(
      "saved-before-setup", for: .openAI, settings: f.settings, surface: .dictation)
    guard case .stored(let validation, _) = stored else {
      Issue.record("the earlier key was not stored")
      return
    }
    await validation.value
    let panel = f.panel(Events())
    panel.hydrate()
    await f.drained()  // the key read runs on the shared lane
    #expect(panel.keys.hasCompletedKeyRead && panel.key == "saved-before-setup")
    f.script.answer = .inconclusive  // offline: the re-check cannot finish
    let check = try #require(panel.check())
    await check.value
    #expect(panel.phase == .retry)
    panel.later()
    panel.dispose()
    await f.drained()
    #expect(f.presence.savedFlag(for: .openAI) == true, "Setup deleted the person's saved key")
  }

  @Test(
    "a key that passed in Setup survives a timed-out re-check of the same key; a different unpassed key typed after it is still removed"
  )
  func passedKeyRecheckSurvivesTimeout() async throws {
    let f = Fixture()
    f.script.answer = .accept
    let panel = f.panel(Events())
    Self.type("  typed-and-passed\n", into: panel)  // pasted with surrounding whitespace
    var check = try #require(panel.check())
    await check.value
    #expect(panel.phase == .picker)
    f.script.answer = .inconclusive  // Check my key again: the provider times out
    check = try #require(panel.check())
    await check.value
    #expect(panel.phase == .retry)
    panel.later()
    panel.dispose()
    await f.drained()
    #expect(f.presence.savedFlag(for: .openAI) == true, "the passed key was removed")

    // A genuinely different key typed after a pass, never passed itself: removable.
    let g = Fixture()
    g.script.answer = .accept
    let other = g.panel(Events())
    Self.type("first-passes", into: other)
    check = try #require(other.check())
    await check.value
    g.script.answer = .inconclusive
    Self.type("second-differs", into: other)
    check = try #require(other.check())
    await check.value
    other.dispose()
    await g.drained()
    #expect(g.presence.savedFlag(for: .openAI) == false, "an unpassed replacement stayed")
  }

  @Test("a newer key saved elsewhere after the rejection is never removed")
  func newerReplacementSurvives() async throws {
    let f = Fixture()
    let panel = f.panel(Events())
    Self.type("sk-bad", into: panel)
    let check = try #require(panel.check())
    await check.value
    #expect(panel.phase == .rejected)
    // Settings (or the door) stores a different key for the same provider.
    f.script.answer = .accept
    let replaced = await f.writer.save(
      "sk-from-settings", for: .openAI, settings: f.settings, surface: .dictation)
    guard case .stored(let validation, _) = replaced else {
      Issue.record("the replacement was not stored")
      return
    }
    await validation.value
    panel.dispose()
    await f.drained()
    #expect(f.presence.savedFlag(for: .openAI) == true, "Setup removed a newer key")
  }
}
