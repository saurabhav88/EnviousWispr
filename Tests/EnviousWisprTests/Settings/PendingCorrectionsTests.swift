import AppKit
import EnviousWisprContacts
import EnviousWisprCore
import EnviousWisprPostProcessing
import EnviousWisprStorage
import Foundation
import Observation
import SwiftUI
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

// MARK: - Fixture

@MainActor
private struct PendingFixture {
  typealias C = CorrectionProposalCoordinator
  let store: CorrectionProposalStore
  let faults: LedgerFaults
  let library = WordLibraryFake()
  let telemetry = LearnTelemetrySpy()
  let coordinator: C
  let settings: SettingsManager
  let saira = CustomWord(canonical: "Saira")
  /// A fixed clock: rows are "newest first" by `createdAt`, so each mint
  /// advances it.
  var clock = Date(timeIntervalSince1970: 1_700_000_000)
  private let tick: Ticker

  private final class Ticker {
    var now: Date
    init(_ now: Date) { self.now = now }
  }

  init() {
    (store, faults, _) = makeFaultableStore()
    library.userWords = [saira]
    let ticker = Ticker(clock)
    tick = ticker
    coordinator = C(
      store: store, vocabulary: library.access, presenter: nil, telemetry: telemetry,
      now: { ticker.now })
    coordinator.initialize()
    let name = "ew.pending.settings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    settings = SettingsManager(defaults: defaults)
  }

  @discardableResult
  func mint(_ original: String, _ corrected: String, app: String? = "com.tinyspeck.slackmacgap") -> UUID {
    tick.now = tick.now.addingTimeInterval(60)
    let state: CorrectionProposalTargetState =
      library.userWords.first { $0.canonical == corrected }.map { .existingWord($0.id) } ?? .newWord
    guard
      case .minted(let id) = coordinator.propose(
        original: original, corrected: corrected, state: state, language: "en",
        contextExcerpt: nil, sourceBundleID: app, advisorySafeAlias: nil)
    else {
      Issue.record("expected minted")
      return UUID()
    }
    return id
  }

  var now: Date { tick.now }

  func content(sourceAppName: @escaping (String) -> String? = { _ in nil }) -> PendingCorrectionsPresentation.Content {
    PendingCorrectionsView.presentation(
      coordinator: coordinator, settings: settings, sourceAppName: sourceAppName, now: now)
  }
}

// MARK: - Tabs

@Suite("Dictionary tabs: Pending is the fifth (#996 step 11)", .tags(.driftGuard))
struct DictionaryPendingTabTests {
  @Test("five tabs, in order, with Pending last; every tab has a label, an icon and a short tagline")
  func fiveTabs() {
    #expect(DictionaryTab.allCases == [.yourWords, .vocabularyPacks, .learnFrom, .quickAdd, .pending])
    #expect(DictionaryTab.pending.label == "Pending")
    #expect(DictionaryTab.pending.tagline == "Fixes to review")
    for tab in DictionaryTab.allCases {
      #expect(!tab.label.isEmpty && !tab.icon.isEmpty)
      #expect(tab.tagline.count <= 18, "\(tab.tagline) would truncate in the 216 pt rail")
    }
  }
}

// MARK: - Presentation

@MainActor
@Suite("Pending tab presentation (#996 step 11)", .tags(.productOutcome))
struct PendingCorrectionsPresentationTests {

  @Test("a trusted empty ledger shows the empty sentence and no badge")
  func trustedEmpty() {
    let f = PendingFixture()
    #expect(f.content() == .empty)
    #expect(PendingCorrectionsView.badge(coordinator: f.coordinator) == 0)
    #expect(PendingCorrectionsPresentation.emptyCopy.hasPrefix("Nothing waiting."))
  }

  @Test("no coordinator means not composed: nothing drawn, no badge, and not the empty claim")
  func notComposed() {
    let f = PendingFixture()
    let content = PendingCorrectionsView.presentation(
      coordinator: nil, settings: f.settings, sourceAppName: { _ in nil }, now: f.now)
    #expect(content == .notComposed)
    #expect(PendingCorrectionsView.badge(coordinator: nil) == 0)
  }

  @Test("rows are newest first, carry the typed state, the app name when resolvable and a relative time; the badge counts them")
  func rowsNewestFirst() throws {
    let f = PendingFixture()
    let first = f.mint("sarah", "Saira")
    let second = f.mint("kubernetees", "Kubernetes", app: nil)
    guard case .rows(let rows) = f.content(sourceAppName: { $0 == "com.tinyspeck.slackmacgap" ? "Slack" : nil }) else {
      Issue.record("expected rows")
      return
    }
    #expect(rows.map(\.id) == [second, first], "newest first")
    #expect(rows[1].state == .existingWord(name: "Saira") && rows[0].state == .newWord)
    #expect(rows[1].sourceApp == "Slack")
    #expect(rows[0].sourceApp == nil, "a nil bundle id shows no app, not a placeholder")
    #expect(rows[0].relativeTime == "now" || rows[0].relativeTime == "in 0 seconds" || !rows[0].relativeTime.isEmpty)
    #expect(rows[1].relativeTime.contains("1 minute ago") || rows[1].relativeTime.contains("1 min"), "\(rows[1].relativeTime)")
    #expect(rows.allSatisfy { !$0.isResolving })
    #expect(PendingCorrectionsView.badge(coordinator: f.coordinator) == 2)
  }

  @Test("an unresolvable bundle id shows the time alone: no raw identifier, no invented app name")
  func unresolvedApp() throws {
    let f = PendingFixture()
    f.mint("sarah", "Saira", app: "com.example.unknown")
    guard case .rows(let rows) = f.content() else {
      Issue.record("expected rows")
      return
    }
    #expect(rows[0].sourceApp == nil)
  }

  @Test("toggle off hides the rows but keeps the badge and the records")
  func toggleOffHides() throws {
    let f = PendingFixture()
    let id = f.mint("sarah", "Saira")
    f.settings.learnFromEdits = false
    #expect(f.content() == .hidden)
    #expect(PendingCorrectionsView.badge(coordinator: f.coordinator) == 1, "hidden only at zero, not while off")
    #expect(f.coordinator.proposal(id: id)?.status == .pending, "kept, not erased")
    f.settings.learnFromEdits = true
    guard case .rows(let rows) = f.content() else {
      Issue.record("expected rows again")
      return
    }
    #expect(rows.map(\.id) == [id])
  }

  @Test("an accepting row stays visible and counted with its buttons disabled")
  func acceptingRow() throws {
    let f = PendingFixture()
    let id = f.mint("sarah", "Saira")
    // Stage an `accepting` record as a crash mid-accept leaves it, then reload
    // with an unreadable word list: reconciliation cannot decide, so the row
    // stays accepting on a READY ledger (the coordinator suite's own case).
    var staged = try #require(f.coordinator.proposal(id: id))
    staged.status = .accepting
    staged.acceptingIntent = CorrectionAcceptingIntent(
      pairKey: staged.pairKey, operation: .addAlias, targetWordID: f.saira.id)
    try f.store.upsert(staged)
    f.library.refresh = .unreadable
    f.coordinator.initialize()
    #expect(f.coordinator.ledgerState == .ready)
    #expect(f.coordinator.proposal(id: id)?.status == .accepting)
    #expect(f.coordinator.resolve(id: id, .accept, surface: .pending) == .inProgress)
    #expect(PendingCorrectionsPresentation.notice(for: .inProgress) == nil)
    guard case .rows(let rows) = f.content() else {
      Issue.record("expected rows")
      return
    }
    #expect(rows.count == 1 && rows[0].isResolving)
    #expect(PendingCorrectionsView.badge(coordinator: f.coordinator) == 1, "accepting counts")
    #expect(PendingCorrectionsPresentation.notice(for: .landedButUnrecorded) == "Saved, but couldn\u{2019}t record it.")
  }

  @Test("an unreadable ledger is its own state, distinct from empty, with resolution disabled")
  func untrusted() throws {
    let (blindStore, _, _) = makeFaultableStore()
    // A directory where the file should be: readable as a path, not as a file.
    try FileManager.default.createDirectory(at: blindStore.fileURL, withIntermediateDirectories: true)
    let f = PendingFixture()
    let c = CorrectionProposalCoordinator(
      store: blindStore, vocabulary: f.library.access, presenter: nil, telemetry: f.telemetry)
    c.initialize()
    let content = PendingCorrectionsView.presentation(
      coordinator: c, settings: f.settings, sourceAppName: { _ in nil }, now: f.now)
    #expect(content == .untrusted(.unreadable))
    #expect(content != .empty)
    #expect(PendingCorrectionsView.badge(coordinator: c) == 0, "no trustworthy count")
    #expect(c.resolve(id: UUID(), .accept, surface: .pending) == .ledgerUnavailable)
    #expect(PendingCorrectionsPresentation.notice(for: .ledgerUnavailable) == "Couldn\u{2019}t save.")
    #expect(PendingCorrectionsPresentation.untrustedCopy(for: .unreadable).hasPrefix("Your waiting suggestions couldn't be read this time."))
    #expect(PendingCorrectionsPresentation.untrustedCopy(for: .corrupt) == PendingCorrectionsPresentation.unreadableCopy, "a damaged file that could not move was left as found")
    #expect(
      PendingCorrectionsPresentation.untrustedCopy(for: .durabilityUnconfirmed)
        == "Your latest change to waiting suggestions couldn't be confirmed as saved. Try relaunching.")
    #expect(!PendingCorrectionsPresentation.durabilityCopy.contains("Nothing was changed"), "a landed-but-unconfirmed save may have changed the file")
  }

  @Test("a damaged ledger moves aside, the tab starts empty and trusted, and says so once")
  func recoveredLedger() throws {
    let (badStore, _, badDir) = makeFaultableStore()
    try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: badStore.fileURL)
    let f = PendingFixture()
    let c = CorrectionProposalCoordinator(
      store: badStore, vocabulary: f.library.access, presenter: nil, telemetry: f.telemetry)
    c.initialize()
    #expect(c.recoveredAtLaunch == .corrupt)
    let content = PendingCorrectionsView.presentation(
      coordinator: c, settings: f.settings, sourceAppName: { _ in nil }, now: f.now)
    #expect(content == .empty, "fresh and trusted: the ordinary empty state, under the one-time banner")
    #expect(
      PendingCorrectionsPresentation.recoveredCopy
        == "Your waiting suggestions file was damaged and moved aside for recovery. EnviousWispr started with an empty list.")
    // The banner is part of the rendered tab.
    let host = NSHostingView(rootView: AnyView(PendingCorrectionsView().environment(f.settings).environment(c).frame(width: 640)))
    host.layoutSubtreeIfNeeded()
    let plain = NSHostingView(rootView: AnyView(PendingCorrectionsView().environment(f.settings).environment(f.coordinator).frame(width: 640)))
    plain.layoutSubtreeIfNeeded()
    #expect(host.fittingSize.height > plain.fittingSize.height, "the recovery banner adds height over a plain empty tab")
  }

  @Test("Accept and Reject from the tab resolve through the coordinator only, and the list follows the ledger")
  func resolveThroughTheCoordinator() throws {
    let f = PendingFixture()
    let a = f.mint("sarah", "Saira")
    let b = f.mint("kubernetees", "Kubernetes")
    #expect(f.coordinator.resolve(id: a, .accept, surface: .pending) == .accepted(.aliasAdded))
    #expect(f.library.userWords.first { $0.canonical == "Saira" }?.aliases.contains("sarah") == true)
    #expect(f.coordinator.resolve(id: b, .reject, surface: .pending) == .rejected)
    #expect(f.content() == .empty, "both resolved, nothing left; no optimistic removal was needed")
    #expect(f.telemetry.events.contains(.resolved(.accepted, .pending, .existingWord, .aliasAdded)))
    #expect(f.telemetry.events.contains(.resolved(.rejected, .pending, .newWord, .added)) == false)
    #expect(PendingCorrectionsPresentation.notice(for: .accepted(.aliasAdded)) == nil)
    #expect(PendingCorrectionsPresentation.notice(for: .rejected) == nil)
    #expect(
      PendingCorrectionsPresentation.notice(for: .refused(.aliasOwnedElsewhere)) == "Couldn\u{2019}t save.",
      "the planned owner-naming sentence needs a name the outcome does not carry; generic approved copy until it does")
    #expect(PendingCorrectionsPresentation.notice(for: .refused(.targetGone)) == "Couldn\u{2019}t save.")
  }
}

// MARK: - Observation

@MainActor
@Suite("Pending tab observation: the coordinator invalidates its readers on every landed write (#996 step 11)", .tags(.productOutcome))
struct CorrectionProposalCoordinatorObservationTests {

  /// Reads the accessor the tab reads, inside observation tracking, and
  /// reports whether a later write fired the tracker.
  private func fires(after write: () -> Void, in f: PendingFixture) -> Bool {
    final class Flag: @unchecked Sendable {
      private let lock = NSLock()
      private var _fired = false
      var fired: Bool {
        get { lock.withLock { _fired } }
        set { lock.withLock { _fired = newValue } }
      }
    }
    let flag = Flag()
    withObservationTracking {
      _ = f.coordinator.openProposalsNewestFirst
    } onChange: {
      flag.fired = true
    }
    write()
    return flag.fired
  }

  @Test("a mint, an accept and a reject each fire the tracker while the ledger stays ready")
  func writesFire() {
    let f = PendingFixture()
    #expect(fires(after: { f.mint("sarah", "Saira") }, in: f))
    let id = f.mint("kubernetees", "Kubernetes")
    #expect(f.coordinator.ledgerState == .ready)
    #expect(fires(after: { _ = f.coordinator.resolve(id: id, .reject, surface: .pending) }, in: f))
    let again = f.mint("sorob", "Saurabh")
    #expect(fires(after: { _ = f.coordinator.resolve(id: again, .accept, surface: .pending) }, in: f))
    #expect(f.coordinator.ledgerState == .ready)
  }

  @Test("the revision counts landed writes; a refused write leaves it alone")
  func revisionCountsLandedWrites() {
    let f = PendingFixture()
    let before = f.coordinator.ledgerRevision
    f.mint("sarah", "Saira")
    // Two landed writes: the minted record, then `overlayAttempted` when the
    // single overlay attempt is spent (there is no presenter here, so it is
    // spent at once).
    #expect(f.coordinator.ledgerRevision == before + 2)
    let afterMint = f.coordinator.ledgerRevision
    f.faults.failCommit = true
    #expect(
      f.coordinator.propose(
        original: "x", corrected: "Y", state: .newWord, language: "en", contextExcerpt: nil,
        sourceBundleID: nil, advisorySafeAlias: nil) == .writeFailed)
    // A failed commit withholds trust (durability unconfirmed). That is a
    // change of the observed `ledgerState`, which redraws the tab on its own
    // (rows → untrusted banner); the revision is for landed writes and a
    // write that did not land leaves it alone.
    #expect(f.coordinator.ledgerState == .untrusted(.durabilityUnconfirmed))
    #expect(f.coordinator.ledgerRevision == afterMint, "no landed write, no bump")
  }

  @Test("a failed commit fires the tracker through the ledger state alone, so the banner replaces the rows")
  func stateChangeFires() {
    let f = PendingFixture()
    f.mint("sarah", "Saira")
    f.faults.failCommit = true
    #expect(
      fires(
        after: {
          _ = f.coordinator.propose(
            original: "x", corrected: "Y", state: .newWord, language: "en", contextExcerpt: nil,
            sourceBundleID: nil, advisorySafeAlias: nil)
        }, in: f))
    #expect(f.content() == .untrusted(.durabilityUnconfirmed))
    #expect(PendingCorrectionsView.badge(coordinator: f.coordinator) == 0)
  }

  @Test("a badge read is a ledger read: no second array, the count is the store's own open proposals")
  func badgeIsTheStoresCount() {
    let f = PendingFixture()
    f.mint("sarah", "Saira")
    f.mint("kubernetees", "Kubernetes")
    #expect(PendingCorrectionsView.badge(coordinator: f.coordinator) == f.store.ledger?.openProposals.count)
  }
}

// MARK: - Learning row

@Suite("Self-Learning Dictionary row (#996 §3.9)", .tags(.productOutcome))
struct LearnFromEditsRowTests {

  @Test("an arm enables the row with no reason line; each unavailable reason disables it with its own line")
  func mappings() {
    let rules = LearnFromEditsSettingsPresentation(selection: .arm(.rules))
    #expect(rules.isEnabled && rules.secondaryLine == nil)
    let afm = LearnFromEditsSettingsPresentation(selection: .arm(.afm))
    #expect(afm.isEnabled && afm.secondaryLine == nil)
    let none = LearnFromEditsSettingsPresentation(selection: .unavailable(.noQualifiedArm))
    #expect(!none.isEnabled && none.secondaryLine == "Not available on this version of macOS yet")
    let off = LearnFromEditsSettingsPresentation(selection: .unavailable(.afmUnavailableNoRulesFallback))
    #expect(
      !off.isEnabled
        && off.secondaryLine == "Turn on Apple Intelligence in System Settings to get suggestions")
    #expect(LearnFromEditsSettingsPresentation.unwired == none, "before wiring the row is disabled")
    let classifier = LearnFromEditsSettingsPresentation(selection: .arm(.classifier), judge: .ready)
    #expect(classifier.isEnabled && classifier.secondaryLine == nil && classifier.action == nil)
  }

  @Test("#996 phase D: every delivered-judge phase disables the row with its own line and its one action, and a ready judge on an unqualified macOS still says so")
  @MainActor func deliveryPhases() {
    typealias P = LearnFromEditsSettingsPresentation
    let none: CorrectionJudgeArmSelection = .unavailable(.noQualifiedArm)
    let table: [(P.JudgePhase, String, P.Action?)] = [
      (.notInstalled, "The correction model is not downloaded yet", .download),
      (.downloading(fractionCompleted: 0.5, bytesWritten: 161_405_824, totalBytes: 322_811_647),
       "Downloading the correction model (154 of 308 MB)", .cancel),
      (.verifying, "Checking the correction model", nil),
      (.loading, "Loading the correction model", nil),
      (.cancelled, "The download was cancelled", .download),
      (.deliveryFailed, "The correction model could not be downloaded", .download),
      (.loadFailed, "The correction model could not be loaded", .retryLoad),
      (.identityMismatch, "The downloaded correction model is not the one this version was tested with", .removeAndDownload),
      (.pausedByKillSwitch, "Model downloads are paused by Envious Labs", nil),
      (.waitingForOnboarding, "The correction model downloads after setup finishes", nil),
      (.waitingForSpeechModel, "The correction model downloads after the speech model", nil),
      (.debugLoading, "Loading the test judge from the UAT door", nil),
      (.debugFailed, "The test judge from the UAT door failed to load", nil),
      (.removalFailed, "The correction model could not be fully removed", .removeAndDownload),
      (.ready, "Not available on this version of macOS yet", nil),
      (.none, "Not available on this version of macOS yet", nil),
    ]
    for (phase, line, action) in table {
      let p = P(selection: none, judge: phase)
      #expect(!p.isEnabled, "\(phase)")
      #expect(p.secondaryLine == line, "\(phase)")
      #expect(p.action == action, "\(phase)")
    }
    // A total of zero bytes (size unknown yet) drops the count.
    #expect(P.downloadingLine(fraction: 0, written: 0, total: 0) == "Downloading the correction model")
    // The availability object routes each action to its bound closure.
    let availability = LearnFromEditsAvailability(presentation: P(selection: none, judge: .notInstalled))
    var fired: [String] = []
    availability.download = { fired.append("download") }
    availability.cancel = { fired.append("cancel") }
    availability.retryLoad = { fired.append("retry") }
    availability.removeAndDownload = { fired.append("remove") }
    for action in [P.Action.download, .cancel, .retryLoad, .removeAndDownload] { availability.perform(action) }
    #expect(fired == ["download", "cancel", "retry", "remove"])
    availability.publish(P(selection: .arm(.classifier), judge: .ready))
    #expect(availability.presentation.isEnabled)
  }

  @Test("the row is the founder's 2026-09-21 copy, word for word, with the help article behind Learn more")
  func rowCopy() {
    #expect(LearnFromEditsSettingsPresentation.rowTitle == "Self-Learning Dictionary")
    let copy = LearnFromEditsSettingsPresentation.rowCopy
    #expect(
      copy
        == "Automatically detects when you correct a dictation and suggests the corrected word for your dictionary. Review suggestions anytime in Dictionary → Pending.")
    #expect(copy.contains("stay on this Mac") == false)
    // The privacy sentences moved to the article; the row must not half-carry them.
    #expect(copy.contains("Envious Labs") == false)
    #expect(LearnFromEditsSettingsPresentation.learnMoreLabel == "Learn more")
    let url = URL(string: LearnFromEditsSettingsPresentation.learnMoreURL)
    #expect(url?.host() == "enviouswispr.com")
    #expect(url?.path() == "/help/self-learning-dictionary/")
  }
}

// MARK: - Rendered

@MainActor
@Suite("Pending tab and Learning row render with and without a coordinator (#996 step 11)", .tags(.productOutcome))
struct PendingCorrectionsRenderTests {

  private func host<V: View>(_ view: V) -> NSHostingView<AnyView> {
    let host = NSHostingView(rootView: AnyView(view.frame(width: 640)))
    host.layoutSubtreeIfNeeded()
    return host
  }

  @Test("the tab renders rows with a real coordinator, the empty state without proposals, and nothing when the coordinator is absent")
  func rendersEveryState() {
    let f = PendingFixture()
    let absent = host(PendingCorrectionsView().environment(f.settings))
    let absentHeight = absent.fittingSize.height
    #expect(absentHeight > 0, "the panel header still draws")

    let empty = host(PendingCorrectionsView().environment(f.settings).environment(f.coordinator))
    let emptyHeight = empty.fittingSize.height
    #expect(emptyHeight > absentHeight, "the empty sentence adds height: \(emptyHeight) vs \(absentHeight)")

    f.mint("sarah", "Saira")
    f.mint("kubernetees", "Kubernetes")
    let rows = host(PendingCorrectionsView().environment(f.settings).environment(f.coordinator))
    let rowsHeight = rows.fittingSize.height
    #expect(rowsHeight > emptyHeight, "two rows are taller than the empty sentence: \(rowsHeight) vs \(emptyHeight)")
  }

  @Test("the Learning row renders enabled and disabled without a Contacts coordinator crash")
  func learningRowRenders() {
    let f = PendingFixture()
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-pending-learning-\(UUID().uuidString)", isDirectory: true)
    // The default provider only wraps a `CNContactStore`; nothing here asks it
    // for access, so no permission prompt and no Contacts read.
    let contacts = ContactsImportCoordinator(
      customWords: CustomWordsCoordinator(
        manager: CustomWordsManager(fileURL: dir.appendingPathComponent("custom-words.json"))),
      stateStore: ImportedContactsStateStore(
        fileURL: dir.appendingPathComponent("imported-contacts-state.json")))
    let enabled = host(
      LearningSection().environment(f.settings).environment(contacts)
        .environment(LearnFromEditsAvailability(presentation: LearnFromEditsSettingsPresentation(selection: .arm(.rules)))))
    let disabled = host(
      LearningSection().environment(f.settings).environment(contacts)
        .environment(LearnFromEditsAvailability(presentation: .unwired)))
    #expect(enabled.fittingSize.height > 0)
    #expect(disabled.fittingSize.height > enabled.fittingSize.height, "the reason line adds a line")
  }
}
