import AppKit
import EnviousWisprCore
import Foundation
import Observation
import SwiftUI
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit
@testable import EnviousWisprServices

/// #4320: EnviousMeet's two language windows (Live Preview language, Transcript language) and the
/// transcript Auto switch. When these fail, the user is offered a language the meeting engine
/// cannot use, sees the wrong language or region ticked, cannot find a language by its own name,
/// picks a meeting language that quietly changes another language setting, or finds the
/// transcript list still showing the previous engine's languages after switching.
@MainActor
@Suite("EnviousMeet language windows (#4320)", .tags(.productOutcome))
struct MeetingLanguageControlsTests {

  /// Records an observed change of one value (subject-side signal, bounded by the hang net).
  static func onChange(_ read: @escaping @MainActor () -> Void) -> FastAdmissionReadSignals {
    let signal = FastAdmissionReadSignals()
    withObservationTracking {
      read()
    } onChange: {
      Task { @MainActor in signal.record(nil) }
    }
    return signal
  }

  final class Closed { var count = 0 }

  /// The three language settings a meeting language control must keep apart.
  struct Languages: Equatable {
    let dictation: LanguageMode
    let live: String?
    let transcript: LanguageMode
    @MainActor init(_ settings: SettingsManager) {
      dictation = settings.languageMode
      live = settings.meetingLiveWordsLanguage
      transcript = settings.meetingLanguageMode
    }
  }

  // MARK: - Live Preview language

  @Test(
    "the live window lists Apple's exact tags, two regions as two rows, and ticks only the saved one"
  )
  func liveRows() async throws {
    let settings = MeetingLiveWordsChoiceInitializerTests.freshSettings()
    settings.commitMeetingLiveWordsChoice(engine: .apple, language: "en-US")
    let model = MeetingLiveWordsRowModel.renderFixture(
      settings: settings, appleTags: ["de-DE", "en-GB", "en-US"])
    await model.appear()
    try #require(model.selectedEngine == .apple)
    let content = LanguagePickerContent.meetingLive(model: model, query: "") {}
    #expect(Set(content.rows.map(\.code)) == ["de-DE", "en-GB", "en-US"])
    #expect(Set(content.rows.map(\.id)).count == 3, "each region is its own row")
    #expect(content.rows.filter(\.isSelected).map(\.code) == ["en-US"], "only the saved region")
    #expect(content.autoRow == nil && content.recents.isEmpty, "no Automatic, no Recent")
    // Voice Control: the spoken name includes the native name the row shows.
    let german = try #require(content.rows.first { $0.code == "de-DE" })
    #expect(
      german.accessibilityLabel.contains(german.nativeName),
      "\(german.accessibilityLabel) names \(german.nativeName)")
    #expect(
      LanguagePickerContent.meetingLive(model: model, query: "en-gb") {}.rows.map(\.code) == [
        "en-GB"
      ])
    #expect(LanguagePickerContent.meetingLive(model: model, query: "zzzz") {}.rows.isEmpty)
  }

  @Test("the live window finds a Universal language by its own name")
  func liveSearchFindsNativeNames() async throws {
    let settings = MeetingLiveWordsChoiceInitializerTests.freshSettings()
    settings.commitMeetingLiveWordsChoice(engine: .universal, language: "en")
    let model = MeetingLiveWordsRowModel.renderFixture(settings: settings)
    await model.appear()
    try #require(model.selectedEngine == .universal)
    let german = try #require(
      LanguagePickerContent.meetingLive(model: model, query: "") {}.rows.first { $0.code == "de" })
    try #require(
      !german.displayName.lowercased().contains("deutsch"), "the search must reach the native name")
    #expect(
      LanguagePickerContent.meetingLive(model: model, query: "Deutsch") {}.rows.map(\.code) == [
        "de"
      ])
  }

  @Test("a live choice saves only the meeting's live language and closes the window")
  func liveChoiceIsTheMeetings() async throws {
    let settings = MeetingLiveWordsChoiceInitializerTests.freshSettings()
    settings.commitMeetingLiveWordsChoice(engine: .apple, language: "en-US")
    settings.meetingLanguageMode = .locked("fr")
    let model = MeetingLiveWordsRowModel.renderFixture(settings: settings)
    await model.appear()
    let before = Languages(settings)
    let closed = Closed()
    let german = try #require(
      LanguagePickerContent.meetingLive(model: model, query: "") { closed.count += 1 }
        .rows.first { $0.code == "de-DE" })
    let saved = Self.onChange { _ = settings.meetingLiveWordsLanguage }
    german.action()
    try #require(await saved.wait(after: 0), "the live language was never saved")
    #expect(settings.meetingLiveWordsLanguage == "de-DE")
    #expect(closed.count == 1)
    let after = Languages(settings)
    #expect(after.dictation == before.dictation, "dictation's language is untouched")
    #expect(after.transcript == before.transcript, "the transcript language is untouched")
  }

  // MARK: - Transcript language

  @Test(
    "the transcript window lists the engine's languages, ticks the lock, and locks only the transcript"
  )
  func transcriptRows() throws {
    let settings = MeetingLiveWordsChoiceInitializerTests.freshSettings()
    settings.meetingLanguageMode = .locked("de")
    settings.commitMeetingLiveWordsChoice(engine: .universal, language: "de")
    let model = MeetingLiveWordsRowModel.renderFixture(settings: settings)
    let closed = Closed()
    let parakeet = LanguagePickerContent.meetingTranscript(
      model: model, engine: .parakeet, query: ""
    ) {
      closed.count += 1
    }
    let lockable = try #require(LanguageLockOptions.lockableCodes(for: .parakeet))
    #expect(parakeet.rows.count == lockable.count, "one row per language the engine can write")
    #expect(parakeet.rows.allSatisfy { lockable.contains($0.code) })
    #expect(!parakeet.rows.contains { $0.id == LanguageCatalog.englishUK.code }, "no English (UK)")
    #expect(parakeet.rows.filter(\.isSelected).map(\.code) == ["de"])
    #expect(parakeet.autoRow == nil, "the section's switch owns Auto")
    let whisper = LanguagePickerContent.meetingTranscript(model: model, engine: .whisper, query: "")
    {}
    #expect(whisper.rows.count > parakeet.rows.count)

    let before = Languages(settings)
    let french = try #require(parakeet.rows.first { $0.code == "fr" })
    french.action()
    #expect(settings.meetingLanguageMode == .locked("fr"))
    #expect(closed.count == 1)
    let after = Languages(settings)
    #expect(after.dictation == before.dictation, "dictation's language is untouched")
    #expect(after.live == before.live, "the live language is untouched")
  }

  @Test("the Auto switch: on is Auto with Change off; off locks to a language the engine can write")
  func autoSwitch() {
    let settings = MeetingLiveWordsChoiceInitializerTests.freshSettings()
    settings.meetingLanguageMode = .locked("de")
    settings.commitMeetingLiveWordsChoice(engine: .universal, language: "en")
    let model = MeetingLiveWordsRowModel.renderFixture(settings: settings)
    let before = Languages(settings)
    #expect(!MeetingTranscriptLanguageSection.isAuto(model), "Change is on while locked")

    MeetingTranscriptLanguageSection.setAuto(
      true, model: model, engine: .parakeet, systemLanguage: "fr")
    #expect(settings.meetingLanguageMode == .auto)
    #expect(MeetingTranscriptLanguageSection.isAuto(model), "Change is off on Auto")

    MeetingTranscriptLanguageSection.setAuto(
      false, model: model, engine: .parakeet, systemLanguage: "fr")
    #expect(
      settings.meetingLanguageMode == .locked("fr"), "the Mac's language, which Parakeet writes")

    MeetingTranscriptLanguageSection.setAuto(
      true, model: model, engine: .parakeet, systemLanguage: "ja")
    MeetingTranscriptLanguageSection.setAuto(
      false, model: model, engine: .parakeet, systemLanguage: "ja")
    #expect(settings.meetingLanguageMode == .locked("en"), "Parakeet cannot write Japanese")

    let after = Languages(settings)
    #expect(after.dictation == before.dictation && after.live == before.live)
  }

  @Test("the Auto line names the transcript engine's coverage")
  func autoCoverage() {
    #expect(MeetingTranscriptLanguageSection.coverage(.parakeet) == "25 European languages")
    #expect(MeetingTranscriptLanguageSection.coverage(.whisper) == "99+ languages")
  }

  /// Plan §3.3 / §11 item 3: an engine switch that finishes while the window is open re-lists it.
  @Test("the open transcript window follows a Whisper switch that finishes while it is open")
  func transcriptWindowFollowsAPendingSwitch() async throws {
    _ = NSApplication.shared
    let settings = MeetingLiveWordsChoiceInitializerTests.freshSettings()
    final class Gate {
      let parked = FastAdmissionReadSignals()
      var reply: CheckedContinuation<WhisperSetupState, Never>?
    }
    let gate = Gate()
    let setup = WhisperSetupService(
      engineMutationScope: .alwaysAllowedForTesting,
      readAvailability: {
        await withCheckedContinuation { continuation in
          gate.reply = continuation
          gate.parked.record(nil)
        }
      })
    let engine = MeetingTranscriptEngineRowModel(
      environment: .init(settings: settings, whisperSetup: setup, isMeetingActive: { false }))
    let live = MeetingLiveWordsRowModel.renderFixture(settings: settings)
    let built = FastAdmissionReadSignals()
    final class Last { var rows = 0 }
    let last = Last()
    let sheet = LanguageLockSheet { query, dismiss in
      let content = LanguagePickerContent.meetingTranscript(
        model: live, engine: engine.selectedEngine, query: query, dismiss: dismiss)
      last.rows = content.rows.count
      built.record(nil)
      return content
    }
    .environment(settings)
    let host = NSHostingView(rootView: sheet.frame(width: 460, height: 560))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 460, height: 560), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = host
    defer {
      gate.reply?.resume(returning: .notDownloaded)
      window.contentView = nil
    }
    host.layoutSubtreeIfNeeded()
    try #require(await built.wait(after: 0), "the window never rendered")
    let parakeetRows = try #require(LanguageLockOptions.lockableCodes(for: .parakeet)).count
    #expect(last.rows == parakeetRows)

    let switching = Task { await engine.select(.whisper) }
    try #require(await gate.parked.wait(after: 0), "the Whisper readiness read never parked")
    let baseline = built.count
    gate.reply?.resume(returning: .ready)
    gate.reply = nil
    await switching.value
    #expect(settings.meetingTranscriptEngine == .whisper)
    host.layoutSubtreeIfNeeded()
    try #require(await built.wait(after: baseline), "the open window did not re-list")
    #expect(last.rows > parakeetRows, "the window lists Whisper's languages now")
  }
}
