import AppKit
import EnviousWisprContacts
import EnviousWisprLLM
import EnviousWisprModelDelivery
import EnviousWisprPostProcessing
import Foundation
import SwiftUI
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// The `learnFromEdits` setting (#996 §3.9): ON by default, written to the store
/// only when the key is absent, and an explicit choice survives reconstruction
/// in both directions.
@MainActor
@Suite("Learn-from-edits setting (#996)", .tags(.productOutcome))
struct LearnFromEditsSettingTests {

  private static func freshSuite() -> UserDefaults {
    let name = "ew.learn.settings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test(
    "a fresh install is ON, and the absent key is written so a later default flip cannot change it")
  func absentKeyIsWrittenOn() {
    let suite = Self.freshSuite()
    #expect(suite.object(forKey: "learnFromEdits") == nil, "precondition: absent")
    let settings = SettingsManager(defaults: suite)
    #expect(settings.learnFromEdits)
    #expect(suite.object(forKey: "learnFromEdits") as? Bool == true)
  }

  @Test("an explicit OFF survives reconstruction and is never rewritten to the default")
  func explicitFalseSurvives() {
    let suite = Self.freshSuite()
    suite.set(false, forKey: "learnFromEdits")
    #expect(SettingsManager(defaults: suite).learnFromEdits == false)
    #expect(suite.object(forKey: "learnFromEdits") as? Bool == false)
    let settings = SettingsManager(defaults: suite)
    settings.learnFromEdits = true
    #expect(SettingsManager(defaults: suite).learnFromEdits)
  }

  @Test("an explicit ON stays ON, and turning it off persists and fires the change key")
  func explicitTrueAndChange() {
    let suite = Self.freshSuite()
    suite.set(true, forKey: "learnFromEdits")
    let settings = SettingsManager(defaults: suite)
    #expect(settings.learnFromEdits)
    var changed: [SettingsManager.SettingKey] = []
    settings.onChange = { changed.append($0) }
    settings.learnFromEdits = false
    #expect(changed == [.learnFromEdits])
    #expect(SettingsManager(defaults: suite).learnFromEdits == false)
  }

  @Test("the key is unified across builds")
  func inUnifiedKeySet() {
    #expect(SettingsManager.unifiedDefaultsKeys.contains("learnFromEdits"))
    #expect(SettingsManager.unifiedDefaultsKeys.filter { $0 == "learnFromEdits" }.count == 1)
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
        == "Automatically detects when you correct a dictation and adds the corrected word to your dictionary. Undo it from the notification, or remove it later in Your Words.")
    #expect(copy.contains("stay on this Mac") == false)
    // The ask-first design is gone (2026-09-21 pivot): the row never points at
    // a Pending tab or at suggestions to review.
    #expect(copy.contains("Pending") == false && copy.contains("suggest") == false)
    // The privacy sentences moved to the article; the row must not half-carry them.
    #expect(copy.contains("Envious Labs") == false)
    #expect(LearnFromEditsSettingsPresentation.learnMoreLabel == "Learn more")
    let url = URL(string: LearnFromEditsSettingsPresentation.learnMoreURL)
    #expect(url?.host() == "enviouswispr.com")
    #expect(url?.path() == "/help/self-learning-dictionary/")
  }

  @Test("the Learning row renders enabled and disabled without a Contacts coordinator crash")
  @MainActor func learningRowRenders() throws {
    func host<V: View>(_ view: V) -> NSHostingView<AnyView> {
      let host = NSHostingView(rootView: AnyView(view.frame(width: 640)))
      host.layoutSubtreeIfNeeded()
      return host
    }
    let name = "ew.learn.row.settings.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    let settings = SettingsManager(defaults: defaults)
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-learning-row-\(UUID().uuidString)", isDirectory: true)
    // The default provider only wraps a `CNContactStore`; nothing here asks it
    // for access, so no permission prompt and no Contacts read.
    let contacts = ContactsImportCoordinator(
      customWords: CustomWordsCoordinator(
        manager: CustomWordsManager(fileURL: dir.appendingPathComponent("custom-words.json"))),
      stateStore: ImportedContactsStateStore(
        fileURL: dir.appendingPathComponent("imported-contacts-state.json")))
    // #3105: the row also reads the learned-word check's eligibility. No
    // manifest and no server binary, so it reports the check as unavailable.
    let resources = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Sources/EnviousWispr/Resources")
    let checker = EGOneCheckerEligibility(
      delivery: ModelDeliveryHome(
        engineMutationScope: .live(
          tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
        manifestBundle: try #require(Bundle(url: resources)),
        appSupportOverride: dir.appendingPathComponent("delivery", isDirectory: true)),
      base: nil, promptTemplateID: nil,
      runtime: EGOneRuntime(manifest: nil, serverBinaryURL: nil, delivery: nil))
    let enabled = host(
      LearningSection().environment(settings).environment(contacts).environment(checker)
        .environment(LearnFromEditsAvailability(presentation: LearnFromEditsSettingsPresentation(selection: .arm(.rules)))))
    let disabled = host(
      LearningSection().environment(settings).environment(contacts).environment(checker)
        .environment(LearnFromEditsAvailability(presentation: .unwired)))
    #expect(enabled.fittingSize.height > 0)
    #expect(disabled.fittingSize.height > enabled.fittingSize.height, "the reason line adds a line")
  }
}

// MARK: - Dictionary tabs

/// The Pending tab left with the ask-first design (#996, 2026-09-21 pivot):
/// the rail is back to its four tabs and carries no count badge.
@Suite("Dictionary tabs: four, in order, no Pending (#996)", .tags(.driftGuard))
struct DictionaryTabTests {
  @Test("four tabs, in order; every tab has a label, an icon and a short tagline")
  func fourTabs() {
    #expect(DictionaryTab.allCases == [.yourWords, .vocabularyPacks, .learnFrom, .quickAdd])
    #expect(DictionaryTab.allCases.map(\.label) == ["Your Words", "Vocabulary Packs", "Learn from...", "Quick Add"])
    for tab in DictionaryTab.allCases {
      #expect(!tab.icon.isEmpty, "\(tab)")
      #expect(!tab.tagline.isEmpty && tab.tagline.count <= 18, "\(tab): \(tab.tagline)")
    }
  }
}
