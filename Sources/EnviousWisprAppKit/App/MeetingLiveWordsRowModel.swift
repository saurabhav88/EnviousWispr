import EnviousWisprCore
import EnviousWisprLivePreview
import EnviousWisprModelDelivery
import EnviousWisprServices
import Foundation
import Observation

/// #4105: the state and commands behind EnviousMeet > General's Live words and transcript
/// language rows (plan §3.5, R1.2-R1.6, R2.4-R2.5, R3.1).
///
/// The bootstrapper owns one instance for the life of the app, so closing Settings mid-download
/// keeps the transfer's owner and reopening shows it still running instead of offering a second
/// one. Nothing here downloads on its own: opening, refreshing and choosing only read; a transfer
/// starts only from `download()`, after `MeetingDownloadAdmission` in the same step.
///
/// One choice owner: `appear()` asks the same `MeetingLiveWordsChoice.Initializer` meeting Start
/// asks, so the first ready guess is saved once, whichever comes first.
@MainActor
@Observable
final class MeetingLiveWordsRowModel {
  struct Environment {
    let choice: MeetingLiveWordsChoice.Initializer
    let settings: SettingsManager
    /// A meeting records or processes (`MeetingCoordinator.isMeetingActive`).
    let isMeetingActive: @MainActor () -> Bool
    /// The meeting-module catalogue: the only Apple installer, holding its locale claim until
    /// `downloadAndInstall` returns.
    let appleCatalog: ApplePackCatalog
    /// The Universal engine's delivery state (`ModelDeliveryHome.whisperPreviewState`); nil when
    /// this build has no Universal delivery.
    let universalState: @MainActor () -> DeliveryState?
    /// `ModelDeliveryHome.startPreviewDownload` / `cancelPreviewDownload`: the existing
    /// transfer, its progress and Cancel, never a second copy. Start answers whether it was
    /// scheduled (false: no delivery in this build, or turned off remotely).
    let startUniversalDownload: @MainActor () -> Bool
    /// The delivery refused the last Download press, now or once its work ran
    /// (`ModelDeliveryHome.previewDownloadRefused`).
    let universalDownloadRefused: @MainActor () -> Bool
    let cancelUniversalDownload: @MainActor () -> Void
  }

  /// What the row says now.
  enum Status: Equatable {
    /// The inventory is being read (never "downloading").
    case loading
    /// No engine and language chosen; `suggestion` is the guess that needs a download.
    case notSetUp(suggestion: MeetingLiveWordsChoice.Suggestion?)
    case ready(engine: LivePreviewEngineChoice, language: String)
    case notDownloaded(engine: LivePreviewEngineChoice, language: String)
    /// `fraction` nil is indeterminate: Apple reports no progress before it finishes.
    case downloading(engine: LivePreviewEngineChoice, language: String, fraction: Double?)
    /// The last download of this choice did not finish; Download again retries.
    case failed(engine: LivePreviewEngineChoice, language: String)
    /// Apple's meeting speech is not available on this Mac (below macOS 26, or no module).
    case appleUnavailable
  }

  enum DownloadOutcome: Equatable {
    case started
    /// A meeting records or processes: nothing started (`MeetingDownloadAdmission.refusal`).
    case refusedDuringMeeting
    /// Another Apple language is still downloading; one at a time.
    case busy
    /// Nothing to download for the current choice.
    case notNeeded
    /// The Universal download could not be scheduled (no delivery in this build, or turned off
    /// remotely); the row says so instead of offering it again.
    case unavailable
  }

  struct LanguageOption: Equatable, Identifiable {
    /// An exact BCP-47 tag (Apple) or a base code (Universal). Never Auto.
    let code: String
    let name: String
    var id: String { code }
  }

  private let environment: Environment

  /// The last inventory read; nil until the first read finishes.
  private(set) var inventory: MeetingLiveWordsChoice.Inventory?
  /// The stored choice and its resolution, read together.
  private(set) var snapshot: MeetingLiveWordsChoice.Initializer.Snapshot?
  /// The Apple tag downloading now. Kept apart from the selection, so choosing another language
  /// during a transfer never relabels it.
  private(set) var appleDownloadingTag: String?
  /// The Apple tag whose last download did not finish.
  private(set) var appleFailedTag: String?
  /// The Apple install in flight, readable so a test can join it.
  private(set) var appleDownloadTask: Task<Void, Never>?

  /// Every refresh publishes only if no newer one started.
  private var refreshGeneration = 0
  /// Every user selection bumps this, so an older engine switch still looking up its language
  /// never overwrites a newer choice.
  private var selectionGeneration = 0

  init(environment: Environment) {
    self.environment = environment
  }

  /// The real meeting-module catalogue. Below macOS 26 it lists nothing and installs nothing
  /// (the row then reads Apple as unavailable from the inventory).
  static func liveMeetingCatalog() -> ApplePackCatalog {
    if #available(macOS 26.0, *) {
      return ApplePackCatalog(dependencies: .live(.meeting), claims: .shared)
    }
    return ApplePackCatalog(
      dependencies: .init(supportedTags: { [] }, installedTags: { [] }, install: { _ in }),
      claims: .shared)
  }

  // MARK: - Reading

  /// The row appears: save the first ready guess through the shared initializer (as Start
  /// would), then read. Never downloads.
  func appear() async {
    _ = await environment.choice.materializeIfUnset()
    await refresh()
  }

  /// Re-reads the inventory and the stored choice. Never downloads.
  func refresh() async {
    refreshGeneration += 1
    let mine = refreshGeneration
    let inventory = await environment.choice.inventory()
    let snapshot = await environment.choice.peek()
    guard mine == refreshGeneration else { return }
    self.inventory = inventory
    self.snapshot = snapshot
    // A failure the system has since resolved (the language is installed) is history.
    if let failed = appleFailedTag, inventory.appleInstalledTags.contains(failed) {
      appleFailedTag = nil
    }
  }

  var status: Status {
    guard let inventory, let snapshot else { return .loading }
    if snapshot.storedEngine == .apple, !inventory.appleAvailable { return .appleUnavailable }
    // The choice the row is about: the stored one, or the suggestion while nothing is stored.
    // Transfers and readiness are read for it the same way in every case (Codex chunk 6 r1).
    let engine: LivePreviewEngineChoice
    let language: String
    let readNow: Status
    switch snapshot.resolution {
    case .ready(let e, let l):
      (engine, language, readNow) = (e, l, .ready(engine: e, language: l))
    case .notDownloaded(let e, let l):
      (engine, language, readNow) = (e, l, .notDownloaded(engine: e, language: l))
    case .notSetUp(let suggestion?):
      (engine, language, readNow) = (
        suggestion.engine, suggestion.language, .notSetUp(suggestion: suggestion)
      )
    case .notSetUp(nil):
      return .notSetUp(suggestion: nil)
    }
    let transfer: Transfer
    switch engine {
    case .apple:
      transfer =
        appleDownloadingTag == language
        ? .active(fraction: nil) : appleFailedTag == language ? .failed : .none
    case .universal:
      // Live from the existing delivery owner: its progress, its arrival before the next
      // inventory read, and a removal after the last one.
      switch environment.universalState() {
      case .preparing, .verifying: transfer = .active(fraction: nil)
      case .downloading(let fraction, _, _): transfer = .active(fraction: fraction)
      case .admitted: transfer = .arrived
      case .failed: transfer = .failed
      case .notReady, .cancelled: transfer = .gone
      case nil: transfer = .none
      }
    }
    return Self.status(read: readNow, engine: engine, language: language, transfer: transfer)
  }

  /// What a download says about the choice, beside what the last read found.
  enum Transfer: Equatable {
    case none
    /// Running now; `fraction` nil is indeterminate.
    case active(fraction: Double?)
    /// The last attempt did not finish.
    case failed
    /// The model arrived since the last read.
    case arrived
    /// The model is not there (never downloaded, cancelled or removed).
    case gone
  }

  /// The one precedence rule (Codex chunk 6 r2): a running transfer first; then what is true
  /// now (an arrival is ready, a removal is not); a past failure only for a choice still
  /// missing, never over one the system now reports installed.
  static func status(
    read: Status, engine: LivePreviewEngineChoice, language: String, transfer: Transfer
  ) -> Status {
    let isReady = if case .ready = read { true } else { false }
    switch transfer {
    case .active(let fraction):
      return .downloading(engine: engine, language: language, fraction: fraction)
    case .arrived:
      return .ready(engine: engine, language: language)
    case .gone:
      return isReady ? .notDownloaded(engine: engine, language: language) : read
    case .failed:
      return isReady ? read : .failed(engine: engine, language: language)
    case .none:
      return read
    }
  }

  /// The stored engine and language (what the pickers show as selected).
  var selectedEngine: LivePreviewEngineChoice? { snapshot?.storedEngine }
  var selectedLanguage: String? { snapshot?.storedLanguage }

  /// Whether Apple can be chosen on this Mac; Universal always can.
  var isAppleAvailable: Bool { inventory?.appleAvailable ?? false }

  /// The chosen engine's languages, never Auto: Apple's exact runtime tags with their localized
  /// names, or Universal's base codes from `LanguageCatalog`.
  func languages(for engine: LivePreviewEngineChoice) -> [LanguageOption] {
    guard let inventory else { return [] }
    let options: [LanguageOption]
    switch engine {
    case .apple:
      guard inventory.appleAvailable else { return [] }
      options = inventory.appleSupportedTags.map {
        LanguageOption(code: $0, name: ApplePackCatalog.localizedName(for: $0))
      }
    case .universal:
      options = inventory.universalCodes.map {
        LanguageOption(code: $0, name: LanguageCatalog.entry(for: $0).displayName)
      }
    }
    return options.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// A language's name as the row shows it: Apple's localized name for its tag, Universal's
  /// catalogue name for its code.
  func languageName(engine: LivePreviewEngineChoice, code: String) -> String {
    switch engine {
    case .apple: ApplePackCatalog.localizedName(for: code)
    case .universal: LanguageCatalog.entry(for: code).displayName
    }
  }

  /// "Available after the meeting." while a meeting records or processes; nil otherwise.
  var downloadRefusal: String? {
    environment.isMeetingActive() ? MeetingDownloadAdmission.refusal : nil
  }

  // MARK: - Choosing

  /// Switches the engine, keeping the language when the new engine has it (the shared policy:
  /// an installed Apple region first, else Apple's equivalent; Universal's base code), else
  /// clearing it. With no language stored yet, the engine is preselected with the dictation
  /// language's match, so the row never shows an engine with an empty language while a guess
  /// would be used, and the pair is the user's choice from then on (Codex chunk 7 r1). A newer
  /// selection made during the lookup wins.
  func selectEngine(_ engine: LivePreviewEngineChoice) async {
    guard engine != .apple || isAppleAvailable else { return }
    selectionGeneration += 1
    let mine = selectionGeneration
    let settings = environment.settings
    let current =
      settings.meetingLiveWordsLanguage ?? MeetingLiveWordsChoice.guessCode(settings.languageMode)
    let inventory = await environment.choice.inventory()
    let kept = await MeetingLiveWordsChoice.switchedLanguage(
      to: engine, from: current, inventory: inventory,
      appleEquivalent: environment.choice.appleEquivalent)
    guard mine == selectionGeneration else { return }
    if let kept {
      settings.commitMeetingLiveWordsChoice(engine: engine, language: kept)
    } else {
      settings.meetingLiveWordsLanguage = nil
      settings.meetingLiveWordsEngine = engine
    }
    await refresh()
  }

  /// Chooses a language for the current engine, exactly as picked (an Apple tag stays exact).
  func selectLanguage(_ code: String) async {
    guard let engine = environment.settings.meetingLiveWordsEngine else { return }
    selectionGeneration += 1
    environment.settings.commitMeetingLiveWordsChoice(engine: engine, language: code)
    await refresh()
  }

  // MARK: - Downloading

  /// Downloads the current choice's model. Refused while a meeting is active: the admission and
  /// the start are one main-actor step, with no suspension between them.
  @discardableResult
  func download() -> DownloadOutcome {
    guard MeetingDownloadAdmission.canStart(meetingActive: environment.isMeetingActive()) else {
      return .refusedDuringMeeting
    }
    switch status {
    case .notDownloaded(.apple, let tag), .failed(.apple, let tag):
      return startAppleDownload(tag)
    case .notDownloaded(.universal, _), .failed(.universal, _):
      return startUniversalDownload()
    case .notSetUp(let suggestion?):
      // Not set up yet: download the guess's model; the choice is saved once it is ready (the
      // Apple task saves it; for Universal, the next appearance or Start does).
      switch suggestion.engine {
      case .apple: return startAppleDownload(suggestion.language)
      case .universal: return startUniversalDownload()
      }
    case .loading, .notSetUp(nil), .ready, .downloading, .appleUnavailable:
      return .notNeeded
    }
  }

  /// Cancels the Universal download (Apple's installer offers no Cancel).
  func cancelDownload() {
    if case .downloading(.universal, _, _) = status { environment.cancelUniversalDownload() }
  }

  private func startUniversalDownload() -> DownloadOutcome {
    environment.startUniversalDownload() ? .started : .unavailable
  }

  /// The delivery refused the last Universal Download press, at once or once its work ran; the
  /// row says so beside its Download, which stays there for a retry.
  var universalDownloadUnavailable: Bool { environment.universalDownloadRefused() }

  private func startAppleDownload(_ tag: String) -> DownloadOutcome {
    guard appleDownloadingTag == nil else { return .busy }
    // Set before the first suspension: the row shows the spinner on the press, and a second
    // press cannot slip in behind it.
    appleDownloadingTag = tag
    appleFailedTag = nil
    // Owned here, not by a view: closing Settings never cancels it, and the catalogue holds the
    // locale claim until `downloadAndInstall` returns. `[weak self]` so the task never keeps the
    // model alive (the bootstrapper does).
    appleDownloadTask = Task { [weak self, catalog = environment.appleCatalog] in
      let landed: Bool
      do {
        landed = try await catalog.install(tag: tag).contains { $0.tag == tag && $0.isInstalled }
      } catch {
        // Apple can install and then throw: the system's list is the authority.
        landed = await catalog.snapshot().contains { $0.tag == tag && $0.isInstalled }
      }
      guard let self else { return }
      await self.refresh()
      // Released only after the refresh settled, so a retry never races this task's results.
      self.appleDownloadingTag = nil
      self.appleFailedTag = landed ? nil : tag
      if landed { _ = await self.environment.choice.materializeIfUnset() }
      await self.refresh()
    }
    return .started
  }

  // MARK: - Transcript language

  /// The final transcript's language (`meetingLanguageMode`), Auto included. A change applies to
  /// the next meeting: a recorded meeting keeps the language it started with.
  var transcriptLanguage: LanguageMode {
    get { environment.settings.meetingLanguageMode }
    set { environment.settings.meetingLanguageMode = newValue }
  }

  /// The final engine's lockable languages (Parakeet, `LanguageLockOptions`); Auto is offered
  /// by the picker beside these. No English (UK): it is dictation's British spelling choice, not
  /// a language, and a meeting stores only the language.
  var transcriptLanguageOptions: [LanguageCatalog.Entry] {
    LanguageLockOptions.pickerRows(
      lockableCodes: LanguageLockOptions.lockableCodes(for: .parakeet), query: "",
      offersEnglishUK: false)
  }

  /// The note under both pickers: shown when the transcript language is locked to a different
  /// language than live words. It never blocks either choice.
  var languagesDiffer: Bool {
    MeetingLiveWordsChoice.languagesDiffer(
      liveWords: selectedLanguage, transcript: transcriptLanguage)
  }
}
