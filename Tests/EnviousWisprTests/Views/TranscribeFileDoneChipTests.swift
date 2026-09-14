import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2817 item 4 — the credit chip on Done says "Polished by X" whenever the polisher cleaned
/// any part; the exception lives on the section that kept its raw words, never on the chip.
///
/// **When this fails, the user reads "Partly polished" for a document that is thirteen good
/// parts and one raw one, or a provider name for a run that polished nothing.** Product
/// coverage.
@Suite("Transcribe a File done chip (#2817)", .tags(.productOutcome))
struct TranscribeFileDoneChipTests {

  @Test("the credit names the provider when any part was polished, and only then")
  func credit() {
    #expect(TranscribeFileView.polishCredit(provider: .egOne, anyPartPolished: true) == "Polished by EG-1")
    #expect(TranscribeFileView.polishCredit(provider: .egOne, anyPartPolished: false) == "No AI polish applied")
    #expect(TranscribeFileView.polishCredit(provider: LLMProvider.none, anyPartPolished: true) == "No AI polish")
    #expect(TranscribeFileView.polishCredit(provider: LLMProvider.none, anyPartPolished: false) == "No AI polish")
    #expect(TranscribeFileView.polishCredit(provider: nil, anyPartPolished: true) == "No AI polish")
    #expect(TranscribeFileView.polishCredit(provider: nil, anyPartPolished: false) == "No AI polish")
  }

  @Test("no provider ever reads Partly: the exception is on the section, not the chip")
  func neverPartly() {
    for provider in LLMProvider.allCases {
      let text = TranscribeFileView.polishCredit(provider: provider, anyPartPolished: true)
      #expect(!text.contains("Partly"), Comment(rawValue: provider.rawValue))
      #expect(text.hasPrefix("Polished by") || text == "No AI polish", Comment(rawValue: provider.rawValue))
    }
  }
}
