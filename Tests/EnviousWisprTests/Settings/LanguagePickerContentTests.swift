import EnviousWisprCore
import EnviousWisprServices
import AppKit
import Foundation
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #4320: the language window renders only from `LanguagePickerContent`. When this fails, the
/// user sees the dictation language window offer a language the engine cannot honour, mark the
/// wrong English row as chosen, show stale or ineligible Recent languages, or record a lock
/// before it is applied; or an EnviousMeet window quietly changes the dictation language.
@MainActor
@Suite("Language window content (#4320)", .tags(.productOutcome))
struct LanguagePickerContentTests {

  /// A dictation content with recorded choices (nil is Auto).
  final class Picks {
    var chosen: [String?] = []
  }

  func dictation(
    mode: LanguageMode = .auto, stored: EnglishSpelling = .american,
    lockable: Set<String>? = nil, query: String = "",
    recents: [LanguageCatalog.Entry] = [], picks: Picks = Picks()
  ) -> LanguagePickerContent {
    LanguagePickerContent.dictation(
      mode: mode, stored: stored, lockableCodes: lockable, contextSubtitle: nil,
      offersEnglishUK: true, query: query, recents: recents
    ) { picks.chosen.append($0?.code) }
  }

  @Test(
    "restricted to two languages, the window lists exactly their rows, English with both spellings")
  func restrictedRows() {
    let content = dictation(lockable: ["en", "de"])
    #expect(content.rows.map(\.id) == ["en", "en-gb", "de"], "catalog display order, UK right after English")
    #expect(content.heading == String(localized: "AVAILABLE ON THIS MAC"))
  }

  @Test("unrestricted, the window lists every picker row under the all-languages heading")
  func unrestrictedRows() {
    let content = dictation()
    #expect(content.rows.count == LanguageCatalog.pickerEntries.count)
    #expect(content.rows.count == 101, "100 languages plus English (UK)")
    #expect(content.heading == String(localized: "ALL LANGUAGES"))
  }

  @Test("search matches the shown name, the native name and the code")
  func searchFields() throws {
    let german = try #require(LanguageCatalog.pickerEntries.first { $0.code == "de" })
    #expect(dictation(query: german.displayName).rows.map(\.id).contains("de"))
    #expect(dictation(query: "Deutsch").rows.map(\.id).contains("de"))
    #expect(dictation(query: "  DE ").rows.map(\.id).contains("de"))
    #expect(dictation(query: "zzzz-no-language").rows.isEmpty)
  }

  @Test("British spelling chosen: the English (UK) row is selected, writes en, and says British")
  func englishUKIdentity() throws {
    let content = dictation(mode: .locked("en"), stored: .british)
    let uk = try #require(content.rows.first { $0.id == "en-gb" })
    let us = try #require(content.rows.first { $0.id == "en" })
    #expect(uk.isSelected)
    #expect(us.isSelected == false)
    #expect(uk.code == "en", "the engine is never handed en-gb")
    #expect(uk.subtitle.contains("colour"))
    #expect(us.subtitle.contains("color"))
  }

  @Test("Auto is selected only on Auto, and choosing it reports nil")
  func autoRow() throws {
    let picks = Picks()
    let onAuto = dictation(mode: .auto, picks: picks)
    let auto = try #require(onAuto.autoRow)
    #expect(auto.isSelected)
    auto.action()
    #expect(picks.chosen == [nil])
    #expect(try #require(dictation(mode: .locked("de")).autoRow).isSelected == false)
  }

  @Test(
    "Recent drops entries older than a day and applies the engine restriction before the cap of five"
  )
  func recentsTTLAndRestrictionBeforeCap() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func used(_ minutesAgo: Double) -> SessionLanguageMemory.UsageEntry {
      .init(count: 1, lastSeen: now.addingTimeInterval(-minutesAgo * 60))
    }
    // Newest first: ja and zh (not lockable here), then six lockable, then one stale.
    let memory = SessionLanguageMemory(usage24h: [
      "ja": used(1), "zh": used(2), "de": used(3), "fr": used(4), "es": used(5),
      "it": used(6), "nl": used(7), "pl": used(8), "pt": used(60 * 25),
    ])
    let data = try JSONEncoder().encode(memory)
    let recents = LanguagePickerContent.dictationRecents(
      memoryData: data, now: now,
      lockableCodes: ["de", "fr", "es", "it", "nl", "pl", "pt", "en"],
      stored: .american, offersEnglishUK: true)
    #expect(recents.map(\.code) == ["de", "fr", "es", "it", "nl"])
    #expect(
      LanguagePickerContent.dictationRecents(
        memoryData: nil, now: now, lockableCodes: nil, stored: .american, offersEnglishUK: true
      ).isEmpty)
  }

  @Test(
    "a recent English follows the chosen spelling, and is plain English where UK is not offered")
  func recentEnglishSpelling() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let data = try JSONEncoder().encode(
      SessionLanguageMemory(usage24h: ["en": .init(count: 1, lastSeen: now)]))
    #expect(
      LanguagePickerContent.dictationRecents(
        memoryData: data, now: now, lockableCodes: nil, stored: .british, offersEnglishUK: true
      ).map(\.code) == ["en-gb"])
    #expect(
      LanguagePickerContent.dictationRecents(
        memoryData: data, now: now, lockableCodes: nil, stored: .british, offersEnglishUK: false
      ).map(\.code) == ["en"])
  }

  @Test("a dictation choice writes the spelling and lock, then reports, then closes")
  func commitOrder() throws {
    let defaults = try #require(TestDefaults.suite("ew.4320.commit.\(UUID().uuidString)"))
    let settings = SettingsManager(defaults: defaults)
    settings.languageMode = .auto
    settings.englishSpelling = .american
    var steps: [String] = []
    LanguagePickerContent.commitDictation(
      LanguageCatalog.englishUK, to: settings,
      track: { from, to, _ in
        steps.append("track \(from)->\(to)")
        #expect(settings.languageMode == .locked("en"), "the lock is applied before it is reported")
        #expect(settings.englishSpelling == .british)
      },
      dismiss: { steps.append("dismiss") })
    #expect(steps.count == 2)
    #expect(steps.last == "dismiss")
    #expect(steps.first?.hasPrefix("track ") == true)
  }

  /// The caller's own state, as EnviousMeet's row models are: observed, so the sheet re-reads it.
  @MainActor @Observable final class CallerLanguage {
    var code = "en-US"
    var picked: [String] = []
  }

  @Test(
    "the real window resolves a caller's content while hosted, follows the caller's live value, and runs only the caller's action"
  )
  func hostedCallerContentIsLiveAndTheCallers() async throws {
    _ = NSApplication.shared
    let defaults = try #require(TestDefaults.suite("ew.4320.custom.\(UUID().uuidString)"))
    let settings = SettingsManager(defaults: defaults)
    settings.languageMode = .locked("de")
    settings.englishSpelling = .american
    let caller = CallerLanguage()
    let built = FastAdmissionReadSignals()
    final class Last { var content: LanguagePickerContent? }
    let last = Last()
    let sheet = LanguageLockSheet { _, _ in
      let code = caller.code
      let row = LanguagePickerRow(
        id: code, code: code, nativeName: code, englishName: code, displayName: code,
        subtitle: code, isSelected: true, accessibilityLabel: code
      ) { caller.picked.append(code) }
      let content = LanguagePickerContent(
        title: "Live Preview language", contextSubtitle: nil, autoRow: nil, recents: [],
        heading: "AVAILABLE FOR LIVE PREVIEW", emptySearchText: "none", rows: [row])
      last.content = content
      built.record(nil)
      return content
    }
    .environment(settings)
    let host = NSHostingView(rootView: sheet.frame(width: 460, height: 560))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 460, height: 560), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = host
    defer { window.contentView = nil }
    host.layoutSubtreeIfNeeded()
    try #require(await built.wait(after: 0), "rendering never asked the caller for content")
    let first = try #require(last.content)
    #expect(first.rows.map(\.code) == ["en-US"])
    #expect(first.title == "Live Preview language")
    #expect(first.autoRow == nil && first.recents.isEmpty, "no Automatic or Recent for a caller")
    #expect(first.rows.first?.isSelected == true)

    let baseline = built.count
    caller.code = "en-GB"
    host.layoutSubtreeIfNeeded()
    try #require(await built.wait(after: baseline), "a caller change did not resolve the content again")
    let second = try #require(last.content)
    #expect(second.rows.map(\.code) == ["en-GB"], "the window must follow the caller, not a frozen copy")

    try #require(second.rows.first).action()
    #expect(caller.picked == ["en-GB"])
    #expect(settings.languageMode == .locked("de"), "a caller choice never writes the dictation language")
    #expect(settings.englishSpelling == .american)
  }
}
