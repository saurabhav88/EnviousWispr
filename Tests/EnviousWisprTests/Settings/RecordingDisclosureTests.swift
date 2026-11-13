import AppKit
import EnviousWisprAppKitTestSupport
import Foundation
import SwiftUI
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprServices

/// #3147 C9 recording disclosure: when these fail, someone who updated is never told their
/// dictations are now recorded, sees the notice again after dismissing it, a brand-new user is
/// shown an "upgrade" notice, reading What's New silently hides it, or a notice describes a
/// default the user already changed.
@MainActor
@Suite("Recording disclosure", .tags(.productOutcome))
struct RecordingDisclosureTests {
  private func suite() -> UserDefaults {
    let name = "ew.recordingDisclosureTest." + UUID().uuidString
    let defaults = TestDefaults.suite(name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test("an install that finished setup before recordings sees the notice until it is dismissed")
  func upgradeSeesItUntilDismissed() {
    let defaults = suite()
    defaults.set(true, forKey: "hasCompletedOnboarding")  // set up on an earlier version
    let settings = SettingsManager(defaults: defaults)
    #expect(settings.isRecordingDisclosureUpgrade)
    #expect(settings.showsRecordingUpgradeDisclosure)

    #expect(SettingsManager(defaults: defaults).showsRecordingUpgradeDisclosure, "until dismissed")
    settings.acknowledgeRecordingDisclosure()
    #expect(!settings.showsRecordingUpgradeDisclosure)
    #expect(
      !SettingsManager(defaults: defaults).showsRecordingUpgradeDisclosure,
      "dismissed once, gone after a relaunch")
  }

  @Test("a fresh install never gets the upgrade notice, even after finishing setup")
  func freshInstallNeverSeesIt() {
    let defaults = suite()
    let settings = SettingsManager(defaults: defaults)
    #expect(!settings.isRecordingDisclosureUpgrade)
    #expect(!settings.showsRecordingUpgradeDisclosure)

    settings.onboardingState = .completed  // setup finishes in this same run
    #expect(!settings.showsRecordingUpgradeDisclosure)
    let relaunched = SettingsManager(defaults: defaults)
    #expect(relaunched.onboardingEverCompleted)
    #expect(
      !relaunched.showsRecordingUpgradeDisclosure, "the cohort was decided once, at first launch")
  }

  @Test("an unfinished setup resumed after the update is treated as a fresh install")
  func resumedSetupIsFresh() {
    let defaults = suite()
    defaults.set("needsModelDownload", forKey: "onboardingState")  // started, never finished
    let settings = SettingsManager(defaults: defaults)
    #expect(!settings.showsRecordingUpgradeDisclosure)
  }

  @Test("opening What's New does not dismiss the History notice")
  func whatsNewIsIndependent() {
    let defaults = suite()
    defaults.set(true, forKey: "hasCompletedOnboarding")
    let settings = SettingsManager(defaults: defaults)
    settings.markWhatsNewSeen()
    #expect(!settings.hasUnreadWhatsNew)
    #expect(settings.showsRecordingUpgradeDisclosure)
  }

  @Test("the notices never write recording settings and never describe a default the user changed")
  func copyFollowsLiveSettings() {
    let defaults = suite()
    let settings = SettingsManager(defaults: defaults)
    _ = RecordingDisclosureCopy.onboardingNote(
      saving: settings.saveDictationRecordings, retention: settings.dictationRecordingRetention)
    settings.acknowledgeRecordingDisclosure()
    #expect(defaults.object(forKey: "saveDictationRecordings") == nil, "nothing seeded")
    #expect(defaults.object(forKey: "dictationRecordingRetention") == nil)

    let byDefault = RecordingDisclosureCopy.bannerBody(saving: true, retention: .forever)
    #expect(byDefault.contains("Recordings stay until you delete them"))
    #expect(byDefault.contains("without deleting the ones you have"))
    #expect(byDefault.contains("Delete all dictation recordings"))
    #expect(byDefault.contains("Settings > App Settings > Recordings"))
    let chosen = RecordingDisclosureCopy.bannerBody(saving: true, retention: .day7)
    #expect(
      !chosen.contains("until you delete them"), "a chosen keep period is never called forever")
    let off = RecordingDisclosureCopy.bannerBody(saving: false, retention: .forever)
    #expect(off.contains("is off"))
    #expect(
      !RecordingDisclosureCopy.onboardingNote(saving: true, retention: .day30).contains(
        "until you delete them"))
    #expect(
      RecordingDisclosureCopy.onboardingNote(saving: false, retention: .forever).contains("is off"))
    for text in [byDefault, chosen, off] {
      #expect(!text.contains("—") && !text.contains("–"), "no dashes")
      #expect(!text.contains("7 days"), "no seven-day claim")
    }
  }

  @Test("the onboarding note states every fact: default, keep period, turning off, deleting")
  func onboardingNoteFacts() {
    let byDefault = RecordingDisclosureCopy.onboardingNote(saving: true, retention: .forever)
    #expect(byDefault.contains("stay until you delete them"))
    #expect(byDefault.contains("Save dictation recordings"))
    #expect(byDefault.contains("existing audio stays subject to your keep period"))
    #expect(byDefault.contains("Delete all dictation recordings"))
    #expect(byDefault.contains("History"))
    #expect(byDefault.contains("The text stays"))
    let chosen = RecordingDisclosureCopy.onboardingNote(saving: true, retention: .day30)
    #expect(!chosen.contains("until you delete them"))
    #expect(chosen.contains("Delete all dictation recordings"))
    #expect(chosen.contains("existing audio stays subject to your keep period"))
    let off = RecordingDisclosureCopy.onboardingNote(saving: false, retention: .forever)
    #expect(off.contains("is off"))
    #expect(off.contains("Delete all dictation recordings"))
    for text in [byDefault, chosen, off] {
      #expect(!text.contains("—") && !text.contains("–"))
    }
  }

  @Test("an upgrading install that re-runs setup still gets its History notice")
  func rerunSetupKeepsUpgradeNotice() {
    let defaults = suite()
    defaults.set(true, forKey: "hasCompletedOnboarding")
    let settings = SettingsManager(defaults: defaults)
    settings.recordOnboardingRecordingNoteShown()  // setup's note, worded for new users
    #expect(settings.showsRecordingUpgradeDisclosure, "only the History dismiss button hides it")
    #expect(SettingsManager(defaults: defaults).showsRecordingUpgradeDisclosure)
  }

  @Test("Open Recordings settings goes to App Settings > Recordings")
  func opensRecordings() {
    let navigation = NavigationCoordinator()
    navigation.request(.appSettings(.recordings))
    #expect(navigation.pendingDestination == .appSettings(.recordings))
  }
}
