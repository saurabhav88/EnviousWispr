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

  // MARK: - #4565 guided tour offer state

  @Test("an install that finished setup before the tour gets no automatic offer, whatever it did with the recording notice")
  func earlierInstallGetsNoAutomaticTour() {
    for acknowledged in [false, true] {
      let defaults = suite()
      defaults.set(true, forKey: "hasCompletedOnboarding")  // set up on an earlier version
      defaults.set(acknowledged, forKey: "recordingDisclosureAcknowledged")
      let settings = SettingsManager(defaults: defaults)
      #expect(settings.guidedTourOfferState == .earlier)
      settings.consumeGuidedTourOffer()
      #expect(settings.guidedTourOfferState == .earlier, "a replay never turns earlier into consumed")
    }
  }

  @Test("an install still in setup at update time is offered the tour once")
  func unfinishedSetupGetsExactlyOneOffer() {
    let defaults = suite()
    defaults.set("needsModelDownload", forKey: "onboardingState")  // started, never finished
    let settings = SettingsManager(defaults: defaults)
    #expect(settings.guidedTourOfferState == .eligible)

    settings.onboardingState = .completed  // finishes setup in this run
    #expect(settings.guidedTourOfferState == .eligible, "finishing setup does not change the seed")
    settings.consumeGuidedTourOffer()
    #expect(settings.guidedTourOfferState == .consumed)
    #expect(
      SettingsManager(defaults: defaults).guidedTourOfferState == .consumed,
      "shown once, gone after a relaunch")
  }

  @Test("a brand-new install is eligible and the tour state is independent of the recording notice")
  func freshInstallIsEligibleAndIndependent() {
    let defaults = suite()
    let settings = SettingsManager(defaults: defaults)
    #expect(settings.guidedTourOfferState == .eligible)
    settings.acknowledgeRecordingDisclosure()
    #expect(settings.guidedTourOfferState == .eligible, "the notice does not consume the tour")
    settings.consumeGuidedTourOffer()
    #expect(settings.recordingDisclosureAcknowledged)

    let other = SettingsManager(defaults: suite())
    other.consumeGuidedTourOffer()
    #expect(!other.recordingDisclosureAcknowledged, "the tour does not dismiss the notice")
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
    _ = RecordingDisclosureCopy.bannerBody(
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
    for text in [byDefault, chosen, off] {
      #expect(!text.contains("—") && !text.contains("–"), "no dashes")
      #expect(!text.contains("7 days"), "no seven-day claim")
    }
  }

  @Test("Open Recordings settings goes to App Settings > Recordings")
  func opensRecordings() {
    let navigation = NavigationCoordinator()
    navigation.request(.appSettings(.recordings))
    #expect(navigation.pendingDestination == .appSettings(.recordings))
  }
}
