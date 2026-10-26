import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// #4105 (plan R3): the first ready guess is saved once, by one owner.
///
/// **What the user sees when this fails:** opening Settings during a meeting start saves the
/// guess twice or saves a half choice, a language the user just picked is overwritten by an older
/// guess, a guess that needs a download is saved as if chosen, or changing dictation's language
/// later changes the meeting's.
@MainActor
@Suite("Meeting live words first guess (#4105)", .tags(.productOutcome))
struct MeetingLiveWordsChoiceInitializerTests {
  typealias Choice = MeetingLiveWordsChoice

  static func freshSettings() -> SettingsManager {
    let name = "ew.meeting.livewords.init.\(UUID().uuidString)"
    let defaults = TestDefaults.suite(name)!
    defaults.removePersistentDomain(forName: name)
    let settings = SettingsManager(defaults: defaults)
    settings.languageMode = .locked("en")
    return settings
  }

  static let ready = Choice.Inventory(
    appleAvailable: true, appleSupportedTags: ["en-US", "de-DE"], appleInstalledTags: ["en-US"],
    universalInstalled: false, universalCodes: ["en", "de"])

  /// An inventory read that waits for the test to open a gate, counting reads.
  final class GatedInventory: @unchecked Sendable {
    let lock = NSLock()
    var reads = 0
    let entered = BoundedWait.Signal()
    let open = BoundedWait.Signal()
    let inventory: Choice.Inventory
    init(_ inventory: Choice.Inventory) { self.inventory = inventory }
    func read() async -> Choice.Inventory {
      lock.withLock { reads += 1 }
      entered.fire()
      try? await BoundedWait.until(open)
      return inventory
    }
  }

  static func initializer(_ settings: SettingsManager, _ gated: GatedInventory)
    -> Choice.Initializer
  {
    Choice.Initializer(
      environment: .init(
        settings: settings, inventory: { await gated.read() },
        appleEquivalent: { ["en": "en-US", "de": "de-DE"][Choice.baseCode($0)] }))
  }

  @Test("Settings and meeting Start at the same time make one lookup and one save")
  func overlappingCallersShareOneLookup() async throws {
    let settings = Self.freshSettings()
    var notified: [SettingsManager.SettingKey] = []
    var sawHalf = false
    settings.onChange = { key in
      notified.append(key)
      if (settings.meetingLiveWordsEngine == nil) != (settings.meetingLiveWordsLanguage == nil) {
        sawHalf = true
      }
    }
    let gated = GatedInventory(Self.ready)
    let subject = Self.initializer(settings, gated)

    let row = Task { await subject.materializeIfUnset() }
    try await BoundedWait.until(gated.entered)
    let start = Task { await subject.materializeIfUnset() }
    gated.open.fire()
    let a = try await BoundedWait.result(of: row).get()
    let b = try await BoundedWait.result(of: start).get()

    #expect(a == .ready(engine: .apple, language: "en-US"))
    #expect(b == a)
    #expect(gated.lock.withLock { gated.reads } == 1)
    #expect(settings.meetingLiveWordsEngine == .apple)
    #expect(settings.meetingLiveWordsLanguage == "en-US")
    #expect(notified == [.meetingLiveWordsEngine, .meetingLiveWordsLanguage])
    #expect(!sawHalf, "no observer saw only one of the two keys")
  }

  @Test("A choice the user makes during the lookup wins over the guess")
  func userEditDuringLookupWins() async throws {
    let settings = Self.freshSettings()
    let gated = GatedInventory(Self.ready)
    let subject = Self.initializer(settings, gated)
    let task = Task { await subject.materializeIfUnset() }
    try await BoundedWait.until(gated.entered)
    settings.meetingLiveWordsEngine = .universal
    settings.meetingLiveWordsLanguage = "de"
    gated.open.fire()
    let result = try await BoundedWait.result(of: task).get()
    #expect(settings.meetingLiveWordsEngine == .universal)
    #expect(settings.meetingLiveWordsLanguage == "de")
    #expect(result == .notDownloaded(engine: .universal, language: "de"))
  }

  @Test("A write cleared back to unset during the lookup still stops the stale guess")
  func clearedWriteInvalidates() async throws {
    let settings = Self.freshSettings()
    let gated = GatedInventory(Self.ready)
    let subject = Self.initializer(settings, gated)
    let task = Task { await subject.materializeIfUnset() }
    try await BoundedWait.until(gated.entered)
    settings.meetingLiveWordsEngine = .universal
    settings.meetingLiveWordsEngine = nil
    gated.open.fire()
    _ = try await BoundedWait.result(of: task).get()
    #expect(settings.meetingLiveWordsEngine == nil)
    #expect(settings.meetingLiveWordsLanguage == nil)
  }

  @Test("A guess that needs a download is not saved")
  func notReadyGuessSavesNothing() async throws {
    let settings = Self.freshSettings()
    settings.languageMode = .locked("de")
    let gated = GatedInventory(Self.ready)
    gated.open.fire()
    let result = await Self.initializer(settings, gated).materializeIfUnset()
    #expect(result == .notSetUp(suggestion: .init(engine: .apple, language: "de-DE")))
    #expect(settings.meetingLiveWordsEngine == nil)
    #expect(settings.meetingLiveWordsLanguage == nil)
  }

  @Test("Once saved, dictation's language no longer changes the meeting's")
  func savedGuessIsNotRedone() async throws {
    let settings = Self.freshSettings()
    let gated = GatedInventory(Self.ready)
    gated.open.fire()
    let subject = Self.initializer(settings, gated)
    _ = await subject.materializeIfUnset()
    settings.languageMode = .locked("de")
    // Reopening Settings and starting another meeting both call it again.
    #expect(await subject.materializeIfUnset() == .ready(engine: .apple, language: "en-US"))
    #expect(
      await Self.initializer(settings, gated).materializeIfUnset()
        == .ready(engine: .apple, language: "en-US"))
    #expect(settings.meetingLiveWordsLanguage == "en-US")
  }

  /// Each Apple equivalence lookup waits for its own gate, so a test can change settings while a
  /// specific lookup is suspended.
  final class GatedEquivalent: @unchecked Sendable {
    let lock = NSLock()
    var calls = 0
    let entered = [BoundedWait.Signal(), BoundedWait.Signal(), BoundedWait.Signal()]
    let open = [BoundedWait.Signal(), BoundedWait.Signal(), BoundedWait.Signal()]
    func lookup(_ code: String) async -> String? {
      let index = lock.withLock { () -> Int in
        defer { calls += 1 }
        return min(calls, entered.count - 1)
      }
      entered[index].fire()
      try? await BoundedWait.until(open[index])
      return ["en": "en-US", "de": "de-DE"][Choice.baseCode(code)]
    }
  }

  @Test("A change during the re-check after a change is still the one returned")
  func everyResolutionIsRevalidated() async throws {
    let settings = Self.freshSettings()
    let gated = GatedEquivalent()
    for gate in gated.open.dropFirst(2) { gate.fire() }
    let subject = Choice.Initializer(
      environment: .init(
        settings: settings, inventory: { Self.ready },
        appleEquivalent: { await gated.lookup($0) }))

    let task = Task { await subject.materializeIfUnset() }
    // 1. The guess lookup is suspended; the user picks Apple, no language yet.
    try await BoundedWait.until(gated.entered[0])
    settings.meetingLiveWordsEngine = .apple
    gated.open[0].fire()
    // 2. The re-check for Apple is suspended; the user switches to Universal German.
    try await BoundedWait.until(gated.entered[1])
    settings.meetingLiveWordsEngine = .universal
    settings.meetingLiveWordsLanguage = "de"
    gated.open[1].fire()

    let result = try await BoundedWait.result(of: task).get()
    #expect(result == .notDownloaded(engine: .universal, language: "de"))
    #expect(settings.meetingLiveWordsEngine == .universal)
    #expect(settings.meetingLiveWordsLanguage == "de")
  }
}
