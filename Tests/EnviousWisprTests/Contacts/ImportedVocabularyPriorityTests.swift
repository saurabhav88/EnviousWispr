import EnviousWisprCore
import EnviousWisprLLM
import Testing

/// #636 §3.5 — imported names carry a priority that sorts AFTER user-typed terms
/// in the 50-term polish cap, so a large import never crowds out hand-typed
/// vocabulary.
@Suite("Imported vocabulary priority (#636 §3.5)")
struct ImportedVocabularyPriorityTests {
  private func userTerm(_ i: Int) -> CustomWord {
    CustomWord(canonical: "UserTerm\(String(format: "%03d", i))", priority: 0)
  }
  private func importedName(_ i: Int) -> CustomWord {
    CustomWord(
      canonical: "ImportedName\(String(format: "%03d", i))", category: .person, priority: 10)
  }

  @Test("49 user terms + many imported: all user terms reach the polish prompt")
  func userTermsKeepTheirSlots() {
    var words = (0..<49).map(userTerm)
    words += (0..<100).map(importedName)
    let rendered = CustomVocabularyFormatter.render(words) ?? ""
    for i in 0..<49 {
      #expect(rendered.contains("UserTerm\(String(format: "%03d", i))"))
    }
  }

  @Test("51 user terms fill all 50 slots; no imported name reaches the prompt")
  func userTermsCrowdOutImported() {
    var words = (0..<51).map(userTerm)
    words.append(
      CustomWord(canonical: "ImportedNameZZZ", category: .person, priority: 10))
    let rendered = CustomVocabularyFormatter.render(words) ?? ""
    #expect(!rendered.contains("ImportedNameZZZ"))
  }
}
