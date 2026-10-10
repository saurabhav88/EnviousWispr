import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #3482 PR A: the two engine cards and the selected-engine summary have one owner that the
/// Settings Map will reuse. Expected text, keys and icons are typed from the cards as they
/// shipped before #3482 (SpeechEngineSettingsView at cdd03bf9), not read from the code under
/// test.
@Suite("Engine choice presentation (#3482)", .tags(.driftGuard))
struct EngineChoicePresentationTests {
  typealias Presentation = EngineChoicePresentation

  @Test("engines are Fast then All Languages, and every backend has a card")
  func orderAndLookup() {
    #expect(Presentation.choices.map(\.backend) == [.parakeet, .whisperKit])
    #expect(Presentation.choice(for: .parakeet).backend == .parakeet)
    #expect(Presentation.choice(for: .whisperKit).backend == .whisperKit)
    #expect(Presentation.choices.map(\.icon) == ["bolt.fill", "globe"])
  }

  @Test("each card keeps its shipped English, spec table included")
  func shippedEnglish() {
    func card(_ c: Presentation.Choice) -> [[UInt8]] {
      ([String(localized: c.title), String(localized: c.tagline)]
        + c.specs.flatMap { [String(localized: $0.label), $0.value.resolved] }).map {
          Array($0.utf8)
        }
    }
    let fast = [
      "Fast", "Pick this for everyday English and European dictation.",
      "Model", "Parakeet v3", "Languages", "25 European languages",
      "Runs on", "Apple Neural Engine", "Transcribe time", "Usually ~0.1s after you speak",
    ].map { Array($0.utf8) }
    let all = [
      "All Languages", "Pick this for other languages or the toughest audio.",
      "Model", "Whisper Large v3 Turbo", "Languages", "99+ languages",
      "Runs on", "Apple GPU", "Transcribe time", "Usually 1-2s after you speak",
    ].map { Array($0.utf8) }
    #expect(card(Presentation.choice(for: .parakeet)) == fast)
    #expect(card(Presentation.choice(for: .whisperKit)) == all)
  }

  @Test("titles and taglines keep their catalog keys; model names stay verbatim")
  func keysAndModelNames() {
    #expect(Presentation.choices.map(\.title.key) == ["Fast", "All Languages"])
    #expect(
      Presentation.choices.map(\.tagline.key) == [
        "Pick this for everyday English and European dictation.",
        "Pick this for other languages or the toughest audio.",
      ])
    #expect(Presentation.choices.map(\.model) == ["Parakeet v3", "Whisper Large v3 Turbo"])
    for choice in Presentation.choices {
      guard case .verbatim(let model) = choice.specs.first?.value else {
        Issue.record("the Model row of \(choice.model) is not a verbatim product name")
        continue
      }
      #expect(model == choice.model)
    }
  }

  @Test("the selected-engine summary reads the same choice and its existing short line")
  func summaryCorrespondence() {
    let fast = Presentation.choice(for: .parakeet)
    let all = Presentation.choice(for: .whisperKit)
    #expect(String(localized: fast.summary) == "For everyday English and European dictation")
    #expect(String(localized: all.summary) == "For other languages or the toughest audio")
    #expect(fast.summary.key == "For everyday English and European dictation")
    #expect(all.summary.key == "For other languages or the toughest audio")
  }
}
