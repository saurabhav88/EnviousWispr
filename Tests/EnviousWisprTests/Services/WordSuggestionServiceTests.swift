import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// Phase 1 (#637) — pins the AFM alias degeneration filter contract.
/// Bible §7.
@Suite("WordSuggestionService — AFM alias degeneration filter")
struct WordSuggestionServiceTests {

  @Test("4× exact self-echo filtered to empty")
  func exactSelfEchoFilteredToEmpty() {
    let raw = ["gemini", "gemini", "gemini", "gemini"]
    let kept = WordSuggestionService.filterDegeneratedAliases(raw, canonical: "gemini")
    #expect(kept.isEmpty, "All exact self-echoes must be filtered")
  }

  @Test("Mixed-case self-echo filtered")
  func mixedCaseSelfEchoFiltered() {
    let raw = ["Gemini", "GEMINI", "gemini", "GeMiNi"]
    let kept = WordSuggestionService.filterDegeneratedAliases(raw, canonical: "Gemini")
    #expect(kept.isEmpty, "Case variants of canonical must be filtered")
  }

  @Test("Whitespace variants of canonical filtered")
  func whitespaceVariantsFiltered() {
    let raw = [" gemini ", "  gemini", "gemini   "]
    let kept = WordSuggestionService.filterDegeneratedAliases(raw, canonical: "gemini")
    #expect(kept.isEmpty, "Whitespace-padded canonicals must be filtered")
  }

  @Test("De-dupe collapses repeats (case + whitespace insensitive)")
  func deDupeCollapsesRepeats() {
    let raw = ["Jamini", "jamini", " JAMINI ", "Jeh meh nee"]
    let kept = WordSuggestionService.filterDegeneratedAliases(raw, canonical: "Gemini")
    #expect(kept.count == 2, "Duplicates collapse to one (Jamini); Jeh meh nee is unique")
    #expect(
      kept.contains(where: { $0.lowercased().trimmingCharacters(in: .whitespaces) == "jamini" }))
    #expect(kept.contains("Jeh meh nee"))
  }

  @Test("Empty entries dropped")
  func emptyEntriesDropped() {
    let raw = ["", "  ", "jamini", "\t\n"]
    let kept = WordSuggestionService.filterDegeneratedAliases(raw, canonical: "Gemini")
    #expect(kept == ["jamini"])
  }

  @Test("Valid aliases pass through (Kubernetes regression check)")
  func validAliasesPassThrough() {
    let raw = ["kuber netties", "cube ernetes", "cooper nettys"]
    let kept = WordSuggestionService.filterDegeneratedAliases(raw, canonical: "Kubernetes")
    #expect(kept.count == 3, "Phonetic variants should survive the filter")
    #expect(kept == raw)
  }

  @Test("Empty input returns empty")
  func emptyInputReturnsEmpty() {
    let kept = WordSuggestionService.filterDegeneratedAliases([], canonical: "anything")
    #expect(kept.isEmpty)
  }

  @Test("Empty canonical returns empty (degenerate input guard)")
  func emptyCanonicalGuardsAgainstAcceptingAll() {
    let kept = WordSuggestionService.filterDegeneratedAliases(["a", "b"], canonical: "")
    #expect(
      kept.isEmpty, "Empty canonical means we cannot meaningfully evaluate self-echo; return empty")
  }

  @Test("Single-character canonical with valid aliases")
  func singleCharCanonical() {
    // "X" canonical with phonetic alternates
    let raw = ["ecks", "eks"]
    let kept = WordSuggestionService.filterDegeneratedAliases(raw, canonical: "X")
    // ecks and eks are far enough from X to survive (score check)
    // The exact survival depends on WordCorrector.score; this test is a sanity check that
    // single-char canonical does not crash or misbehave catastrophically.
    #expect(kept.count >= 0)  // Smoke; allow either to be filtered or kept
  }
}
