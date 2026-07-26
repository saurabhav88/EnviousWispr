import AppKit
import Foundation
import NaturalLanguage

// The heart-path question the grounded review raised: how much does the FIRST
// call cost, in a cold process, when nothing is warmed? That is the cost that
// would land on stop-to-paste.
func ms(_ t0: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000 }

var t = DispatchTime.now().uptimeNanoseconds
let schemes = NLTagger.availableTagSchemes(for: .word, language: .english)
let availabilityProbe = ms(t)

t = DispatchTime.now().uptimeNanoseconds
let langs = NSSpellChecker.shared.availableLanguages
let englishID =
  langs.filter {
    $0.replacingOccurrences(of: "_", with: "-").split(separator: "-", maxSplits: 1).first?
      .lowercased() == "en"
  }.sorted().first ?? "en"
let languageResolve = ms(t)

t = DispatchTime.now().uptimeNanoseconds
let tag = NSSpellChecker.uniqueSpellDocumentTag()
_ = NSSpellChecker.shared.checkSpelling(
  of: "museum", startingAt: 0, language: englishID, wrap: false,
  inSpellDocumentWithTag: tag, wordCount: nil)
let firstSpell = ms(t)

t = DispatchTime.now().uptimeNanoseconds
let j = "can't wait to go to The museum tonight."
let tg = NLTagger(tagSchemes: [.lexicalClass])
tg.string = j
tg.setLanguage(.english, range: j.startIndex..<j.endIndex)
_ = tg.tag(at: j.index(j.startIndex, offsetBy: 20), unit: .word, scheme: .lexicalClass)
let firstTag = ms(t)

t = DispatchTime.now().uptimeNanoseconds
for _ in 0..<200 {
  let tg2 = NLTagger(tagSchemes: [.lexicalClass])
  tg2.string = j
  tg2.setLanguage(.english, range: j.startIndex..<j.endIndex)
  _ = tg2.tag(at: j.index(j.startIndex, offsetBy: 20), unit: .word, scheme: .lexicalClass)
  _ = NSSpellChecker.shared.checkSpelling(
    of: "museum", startingAt: 0, language: englishID, wrap: false,
    inSpellDocumentWithTag: tag, wordCount: nil)
}
let warm = ms(t) / 200

print("COLD PROCESS, first-call costs that would land on stop-to-paste")
print(
  String(
    format: "  availableTagSchemes probe : %7.3f ms  (lexicalClass present: %@)",
    availabilityProbe, schemes.contains(.lexicalClass) ? "yes" : "NO"))
print(
  String(
    format: "  resolve English identifier: %7.3f ms  (chose %@ of %d)",
    languageResolve, englishID, langs.count))
print(String(format: "  FIRST checkSpelling        : %7.3f ms", firstSpell))
print(String(format: "  FIRST tagger decision      : %7.3f ms", firstTag))
print(String(format: "  warm full decision         : %7.3f ms", warm))
print(
  String(
    format: "\n  worst-case cold total      : %7.3f ms",
    availabilityProbe + languageResolve + firstSpell + firstTag))
