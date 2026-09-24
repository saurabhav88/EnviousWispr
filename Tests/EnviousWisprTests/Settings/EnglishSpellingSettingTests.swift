import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// #3124: the English spelling preference persists, defaults to American, and reaches the
/// file-import and recovery snapshot as the value IN FORCE. When one of these fails, a British
/// user's choice is lost on relaunch, or an import or recovered take is spelled differently from
/// live dictation.
@MainActor
@Suite("English (UK) spelling setting", .tags(.productOutcome))
struct EnglishSpellingSettingTests {

  private static func freshSuite() -> UserDefaults {
    let name = "ew.english.spelling.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test("a fresh install and an unknown stored value both load as American")
  func defaultsToAmerican() {
    #expect(SettingsManager(defaults: Self.freshSuite()).englishSpelling == .american)
    let garbage = Self.freshSuite()
    garbage.set("australian", forKey: "englishSpelling")
    #expect(SettingsManager(defaults: garbage).englishSpelling == .american)
  }

  @Test("British survives relaunch and fires its own change key")
  func britishPersists() {
    let suite = Self.freshSuite()
    let settings = SettingsManager(defaults: suite)
    var changed: [SettingsManager.SettingKey] = []
    settings.onChange = { changed.append($0) }
    settings.englishSpelling = .british
    #expect(changed == [.englishSpelling])
    #expect(suite.string(forKey: "englishSpelling") == "british")
    #expect(SettingsManager(defaults: suite).englishSpelling == .british)
    #expect(SettingsManager.unifiedDefaultsKeys.filter { $0 == "englishSpelling" }.count == 1)
  }

  @Test("a file import freezes the spelling in force, not the stored preference")
  func fileImportSnapshotIsEffective() {
    let settings = SettingsManager(defaults: Self.freshSuite())
    settings.englishSpelling = .british
    settings.languageMode = .locked("en")
    #expect(FileImportSettingsFreeze.snapshot(settings: settings).englishSpelling == .british)
    settings.languageMode = .locked("fr")
    #expect(FileImportSettingsFreeze.snapshot(settings: settings).englishSpelling == .american)
    settings.languageMode = .auto
    #expect(FileImportSettingsFreeze.snapshot(settings: settings).englishSpelling == .american)
  }

  @Test("the settings-change event reports the preference as a closed value")
  func settingsTelemetryProjection() {
    let settings = SettingsManager(defaults: Self.freshSuite())
    settings.englishSpelling = .british
    #expect(SettingsProjection.logicals(for: .englishSpelling) == [.englishSpelling])
    #expect(SettingsProjection.Logical.englishSpelling.rawValue == "english_spelling")
    #expect(SettingsProjection.value(for: .englishSpelling, settings: settings) == "british")
  }
}
