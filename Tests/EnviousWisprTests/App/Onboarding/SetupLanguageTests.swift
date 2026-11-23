import EnviousWisprCore
import Testing

@testable import EnviousWisprAppKit

/// #4528 D1 (plan M75): what the Language screen resolves typed text to, and what it starts with.
///
/// **Product Outcome.** When this fails, a person who types their language in their own words is
/// told there is no match, is locked to the wrong language, sees English pre-filled on a Mac the
/// app cannot read, or loses a language they already chose when they come back to the screen.
@Suite(.tags(.productOutcome))
struct SetupLanguageTests {
  private func code(_ input: String) -> String? {
    if case .language(let entry)? = SetupLanguage.match(input) { return entry.code }
    return nil
  }

  @Test(
    "own names, English names, codes, prefixes and small typos resolve to the catalog's language")
  func resolves() {
    let cases: [(String, String)] = [
      ("Deutsch", "de"), ("german", "de"), ("de", "de"), ("Deutch", "de"),
      ("Japanese", "ja"), ("日本語", "ja"), ("Français", "fr"), ("francais", "fr"),
      ("Engl", "en"), ("español", "es"), ("Portugese", "pt"),
    ]
    for (input, expected) in cases {
      #expect(code(input) == expected, "\(input) resolved to \(code(input) ?? "nothing")")
    }
  }

  @Test("blank, too short or unknown text matches nothing and blocks Continue")
  func noMatch() {
    for input in ["", "   ", "x", "zzqx", "Klingon"] {
      #expect(SetupLanguage.match(input) == nil, "\(input) matched")
    }
    #expect(SetupLanguage.showsNoMatch("Klingon"))
    #expect(!SetupLanguage.showsNoMatch("zz"), "the hint must wait for three letters")
  }

  @Test("an existing Auto choice round-trips; a match locks the catalog's code")
  func modes() {
    #expect(SetupLanguage.match("auto") == .automatic)
    #expect(SetupLanguage.match(String(localized: SetupLanguage.automaticLabel)) == .automatic)
    #expect(SetupLanguage.match("Deutsch")?.mode == .locked("de"))
    #expect(SetupLanguage.match("auto")?.mode == .auto)
  }

  @Test("a committed language wins over the Mac's guess; an unknown Mac language starts blank")
  func initialText() {
    let committed = SetupLanguage.initialText(committed: .locked("de"), macCode: "fr")
    #expect(committed.text == "Deutsch" && !committed.guessed)
    let auto = SetupLanguage.initialText(committed: .auto, macCode: "fr")
    #expect(SetupLanguage.match(auto.text) == .automatic && !auto.guessed)
    let guess = SetupLanguage.initialText(committed: nil, macCode: "fr")
    #expect(guess.text == "Français" && guess.guessed)
    #expect(SetupLanguage.initialText(committed: nil, macCode: "xx") == ("", false))
    #expect(SetupLanguage.initialText(committed: nil, macCode: nil) == ("", false))
  }

  @Test("greetings keep their own language and timing; unknown codes greet nobody")
  func greetings() {
    let german = SetupLanguage.greeting(for: "de")
    #expect(german?.text == "Hallo!" && german?.beats == 2 && german?.seconds == 2.2)
    #expect(SetupLanguage.greeting(for: "ja")?.text == "こんにちは！")
    #expect(SetupLanguage.greeting(for: "xx") == nil)
  }

  @Test("the approved alias spellings resolve, and every alias belongs to a catalog language")
  func aliases() {
    for (input, expected) in [
      ("Mandarin", "zh"), ("Farsi", "fa"), ("castellano", "es"), ("nihongo", "ja"),
      ("Bangla", "bn"), ("Filipino", "tl"),
    ] {
      #expect(code(input) == expected, "\(input) resolved to \(code(input) ?? "nothing")")
    }
    let catalog = Set(LanguageCatalog.all.map(\.code))
    #expect(Set(SetupLanguage.aliases.keys).isSubset(of: catalog))
  }
}
