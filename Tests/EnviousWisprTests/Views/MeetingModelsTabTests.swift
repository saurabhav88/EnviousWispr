import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #4287 PR 2: the EnviousMeet Models tab's engine cards.
///
/// When these fail, the user can pick Apple's transcript engine before it exists, pick Whisper
/// before it is downloaded, or reads a card whose model, size or languages differ from the
/// dictation Engine card for the same model.
@MainActor
@Suite("EnviousMeet Models tab engine cards (#4287)", .tags(.productOutcome))
struct MeetingModelsTabTests {
  @Test("the Transcript engine cards are Parakeet, Whisper and Apple, in that order")
  func transcriptOrder() {
    #expect(
      MeetingTranscriptEngineCards.order == [
        .engine(.parakeet), .engine(.whisper), .appleComingSoon,
      ])
    #expect(
      MeetingTranscriptEngineCards.order.map(\.mapID)
        == [
          .meetingTranscriptEngineParakeet, .meetingTranscriptEngineWhisper,
          .meetingTranscriptEngineApple,
        ])
  }

  @Test("Apple says Coming soon and can never be picked; Whisper only once it is downloaded")
  func transcriptSelectability() {
    for ready in [false, true] {
      #expect(!MeetingTranscriptEngineCards.isSelectable(.appleComingSoon, whisperReady: ready))
      #expect(
        MeetingTranscriptEngineCards.unavailability(.appleComingSoon, whisperReady: ready)
          == String(localized: MeetingsCopy.engineComingSoon))
      #expect(MeetingTranscriptEngineCards.isSelectable(.engine(.parakeet), whisperReady: ready))
      #expect(
        MeetingTranscriptEngineCards.unavailability(.engine(.parakeet), whisperReady: ready) == nil)
    }
    #expect(!MeetingTranscriptEngineCards.isSelectable(.engine(.whisper), whisperReady: false))
    #expect(
      MeetingTranscriptEngineCards.unavailability(.engine(.whisper), whisperReady: false)
        == String(localized: MeetingsCopy.whisperNotDownloaded))
    #expect(MeetingTranscriptEngineCards.isSelectable(.engine(.whisper), whisperReady: true))
    #expect(
      MeetingTranscriptEngineCards.unavailability(.engine(.whisper), whisperReady: true) == nil)
  }

  @Test("the spec tables match dictation's Engine cards for the same model, without times")
  func specsMatchDictation() {
    func rows(_ choice: EngineChoicePresentation.Choice) -> [String] {
      choice.specs.map { String(localized: $0.label) + "=" + $0.value.resolved }
    }
    func cardRows(_ item: MeetingTranscriptEngineCards.Item, _ model: String) -> [String] {
      MeetingTranscriptEngineCards.specs(item, parakeetModel: model).map {
        $0.label + "=" + $0.value
      }
    }
    for model in [ParakeetModel.v3.displayName, ParakeetModel.ultra.displayName] {
      #expect(
        cardRows(.engine(.parakeet), model)
          == rows(EngineChoicePresentation.fast(parakeetModel: model)), "\(model)")
    }
    #expect(cardRows(.engine(.whisper), "") == rows(EngineChoicePresentation.allLanguages))
    #expect(cardRows(.appleComingSoon, "").isEmpty)
  }

  @Test("the Transcript engine cards' map titles are the names the cards show")
  func transcriptTitles() {
    for item in MeetingTranscriptEngineCards.order {
      #expect(SettingsMapRef.id(item.mapID).title == MeetingTranscriptEngineCards.title(item))
    }
  }

  @Test("the Live words cards' map titles are the names the cards show")
  func liveWordsTitles() {
    for engine in MeetingLiveWordsEngineCards.order {
      #expect(
        SettingsMapRef.id(engine.meetingLiveWordsMapID).title
          == MeetingLiveWordsEngineCards.title(engine))
    }
  }
}
