import EnviousWisprCore
import Testing

@testable import EnviousWisprAppKit

/// #4528 D2 (plan M76): which speech engine Setup shows and commits, and the facts it shows.
///
/// **Product Outcome.** When this fails, a Japanese speaker is offered Parakeet, the button says
/// one engine and installs another, the card names one Parakeet model with the other's size,
/// or a comparison click becomes a choice.
@Suite(.tags(.productOutcome))
struct SetupSpeechTests {
  @Test("language support comes from the lock options: Japanese rules Parakeet out, German and Auto do not")
  func support() {
    #expect(!SetupSpeech.supports(.parakeet, .locked("ja")))
    #expect(SetupSpeech.supports(.whisper, .locked("ja")))
    #expect(SetupSpeech.supports(.parakeet, .locked("de")))
    #expect(SetupSpeech.supports(.parakeet, .auto) && SetupSpeech.supports(.parakeet, nil))
  }

  @Test("the shown engine: a compatible pending pick, then a compatible committed pick, then the advice")
  func displayedPrecedence() {
    #expect(
      SetupSpeech.displayed(
        draft: .whisper, committed: .parakeet, recommended: .parakeet, language: .locked("de"))
        == .whisper)
    #expect(
      SetupSpeech.displayed(
        draft: nil, committed: .whisper, recommended: .parakeet, language: .locked("de"))
        == .whisper)
    #expect(
      SetupSpeech.displayed(draft: nil, committed: nil, recommended: .parakeet, language: nil)
        == .parakeet)
    // An incompatible pending or committed pick is never shown, so it can never be committed.
    #expect(
      SetupSpeech.displayed(
        draft: .parakeet, committed: .parakeet, recommended: .whisper, language: .locked("ja"))
        == .whisper)
  }

  @Test("the card's size belongs to the model it names")
  func sizesFollowTheNamedModel() {
    let v3 = ParakeetModel.v3.displayName
    let ultra = ParakeetModel.ultra.displayName
    #expect(SetupSpeech.downloadBytes(.parakeet, parakeetModel: v3) == ParakeetModel.v3ShippedBytes)
    #expect(
      SetupSpeech.downloadBytes(.parakeet, parakeetModel: ultra)
        == EngineChoicePresentation.parakeetUltraDownloadBytes)
    #expect(
      SetupSpeech.downloadBytes(.whisper, parakeetModel: v3)
        == EngineChoicePresentation.whisperDownloadBytes)
    #expect(SetupSpeech.name(.parakeet, parakeetModel: v3) == v3)
  }

  @Test("Whisper greets in the chosen language first, then the tour, without repeats")
  func worldGreetings() {
    let german = SetupSpeech.worldGreetings(for: .locked("de")).map(\.text)
    #expect(german.first == "Hallo!" && german.count == 8)
    let english = SetupSpeech.worldGreetings(for: .locked("en")).map(\.text)
    #expect(english.first == "Hello!" && english.count == 7)
  }

  @Test("Reduce Motion stops Whisper's greeting tour and turning it off restarts it on the same screen")
  @MainActor
  func greetingTourFollowsReduceMotion() async {
    let tour = SetupGreetingTour(interval: .milliseconds(20))
    // Motion on: the tour advances.
    let moving = Task { await tour.run(engine: .whisper, reduceMotion: false) }
    #expect(await waitUntil { tour.index >= 2 }, "the tour never advanced with motion allowed")
    // Reduce Motion turned on: the screen's task restarts with the new key; the tour stops.
    moving.cancel()
    await tour.run(engine: .whisper, reduceMotion: true)
    // `run` returned at once and nothing else drives the tour, so it stays on the first greeting.
    #expect(tour.index == 0, "the tour kept moving under Reduce Motion")
    // Turned off again: it starts over and advances.
    let again = Task { await tour.run(engine: .whisper, reduceMotion: false) }
    #expect(await waitUntil { tour.index >= 1 }, "the tour did not restart when motion came back")
    again.cancel()
    // Parakeet never tours.
    await tour.run(engine: .parakeet, reduceMotion: false)
    #expect(tour.index == 0)
  }
}
