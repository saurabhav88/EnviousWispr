import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// #3124: the English (UK) row in the dictation-language picker. When one of these fails, a
/// British user cannot find or keep the choice, the picker ticks the wrong English, or the engine
/// is handed a code it cannot use.
@MainActor
@Suite("English (UK) picker row", .tags(.productOutcome))
struct EnglishUKPickerTests {

  private static func settings() -> SettingsManager {
    let name = "ew.english.uk.picker.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return SettingsManager(defaults: defaults)
  }

  private static var english: LanguageCatalog.Entry { LanguageCatalog.entry(for: "en") }
  private static var german: LanguageCatalog.Entry { LanguageCatalog.entry(for: "de") }

  // MARK: - Catalogue and rows

  @Test("the language catalogue is unchanged: bare codes only, each locking to itself")
  func catalogueUnchanged() {
    #expect(LanguageCatalog.all.contains { $0.code == "en-gb" } == false)
    #expect(LanguageCatalog.all.allSatisfy { $0.lockCode == $0.code })
    #expect(LanguageCatalog.all.filter { $0.spelling != nil }.map(\.code) == ["en"])
    #expect(
      LanguageCatalog.entry(for: "en").englishName == "English", "the English row keeps its name")
  }

  @Test("English (UK) sits directly after English, locks to en, and has its own identity")
  func ukRowPlacement() throws {
    let rows = LanguageCatalog.pickerEntries
    #expect(rows.count == LanguageCatalog.all.count + 1)
    let englishIndex = try #require(rows.firstIndex { $0.code == "en" })
    #expect(rows[englishIndex + 1] == LanguageCatalog.englishUK)
    #expect(LanguageCatalog.englishUK.lockCode == "en")
    #expect(LanguageCatalog.englishUK.englishName == "English (UK)")
    #expect(Set(rows.map(\.code)).count == rows.count, "row identities must be distinct")
  }

  @Test("the sheet's own filter finds English (UK) by uk and gb")
  func ukRowSearchable() {
    for query in ["uk", "GB", "  English (UK) "] {
      let rows = LanguageLockOptions.pickerRows(lockableCodes: nil, query: query, offersEnglishUK: true)
      #expect(rows.contains(LanguageCatalog.englishUK), "search \(query) must find English (UK)")
    }
    #expect(
      LanguageLockOptions.pickerRows(lockableCodes: nil, query: "german", offersEnglishUK: true)
        .contains(LanguageCatalog.englishUK) == false)
  }

  @Test("the sheet's own filter offers English (UK) exactly where English is")
  func ukOfferedWhereEnglishIs() throws {
    func offered(_ codes: Set<String>?, uk: Bool = true) -> Set<String> {
      Set(
        LanguageLockOptions.pickerRows(lockableCodes: codes, query: "", offersEnglishUK: uk)
          .map(\.code))
    }
    #expect(offered(nil).isSuperset(of: ["en", "en-gb"]), "no restriction offers both")
    let parakeet = try #require(LanguageLockOptions.lockableCodes(for: .parakeet))
    #expect(offered(parakeet).isSuperset(of: ["en", "en-gb"]))
    let frenchPackOnly = LanguageLockOptions.previewLockableCodes(
      backend: .whisperKit, previewEngine: .apple, installedPackTags: ["fr-FR"])
    #expect(offered(frenchPackOnly).contains("en-gb") == false)
    #expect(offered(frenchPackOnly).contains("en") == false)
    #expect(offered(frenchPackOnly).contains("fr"))
    let britishPack = LanguageLockOptions.previewLockableCodes(
      backend: .whisperKit, previewEngine: .apple, installedPackTags: ["en-GB"])
    #expect(offered(britishPack).isSuperset(of: ["en", "en-gb"]))
  }

  @Test("the Live Preview picker offers English (UK) on Apple only with the en-GB pack installed")
  func previewNeedsBritishPack() {
    func previewRows(_ engine: LivePreviewEngineChoice, _ tags: [String]) -> Set<String> {
      let codes = LanguageLockOptions.previewLockableCodes(
        backend: .whisperKit, previewEngine: engine, installedPackTags: tags)
      let uk = LanguageLockOptions.previewOffersEnglishUK(
        previewEngine: engine, installedPackTags: tags)
      return Set(
        LanguageLockOptions.pickerRows(lockableCodes: codes, query: "", offersEnglishUK: uk)
          .map(\.code))
    }
    let americanOnly = previewRows(.apple, ["en-US"])
    #expect(americanOnly.contains("en"), "English itself runs on the American pack")
    #expect(americanOnly.contains("en-gb") == false, "the British row needs the en-GB pack")
    #expect(previewRows(.apple, ["en-US", "en_GB"]).contains("en-gb"))
    #expect(previewRows(.universal, []).contains("en-gb"), "the universal engine has no packs")
  }

  @Test("the two English rows say which spelling they give; other rows keep name and code")
  func subtitles() {
    #expect(
      LanguageCatalog.pickerSubtitle(for: LanguageCatalog.englishUK)
        == "British spelling: colour, organise, centre")
    #expect(
      LanguageCatalog.pickerSubtitle(for: Self.english)
        == "American spelling: color, organize, center")
    #expect(LanguageCatalog.pickerSubtitle(for: Self.german) == "German · de")
  }

  @Test("a lock is named by the English actually chosen: recents and the Transcription page")
  func lockNaming() {
    #expect(
      LanguageCatalog.entry(forLockedCode: "en", spelling: .british) == LanguageCatalog.englishUK)
    #expect(LanguageCatalog.entry(forLockedCode: "en", spelling: .american) == Self.english)
    #expect(LanguageCatalog.entry(forLockedCode: "de", spelling: .british) == Self.german)
  }

  // MARK: - Choosing, through real settings

  @Test("choosing English (UK) writes the spelling, then the lock, and reports en-GB")
  func chooseUK() {
    let settings = Self.settings()
    var changes: [SettingsManager.SettingKey] = []
    settings.onChange = { changes.append($0) }
    let event = LanguageLockOptions.apply(LanguageCatalog.englishUK, to: settings)
    #expect(changes == [.englishSpelling, .languageMode], "spelling first, then the lock")
    #expect(settings.languageMode == .locked("en"), "the engine is never handed en-gb")
    #expect(settings.englishSpelling == .british)
    #expect(event.fromLang == "auto")
    #expect(event.toLang == "en-GB")
    #expect(event.reason == "first_time")
    #expect(
      LanguageLockOptions.isSelected(
        LanguageCatalog.englishUK, mode: settings.languageMode, stored: settings.englishSpelling))
    #expect(
      LanguageLockOptions.isSelected(
        Self.english, mode: settings.languageMode, stored: settings.englishSpelling) == false)
  }

  @Test("switching between the two Englishes is a visible change, in both directions")
  func switchBetweenEnglishes() {
    let settings = Self.settings()
    _ = LanguageLockOptions.apply(LanguageCatalog.englishUK, to: settings)
    let toUS = LanguageLockOptions.apply(Self.english, to: settings)
    #expect(settings.englishSpelling == .american)
    #expect(toUS.fromLang == "en-GB")
    #expect(toUS.toLang == "en")
    #expect(toUS.reason == "preference")
    let toUK = LanguageLockOptions.apply(LanguageCatalog.englishUK, to: settings)
    #expect(toUK.fromLang == "en")
    #expect(toUK.toLang == "en-GB")
  }

  @Test("another language or Auto keeps the British choice, and English (UK) comes back with it")
  func preferenceSurvivesOtherChoices() {
    let settings = Self.settings()
    _ = LanguageLockOptions.apply(LanguageCatalog.englishUK, to: settings)
    let toGerman = LanguageLockOptions.apply(Self.german, to: settings)
    #expect(settings.languageMode == .locked("de"))
    #expect(settings.englishSpelling == .british, "a non-English row leaves the preference alone")
    #expect(toGerman.toLang == "de")
    #expect(
      LanguageLockOptions.isSelected(
        LanguageCatalog.englishUK, mode: settings.languageMode, stored: settings.englishSpelling)
        == false)

    let toAuto = LanguageLockOptions.apply(nil, to: settings)
    #expect(settings.languageMode == .auto)
    #expect(toAuto.fromLang == "de")
    #expect(toAuto.toLang == "auto")
    // Back to English by the Auto toggle's restore path: the lock alone brings British back.
    settings.languageMode = .locked("en")
    #expect(
      LanguageLockOptions.isSelected(
        LanguageCatalog.englishUK, mode: settings.languageMode, stored: settings.englishSpelling))
  }
}
