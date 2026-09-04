import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// The S1-mini writing-style picks must survive a restart (#2649). When a row
/// here fails, the user picks Formal, quits, relaunches, and dictates in
/// semi-formal again with nothing on screen saying why.
@MainActor
@Suite("S1-mini control picks persist (#2649)", .tags(.productOutcome))
struct S1ControlPersistenceTests {

  private func freshSuite() -> UserDefaults {
    UserDefaults(suiteName: "S1Control-\(UUID().uuidString)")!
  }

  @Test("a fresh install runs under the shipped control line")
  func freshInstallIsTheDefault() {
    let settings = SettingsManager(defaults: freshSuite())
    #expect(settings.s1Control == .default)
    #expect(settings.s1MiniStyling == .semiFormal)
    #expect(settings.s1MiniStructure == .lists)
    #expect(settings.s1MiniContext == .general)
  }

  /// Written through one manager, read through a second over the same store,
  /// which is what a relaunch is. The composed value is asserted, because that
  /// is the one the pipeline freezes per recording.
  @Test("picks written by one launch are read back by the next")
  func picksSurviveRelaunch() {
    let store = freshSuite()
    let first = SettingsManager(defaults: store)
    first.s1MiniStyling = .formal
    first.s1MiniStructure = .prose
    first.s1MiniContext = .email

    let second = SettingsManager(defaults: store)
    #expect(
      second.s1Control == S1ControlSettings(styling: .formal, structure: .prose, context: .email))
    // And the stored form is the wire token, so the on-disk value can be read
    // without this app's enum in hand.
    #expect(store.string(forKey: "s1MiniStyling") == "formal")
    #expect(store.string(forKey: "s1MiniStructure") == "prose")
    #expect(store.string(forKey: "s1MiniContext") == "email")
  }

  /// A token this build does not know, written by a newer build or by hand,
  /// falls back to the shipped default for THAT axis only. Direction matters:
  /// the model must never be sent an untrained value, and the other two picks
  /// must not be thrown away with it.
  @Test("an unknown stored token falls back to the default for that axis alone")
  func unknownTokenFallsBackPerAxis() {
    let store = freshSuite()
    store.set("shouty", forKey: "s1MiniStyling")
    store.set("prose", forKey: "s1MiniStructure")
    store.set("email", forKey: "s1MiniContext")

    let settings = SettingsManager(defaults: store)
    #expect(settings.s1MiniStyling == .semiFormal)
    #expect(settings.s1MiniStructure == .prose)
    #expect(settings.s1MiniContext == .email)
  }

  /// The build-unification list (#923) is what carries a setting across the
  /// dev and release suites. A key missing from it persists in one build and
  /// vanishes in the other.
  @Test("all three keys are in the unified defaults list, exactly once each")
  func keysAreUnified() {
    for key in ["s1MiniStyling", "s1MiniStructure", "s1MiniContext"] {
      #expect(
        SettingsManager.unifiedDefaultsKeys.filter { $0 == key }.count == 1, Comment(rawValue: key))
    }
  }
}
