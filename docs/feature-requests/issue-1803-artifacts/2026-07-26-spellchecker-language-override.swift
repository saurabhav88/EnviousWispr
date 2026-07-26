import AppKit
import Foundation
let ck = NSSpellChecker.shared
let tag = NSSpellChecker.uniqueSpellDocumentTag()
func ask(_ w: String, _ lang: String) -> Bool {
  ck.checkSpelling(of: w, startingAt: 0, language: lang, wrap: false,
                   inSpellDocumentWithTag: tag, wordCount: nil).location == NSNotFound
}
print("user's current checker language: \(ck.language())")
// Does an EXPLICIT language argument survive the user having selected another one?
for userLang in ["de", "fr", "en"] {
  let ok = ck.setLanguage(userLang)
  print("\nset user language -> \(userLang) (accepted: \(ok)), now reports: \(ck.language())")
  print("  ask 'yesterday' with explicit \"en\": \(ask("yesterday", "en"))")
  print("  ask 'museum'    with explicit \"en\": \(ask("museum", "en"))")
  print("  ask 'qwertyuiopzxcv' with explicit \"en\": \(ask("qwertyuiopzxcv", "en"))  <- canary, must be false")
  print("  ask 'yesterday' with nil/empty (user pref): \(ask("yesterday", ""))")
}
// Restore something sane.
_ = ck.setLanguage("en")
print("\nrestored to: \(ck.language())")
print("availableLanguages: \(ck.availableLanguages.filter { $0.hasPrefix("en") })")
