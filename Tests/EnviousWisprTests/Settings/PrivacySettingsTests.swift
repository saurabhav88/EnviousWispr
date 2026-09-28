import EnviousWisprServices
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #3269: the Privacy section on the Permissions page. The restart notice, the "Restart now"
/// hand-off and the words, through the same helpers the view uses. No relaunch ever runs: the
/// relauncher is a recorder.
@MainActor
@Suite("Privacy settings (#3269)", .tags(.productOutcome))
struct PrivacySettingsTests {

  @Test(
    "The restart notice shows only while the stored crash switch differs from the launch mode",
    arguments: [
      (true, true, false), (false, false, false), (true, false, true), (false, true, true),
    ])
  func needsRestart(stored: Bool, launched: Bool, expected: Bool) {
    #expect(PermissionsSettingsView.needsRestart(stored: stored, launched: launched) == expected)
  }

  @Test("Before launch has run there is nothing to restart for")
  func noLaunchNoNotice() {
    #expect(PermissionsSettingsView.needsRestart(stored: true, launched: nil) == false)
    #expect(PermissionsSettingsView.needsRestart(stored: false, launched: nil) == false)
  }

  /// The notice reads the stored switch each time the page draws, so flipping back hides it and
  /// flipping again (or reopening the page) shows it; nothing caches a pending flag.
  @Test("Flip and flip back: the notice follows the stored switch on every read")
  func flipAndRevert() {
    let suite = UserDefaults(suiteName: "ew-3269-privacy-\(UUID().uuidString)")!
    let settings = SettingsManager(defaults: suite)
    let launched = settings.sendCrashReports
    #expect(launched == true)

    settings.sendCrashReports = false
    #expect(
      PermissionsSettingsView.needsRestart(stored: settings.sendCrashReports, launched: launched)
        == true)
    settings.sendCrashReports = true
    #expect(
      PermissionsSettingsView.needsRestart(stored: settings.sendCrashReports, launched: launched)
        == false)
    settings.sendCrashReports = false
    let reopened = SettingsManager(defaults: suite)
    #expect(
      PermissionsSettingsView.needsRestart(stored: reopened.sendCrashReports, launched: launched)
        == true)
  }

  @Test("Restart now does nothing while work is in flight")
  func busyRefuses() {
    var handedOff = 0
    let didHandOff = PermissionsSettingsView.restartNow(isBusy: { true }) { _ in handedOff += 1 }
    #expect(didHandOff == false)
    #expect(handedOff == 0)
  }

  @Test("Restart now hands off once, with a busy check that still sees later work")
  func idleHandsOffALiveCheck() throws {
    var busy = false
    var received: [@MainActor () -> Bool] = []
    let didHandOff = PermissionsSettingsView.restartNow(isBusy: { busy }) { received.append($0) }

    #expect(didHandOff == true)
    #expect(received.count == 1)
    let check = try #require(received.first)
    #expect(check() == false)
    busy = true
    #expect(check() == true)
  }

  @Test("The shared busy check still counts a dictation and nothing else when no import runs")
  func workInFlightUnchanged() {
    #expect(AppRelauncher.workInFlight(dictationActive: true, fileImport: nil) == true)
    #expect(AppRelauncher.workInFlight(dictationActive: false, fileImport: nil) == false)
  }

  @Test("The Privacy words are the founder-approved English")
  func copy() {
    #expect(PrivacySettingsCopy.metricsLabel == "Share usage metrics")
    #expect(
      PrivacySettingsCopy.metricsHelp
        == "Anonymous counts and timings that show me when a release breaks dictation. Never audio or text. Stops collecting right away."
    )
    #expect(PrivacySettingsCopy.crashLabel == "Send crash reports")
    #expect(PrivacySettingsCopy.crashHelp == "Details about crashes and errors so I can fix them.")
    #expect(PrivacySettingsCopy.restartNotice == "Takes effect when EnviousWispr restarts")
    #expect(PrivacySettingsCopy.restartAction == "Restart now")
  }

  /// The crash row does not mention bug reports (founder 2026-09-28: "it's confusing").
  @Test("The crash switch's words say nothing about bug reports or feedback")
  func crashRowHasNoBugReportLine() {
    for text in [PrivacySettingsCopy.crashLabel, PrivacySettingsCopy.crashHelp] {
      #expect(text.localizedCaseInsensitiveContains("bug") == false)
      #expect(text.localizedCaseInsensitiveContains("feedback") == false)
    }
  }
}
