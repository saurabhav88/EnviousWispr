import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprLivePreview
import EnviousWisprModelDelivery
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// #4105: the state and commands behind the Live words row.
///
/// **What the user sees when this fails:** opening Settings downloads something, Download starts
/// a transfer while a meeting records, a second download of the same language starts after
/// closing and reopening Settings, the row calls a language "Downloading" when it only reads the
/// list, switching engines loses or invents a language, an older lookup overwrites the user's
/// newer pick, or a finished download is shown under another language.
@MainActor
@Suite("Meeting live words row (#4105)", .tags(.productOutcome))
struct MeetingLiveWordsRowModelTests {
  typealias Choice = MeetingLiveWordsChoice
  typealias Status = MeetingLiveWordsRowModel.Status

  /// This Mac: Apple's meeting module and the Universal engine, shared by the inventory the
  /// choice reads and the catalogue that installs, as on a real Mac.
  final class FakeMac: @unchecked Sendable {
    let lock = NSLock()
    var appleAvailable = true
    var supported = ["de-DE", "en-GB", "en-US", "fr-FR"]
    var installed = ["en-US"]
    var universalInstalled = false
    var installCalls: [String] = []
    var installFails = false
    /// Held: an Apple install waits here until opened.
    var installGate: BoundedWait.Signal?
    let installEntered = BoundedWait.Signal()
    /// Held: the inventory read waits here until opened (for stale-lookup tests).
    var inventoryGate: BoundedWait.Signal?
    let inventoryEntered = BoundedWait.Signal()

    func inventory() async -> Choice.Inventory {
      let gate = lock.withLock { inventoryGate }
      if let gate {
        inventoryEntered.fire()
        try? await BoundedWait.until(gate)
      }
      return lock.withLock {
        Choice.Inventory(
          appleAvailable: appleAvailable, appleSupportedTags: supported,
          appleInstalledTags: installed, universalInstalled: universalInstalled,
          universalCodes: ["de", "en", "fr", "ja"])
      }
    }

    func install(_ tag: String) async throws {
      let gate = lock.withLock { () -> BoundedWait.Signal? in
        installCalls.append(tag)
        return installGate
      }
      installEntered.fire()
      if let gate { try? await BoundedWait.until(gate) }
      let fails = lock.withLock { installFails }
      if fails { throw CocoaError(.featureUnsupported) }
      lock.withLock { if !installed.contains(tag) { installed.append(tag) } }
    }
  }

  final class FakeUniversal {
    var state: DeliveryState? = .notReady
    /// What `startPreviewDownload` answers: false when it refuses (no delivery, kill switch).
    var scheduled = true
    var starts = 0
    var cancels = 0
  }

  private actor TagBox {
    private var tags: [String] = []
    func locales() -> [Locale] { tags.map { Locale(identifier: $0) } }
    func add(_ tag: String) -> Bool {
      if tags.contains(tag) { return false }
      tags.append(tag)
      return true
    }
    func remove(_ tag: String) -> Bool {
      guard let i = tags.firstIndex(of: tag) else { return false }
      tags.remove(at: i)
      return true
    }
  }

  private static func claims() -> LocaleClaims {
    let box = TagBox()
    return LocaleClaims(
      inventory: LocaleInventory(
        reserved: { await box.locales() },
        reserve: { await box.add($0.identifier(.bcp47)) },
        release: { await box.remove($0.identifier(.bcp47)) },
        maximumReserved: { 5 }))
  }

  struct Rig {
    let mac = FakeMac()
    let universal = FakeUniversal()
    let settings: SettingsManager
    let choice: Choice.Initializer
    let model: MeetingLiveWordsRowModel

    @MainActor
    init(
      dictation: LanguageMode = .locked("en"),
      meetingActive: @escaping @MainActor () -> Bool = { false }
    ) {
      settings = MeetingLiveWordsChoiceInitializerTests.freshSettings()
      settings.languageMode = dictation
      let mac = self.mac
      let universal = self.universal
      choice = Choice.Initializer(
        environment: .init(
          settings: settings, inventory: { await mac.inventory() },
          appleEquivalent: { code in
            ["de": "de-DE", "en": "en-US", "fr": "fr-FR"][Choice.baseCode(code)]
          }))
      let catalog = ApplePackCatalog(
        dependencies: .init(
          supportedTags: { mac.lock.withLock { mac.supported } },
          installedTags: { mac.lock.withLock { mac.installed } },
          install: { try await mac.install($0) }),
        claims: MeetingLiveWordsRowModelTests.claims())
      model = MeetingLiveWordsRowModel(
        environment: .init(
          choice: choice, settings: settings, isMeetingActive: meetingActive,
          appleCatalog: catalog, universalState: { universal.state },
          startUniversalDownload: {
            universal.starts += 1
            return universal.scheduled
          },
          cancelUniversalDownload: { universal.cancels += 1 }))
    }
  }

  /// A meeting activity flag the rig's closure reads live.
  final class Activity { var active = false }

  // MARK: - Reading

  @Test(
    "opening the row saves the first ready guess through the shared owner and downloads nothing")
  func appearMaterializesWithoutDownloading() async throws {
    let rig = Rig()
    #expect(rig.model.status == .loading, "nothing read yet: loading, never downloading")
    await rig.model.appear()
    #expect(rig.settings.meetingLiveWordsEngine == .apple)
    #expect(rig.settings.meetingLiveWordsLanguage == "en-US")
    #expect(rig.model.status == .ready(engine: .apple, language: "en-US"))
    // The same owner Start asks: a Start now returns the saved choice, with no second save.
    #expect(await rig.choice.materializeIfUnset() == .ready(engine: .apple, language: "en-US"))
    await rig.model.refresh()
    #expect(rig.mac.installCalls.isEmpty)
    #expect(rig.universal.starts == 0)
  }

  @Test(
    "a guess that needs a download is suggested, not saved, and Apple unavailability is its own state"
  )
  func notSetUpAndUnavailable() async throws {
    let german = Rig(dictation: .locked("de"))
    await german.model.appear()
    #expect(german.model.status == .notSetUp(suggestion: .init(engine: .apple, language: "de-DE")))
    #expect(german.settings.meetingLiveWordsEngine == nil)

    let old = Rig()
    old.mac.appleAvailable = false
    old.settings.commitMeetingLiveWordsChoice(engine: .apple, language: "en-US")
    await old.model.refresh()
    #expect(old.model.status == .appleUnavailable)
    #expect(old.model.isAppleAvailable == false)
    #expect(old.model.languages(for: .apple).isEmpty)
  }

  @Test("Apple lists exact runtime tags by name, Universal base codes; neither offers Auto")
  func languageLists() async throws {
    let rig = Rig()
    await rig.model.refresh()
    let apple = rig.model.languages(for: .apple).map(\.code)
    #expect(Set(apple) == ["de-DE", "en-GB", "en-US", "fr-FR"])
    #expect(
      rig.model.languages(for: .apple).allSatisfy {
        $0.name == ApplePackCatalog.localizedName(for: $0.code)
      })
    #expect(Set(rig.model.languages(for: .universal).map(\.code)) == ["de", "en", "fr", "ja"])
    for engine in [LivePreviewEngineChoice.apple, .universal] {
      #expect(!rig.model.languages(for: engine).contains { $0.code.lowercased() == "auto" })
    }
  }

  @Test("the Universal row follows the existing delivery state, progress included")
  func universalStatusFollowsDelivery() async throws {
    let rig = Rig()
    rig.settings.commitMeetingLiveWordsChoice(engine: .universal, language: "de")
    await rig.model.refresh()
    #expect(rig.model.status == .notDownloaded(engine: .universal, language: "de"))
    rig.universal.state = .preparing(validatingExistingCache: false)
    #expect(rig.model.status == .downloading(engine: .universal, language: "de", fraction: nil))
    rig.universal.state = .downloading(fractionCompleted: 0.4, bytesWritten: 4, totalBytes: 10)
    #expect(rig.model.status == .downloading(engine: .universal, language: "de", fraction: 0.4))
    rig.universal.state = .failed(DeliveryFailure(reason: .sourceUnreachable, detail: nil))
    #expect(rig.model.status == .failed(engine: .universal, language: "de"))
    rig.universal.state = .admitted
    #expect(rig.model.status == .ready(engine: .universal, language: "de"))
  }

  // MARK: - Choosing

  @Test("switching engines keeps a language the new engine has and clears one it does not")
  func engineSwitchKeepsOrClears() async throws {
    let rig = Rig()
    rig.settings.commitMeetingLiveWordsChoice(engine: .apple, language: "de-DE")
    await rig.model.selectEngine(.universal)
    #expect(rig.settings.meetingLiveWordsEngine == .universal)
    #expect(rig.settings.meetingLiveWordsLanguage == "de")
    await rig.model.selectEngine(.apple)
    #expect(rig.settings.meetingLiveWordsLanguage == "de-DE", "back to Apple's German")

    rig.settings.commitMeetingLiveWordsChoice(engine: .universal, language: "ja")
    await rig.model.selectEngine(.apple)
    #expect(rig.settings.meetingLiveWordsEngine == .apple)
    #expect(rig.settings.meetingLiveWordsLanguage == nil, "Apple has no Japanese here")

    await rig.model.selectLanguage("en-GB")
    #expect(rig.settings.meetingLiveWordsLanguage == "en-GB", "an exact Apple pick stays exact")
  }

  @Test("choosing an engine on a row not set up saves it with the preselected language, kept after dictation changes")
  func engineFromUnsetPreselectsLanguage() async throws {
    let rig = Rig(dictation: .locked("de"))
    await rig.model.appear()
    #expect(rig.model.status == .notSetUp(suggestion: .init(engine: .apple, language: "de-DE")))
    await rig.model.selectEngine(.universal)
    #expect(rig.settings.meetingLiveWordsEngine == .universal)
    #expect(rig.settings.meetingLiveWordsLanguage == "de", "the language menu shows German")
    #expect(rig.model.status == .notDownloaded(engine: .universal, language: "de"))
    #expect(rig.model.download() == .started)
    rig.settings.languageMode = .locked("fr")
    await rig.model.refresh()
    #expect(rig.settings.meetingLiveWordsLanguage == "de", "dictation's language no longer steers it")
    #expect(rig.model.selectedLanguage == "de")
  }

  @Test("an engine switch still looking up its language never overwrites a newer pick")
  func staleEngineSwitchLoses() async throws {
    let rig = Rig()
    rig.settings.commitMeetingLiveWordsChoice(engine: .apple, language: "de-DE")
    let gate = BoundedWait.Signal()
    rig.mac.lock.withLock { rig.mac.inventoryGate = gate }
    let model = rig.model
    let switching = Task { await model.selectEngine(.universal) }
    try await BoundedWait.until(rig.mac.inventoryEntered)
    rig.mac.lock.withLock { rig.mac.inventoryGate = nil }
    await rig.model.selectLanguage("fr-FR")
    gate.fire()
    _ = try await BoundedWait.result(of: switching).get()
    #expect(rig.settings.meetingLiveWordsEngine == .apple)
    #expect(rig.settings.meetingLiveWordsLanguage == "fr-FR")
  }

  // MARK: - Downloading

  @Test("Download during a meeting starts nothing and says why")
  func downloadRefusedDuringMeeting() async throws {
    let activity = Activity()
    activity.active = true
    let rig = Rig(dictation: .locked("de"), meetingActive: { activity.active })
    await rig.model.appear()
    #expect(rig.model.downloadRefusal == "Available after the meeting.")
    #expect(rig.model.download() == .refusedDuringMeeting)
    rig.settings.commitMeetingLiveWordsChoice(engine: .universal, language: "de")
    await rig.model.refresh()
    #expect(rig.model.download() == .refusedDuringMeeting)
    #expect(rig.mac.installCalls.isEmpty)
    #expect(rig.universal.starts == 0)
    activity.active = false
    #expect(rig.model.downloadRefusal == nil)
    #expect(rig.model.download() == .started)
    #expect(rig.universal.starts == 1)
  }

  @Test(
    "an Apple download is one transfer with no percentage, kept across reopening and a meeting Start"
  )
  func appleDownloadIsOwnedAndIndeterminate() async throws {
    let activity = Activity()
    let rig = Rig(dictation: .locked("de"), meetingActive: { activity.active })
    rig.settings.commitMeetingLiveWordsChoice(engine: .apple, language: "de-DE")
    await rig.model.appear()
    let gate = BoundedWait.Signal()
    rig.mac.lock.withLock { rig.mac.installGate = gate }
    #expect(rig.model.download() == .started)
    #expect(rig.model.status == .downloading(engine: .apple, language: "de-DE", fraction: nil))
    try await BoundedWait.until(rig.mac.installEntered)

    // Settings closed and reopened, a second press, and a meeting starting: still one transfer.
    await rig.model.appear()
    #expect(rig.model.status == .downloading(engine: .apple, language: "de-DE", fraction: nil))
    #expect(rig.model.download() == .notNeeded, "already downloading")
    // Choosing another language mid-transfer never relabels the transfer, and its Download
    // waits for the first one.
    await rig.model.selectLanguage("fr-FR")
    #expect(rig.model.status == .notDownloaded(engine: .apple, language: "fr-FR"))
    #expect(rig.model.appleDownloadingTag == "de-DE")
    #expect(rig.model.download() == .busy)
    await rig.model.selectLanguage("de-DE")
    // A meeting starting now does not stop the transfer it did not start.
    activity.active = true

    gate.fire()
    let task = try #require(rig.model.appleDownloadTask)
    _ = try await BoundedWait.result(of: task).get()
    #expect(rig.mac.installCalls == ["de-DE"], "one install")
    #expect(rig.model.status == .ready(engine: .apple, language: "de-DE"))
    #expect(rig.model.appleDownloadingTag == nil)
  }

  @Test("a failed Apple download offers a retry once the system's list says it is still missing")
  func appleFailureThenRetry() async throws {
    let rig = Rig()
    rig.settings.commitMeetingLiveWordsChoice(engine: .apple, language: "de-DE")
    await rig.model.refresh()
    rig.mac.lock.withLock { rig.mac.installFails = true }
    #expect(rig.model.download() == .started)
    _ = try await BoundedWait.result(of: try #require(rig.model.appleDownloadTask)).get()
    #expect(rig.model.status == .failed(engine: .apple, language: "de-DE"))
    rig.mac.lock.withLock { rig.mac.installFails = false }
    #expect(rig.model.download() == .started)
    _ = try await BoundedWait.result(of: try #require(rig.model.appleDownloadTask)).get()
    #expect(rig.model.status == .ready(engine: .apple, language: "de-DE"))
  }

  /// Every read state against every transfer state (Codex chunk 6 r2: precedence defects in two
  /// rounds), with each outcome written out.
  @Test("status precedence: a running transfer, then what is true now, then a past failure")
  func statusPrecedenceTable() {
    typealias T = MeetingLiveWordsRowModel.Transfer
    let suggestion = Choice.Suggestion(engine: .apple, language: "de-DE")
    let ready = Status.ready(engine: .apple, language: "de-DE")
    let missing = Status.notDownloaded(engine: .apple, language: "de-DE")
    let suggested = Status.notSetUp(suggestion: suggestion)
    let spinning = Status.downloading(engine: .apple, language: "de-DE", fraction: nil)
    let partway = Status.downloading(engine: .apple, language: "de-DE", fraction: 0.3)
    let failed = Status.failed(engine: .apple, language: "de-DE")
    let table: [(Status, T, Status)] = [
      (ready, .none, ready), (missing, .none, missing), (suggested, .none, suggested),
      (ready, .active(fraction: nil), spinning), (missing, .active(fraction: nil), spinning),
      (suggested, .active(fraction: 0.3), partway),
      (ready, .arrived, ready), (missing, .arrived, ready), (suggested, .arrived, ready),
      (ready, .gone, missing), (missing, .gone, missing), (suggested, .gone, suggested),
      (ready, .failed, ready), (missing, .failed, failed), (suggested, .failed, failed),
    ]
    #expect(table.count == 3 * 5, "every read state against every transfer state")
    for (read, transfer, expected) in table {
      let got = MeetingLiveWordsRowModel.status(
        read: read, engine: .apple, language: "de-DE", transfer: transfer)
      #expect(got == expected, "\(read) + \(transfer)")
    }
  }

  @Test("a failure the system later resolves reads ready after a refresh, with no second install")
  func resolvedFailureReadsReady() async throws {
    let rig = Rig()
    rig.settings.commitMeetingLiveWordsChoice(engine: .apple, language: "de-DE")
    await rig.model.refresh()
    rig.mac.lock.withLock { rig.mac.installFails = true }
    #expect(rig.model.download() == .started)
    _ = try await BoundedWait.result(of: try #require(rig.model.appleDownloadTask)).get()
    #expect(rig.model.status == .failed(engine: .apple, language: "de-DE"))
    // macOS finishes the language later (another app, or a retry by the system).
    rig.mac.lock.withLock { rig.mac.installed.append("de-DE") }
    await rig.model.refresh()
    #expect(rig.model.status == .ready(engine: .apple, language: "de-DE"))
    #expect(rig.model.appleFailedTag == nil)
    #expect(rig.model.download() == .notNeeded)
    #expect(rig.mac.installCalls == ["de-DE"], "one install")
  }

  @Test("a suggested Apple download shows its spinner and failure, and is saved once it is ready")
  func suggestedAppleDownload() async throws {
    let rig = Rig(dictation: .locked("de"))
    await rig.model.appear()
    let gate = BoundedWait.Signal()
    rig.mac.lock.withLock {
      rig.mac.installGate = gate
      rig.mac.installFails = true
    }
    #expect(rig.model.download() == .started)
    #expect(rig.model.status == .downloading(engine: .apple, language: "de-DE", fraction: nil))
    #expect(rig.model.download() == .notNeeded, "a second press starts nothing")
    gate.fire()
    _ = try await BoundedWait.result(of: try #require(rig.model.appleDownloadTask)).get()
    #expect(rig.model.status == .failed(engine: .apple, language: "de-DE"))
    #expect(rig.settings.meetingLiveWordsEngine == nil, "an unready guess is never saved")
    rig.mac.lock.withLock {
      rig.mac.installGate = nil
      rig.mac.installFails = false
    }
    #expect(rig.model.download() == .started, "retry")
    _ = try await BoundedWait.result(of: try #require(rig.model.appleDownloadTask)).get()
    #expect(rig.settings.meetingLiveWordsEngine == .apple)
    #expect(rig.settings.meetingLiveWordsLanguage == "de-DE")
    #expect(rig.model.status == .ready(engine: .apple, language: "de-DE"))
  }

  @Test("a suggested Universal download shows progress, can be cancelled, and reads ready on arrival")
  func suggestedUniversalDownload() async throws {
    let rig = Rig(dictation: .locked("ja"))
    await rig.model.appear()
    #expect(rig.model.status == .notSetUp(suggestion: .init(engine: .universal, language: "ja")))
    #expect(rig.model.download() == .started)
    #expect(rig.universal.starts == 1)
    rig.universal.state = .downloading(fractionCompleted: 0.5, bytesWritten: 5, totalBytes: 10)
    #expect(rig.model.status == .downloading(engine: .universal, language: "ja", fraction: 0.5))
    #expect(rig.model.download() == .notNeeded)
    rig.model.cancelDownload()
    #expect(rig.universal.cancels == 1)
    rig.universal.state = .cancelled(resumable: true)
    #expect(rig.model.status == .notSetUp(suggestion: .init(engine: .universal, language: "ja")))
    rig.universal.state = .failed(DeliveryFailure(reason: .sourceUnreachable, detail: nil))
    #expect(rig.model.status == .failed(engine: .universal, language: "ja"))
    #expect(rig.model.download() == .started, "retry")
    rig.universal.state = .admitted
    #expect(rig.model.status == .ready(engine: .universal, language: "ja"))
    #expect(rig.settings.meetingLiveWordsEngine == nil, "saved by the next appearance or Start")
    rig.mac.universalInstalled = true
    await rig.model.appear()
    #expect(rig.settings.meetingLiveWordsEngine == .universal)
    #expect(rig.settings.meetingLiveWordsLanguage == "ja")
  }

  @Test("a ready Universal choice reads not downloaded once the engine is removed")
  func removedUniversalIsNotReady() async throws {
    let rig = Rig()
    rig.mac.universalInstalled = true
    rig.universal.state = .admitted
    rig.settings.commitMeetingLiveWordsChoice(engine: .universal, language: "de")
    await rig.model.refresh()
    #expect(rig.model.status == .ready(engine: .universal, language: "de"))
    rig.universal.state = .notReady
    #expect(rig.model.status == .notDownloaded(engine: .universal, language: "de"))
    #expect(rig.model.download() == .started)
  }

  @Test("a Universal Download the delivery refuses says so, and a later accepted one clears it")
  func refusedUniversalDownloadIsReported() async throws {
    let rig = Rig()
    rig.settings.commitMeetingLiveWordsChoice(engine: .universal, language: "de")
    await rig.model.refresh()
    rig.universal.scheduled = false
    #expect(rig.model.download() == .unavailable)
    #expect(rig.model.universalDownloadUnavailable)
    #expect(rig.model.status == .notDownloaded(engine: .universal, language: "de"))
    rig.universal.scheduled = true
    #expect(rig.model.download() == .started)
    #expect(rig.model.universalDownloadUnavailable == false)
  }

  @Test("Universal Download and Cancel go to the existing delivery commands")
  func universalCommands() async throws {
    let rig = Rig()
    rig.settings.commitMeetingLiveWordsChoice(engine: .universal, language: "de")
    await rig.model.refresh()
    rig.model.cancelDownload()
    #expect(rig.universal.cancels == 0, "nothing to cancel")
    #expect(rig.model.download() == .started)
    #expect(rig.universal.starts == 1)
    rig.universal.state = .downloading(fractionCompleted: 0.1, bytesWritten: 1, totalBytes: 10)
    #expect(rig.model.download() == .notNeeded, "already downloading")
    rig.model.cancelDownload()
    #expect(rig.universal.cancels == 1)
    #expect(rig.mac.installCalls.isEmpty)
  }

  // MARK: - The engine menu

  /// SwiftUI fills its accessibility tree lazily, only under a real accessibility client, so a
  /// hosted menu's items are not readable in a test (measured in RenderedPillHarness, 2026-08-25).
  /// The menu draws exactly `engineItems`, so this checks what it draws; the greyed item on
  /// screen is a Live UAT row.
  @Test("Apple is listed but greyed where this Mac cannot run it, and choosing it changes nothing")
  func unavailableAppleIsDisabled() async throws {
    #expect(
      MeetingLiveWordsRow.engineItems(appleAvailable: false) == [
        .init(
          choice: .apple, label: String(localized: MeetingsCopy.appleNotOnThisMac),
          isEnabled: false),
        .init(choice: .universal, label: LivePreviewEngineCopy.universalTitle, isEnabled: true),
      ])
    #expect(MeetingLiveWordsRow.engineItems(appleAvailable: true).allSatisfy { $0.isEnabled })
    let rig = Rig()
    rig.mac.appleAvailable = false
    rig.settings.commitMeetingLiveWordsChoice(engine: .universal, language: "de")
    await rig.model.refresh()
    await rig.model.selectEngine(.apple)
    #expect(rig.settings.meetingLiveWordsEngine == .universal, "an unavailable Apple is refused")
    #expect(rig.settings.meetingLiveWordsLanguage == "de")
  }

  // MARK: - Transcript language

  @Test(
    "the transcript picker offers the final engine's languages, and its note never changes live words"
  )
  func transcriptLanguage() async throws {
    let rig = Rig()
    rig.settings.commitMeetingLiveWordsChoice(engine: .apple, language: "en-US")
    await rig.model.refresh()
    let options = rig.model.transcriptLanguageOptions
    let expected = LanguageCatalog.pickerEntries.filter {
      ParakeetBackend.lockableLanguageCodes.contains($0.lockCode) && $0 != LanguageCatalog.englishUK
    }
    #expect(options == expected, "the final engine's languages, one row each")
    #expect(!options.contains(LanguageCatalog.englishUK), "British spelling is dictation's choice")
    #expect(options.contains { $0.code == "de" } && options.contains { $0.code == "en" })
    #expect(rig.model.transcriptLanguage == .auto)
    #expect(rig.model.languagesDiffer == false, "Auto never shows the note")
    rig.model.transcriptLanguage = .locked("de")
    #expect(rig.model.languagesDiffer)
    #expect(rig.settings.meetingLiveWordsLanguage == "en-US", "live words unchanged")
    rig.model.transcriptLanguage = .locked("en")
    #expect(rig.model.languagesDiffer == false, "en-US and en are the same language")
  }
}

/// A row model for rendering Settings in tests: a fixed inventory, no installer, no transfer.
extension MeetingLiveWordsRowModel {
  @MainActor
  static func renderFixture(settings: SettingsManager, appleAvailable: Bool = true)
    -> MeetingLiveWordsRowModel
  {
    let inventory = MeetingLiveWordsChoice.Inventory(
      appleAvailable: appleAvailable, appleSupportedTags: appleAvailable ? ["de-DE", "en-US"] : [],
      appleInstalledTags: appleAvailable ? ["en-US"] : [], universalInstalled: false,
      universalCodes: ["de", "en"])
    let choice = MeetingLiveWordsChoice.Initializer(
      environment: .init(
        settings: settings, inventory: { inventory },
        appleEquivalent: { ["de": "de-DE", "en": "en-US"][MeetingLiveWordsChoice.baseCode($0)] }))
    return MeetingLiveWordsRowModel(
      environment: .init(
        choice: choice, settings: settings, isMeetingActive: { false },
        appleCatalog: ApplePackCatalog(
          dependencies: .init(supportedTags: { [] }, installedTags: { [] }, install: { _ in }),
          claims: LocaleClaims(
            inventory: LocaleInventory(
              reserved: { [] }, reserve: { _ in false }, release: { _ in false },
              maximumReserved: { 0 }))),
        universalState: { nil }, startUniversalDownload: { true }, cancelUniversalDownload: {}))
  }
}
