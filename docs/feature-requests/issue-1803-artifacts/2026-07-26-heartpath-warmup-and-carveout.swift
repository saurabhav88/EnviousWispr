import AppKit
import Foundation
import NaturalLanguage

// Two questions:
//  1. If the availability probe and language resolution happen ONCE at startup,
//     what is actually left on the first paste?
//  2. Does the reduced carve-out (closed interjection/politeness class only,
//     with the six open-class nouns the reviewer flagged removed) still work?
func ms(_ t0: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000 }

// ---- startup warm-up, off the paste path -----------------------------------
var t = DispatchTime.now().uptimeNanoseconds
let schemes = NLTagger.availableTagSchemes(for: .word, language: .english)
let langs = NSSpellChecker.shared.availableLanguages
let englishID =
  langs.filter {
    $0.replacingOccurrences(of: "_", with: "-").split(separator: "-", maxSplits: 1).first?
      .lowercased() == "en"
  }.sorted().first ?? "en"
let tag = NSSpellChecker.uniqueSpellDocumentTag()
// Prime both services with one throwaway decision.
_ = NSSpellChecker.shared.checkSpelling(
  of: "warm", startingAt: 0, language: englishID, wrap: false,
  inSpellDocumentWithTag: tag, wordCount: nil)
let primer = NLTagger(tagSchemes: [.lexicalClass])
primer.string = "we were warming the tagger up."
primer.setLanguage(.english, range: primer.string!.startIndex..<primer.string!.endIndex)
_ = primer.tag(at: primer.string!.startIndex, unit: .word, scheme: .lexicalClass)
let warmupCost = ms(t)

// ---- what is left on the first real paste ----------------------------------
t = DispatchTime.now().uptimeNanoseconds
let j = "can't wait to go to The museum tonight."
let tg = NLTagger(tagSchemes: [.lexicalClass])
tg.string = j
tg.setLanguage(.english, range: j.startIndex..<j.endIndex)
_ = tg.tag(at: j.index(j.startIndex, offsetBy: 20), unit: .word, scheme: .lexicalClass)
_ = NSSpellChecker.shared.checkSpelling(
  of: "the", startingAt: 0, language: englishID, wrap: false,
  inSpellDocumentWithTag: tag, wordCount: nil)
let firstPasteAfterWarmup = ms(t)

print("HEART-PATH COST WITH A STARTUP WARM-UP")
print(
  String(
    format: "  warm-up, once, off the paste path : %7.3f ms  (lexicalClass: %@, chose %@)",
    warmupCost, schemes.contains(.lexicalClass) ? "yes" : "NO", englishID))
print(String(format: "  FIRST paste after warm-up         : %7.3f ms", firstPasteAfterWarmup))
print("  (unwarmed first paste was measured at 105.590 ms)")

// ---- reduced carve-out ------------------------------------------------------
let safeTags: Set<NLTag> = [
  .verb, .adverb, .conjunction, .determiner, .pronoun, .adjective, .preposition, .particle,
  .interjection, .number,
]
let bounded: Set<String> = [
  "yesterday", "today", "tomorrow", "tonight", "everything", "something", "nothing", "anything",
  "everyone", "someone", "anyone", "nobody", "everybody", "somebody", "none",
]
// Closed class: greetings, acknowledgements, politeness formulae. The six
// OPEN-class nouns (question, answer, note, reminder, update, example) are
// removed — the grounded review was right that those are a vocabulary guess.
let interjections: Set<String> = [
  "hey", "hello", "hi", "yep", "yup", "yeah", "yes", "nope", "okay", "ok",
  "thanks", "thank", "please", "sorry", "sure", "welcome", "goodbye", "bye",
]
func word(_ p: String) -> String {
  String(p.prefix(while: { !$0.isWhitespace })).trimmingCharacters(in: .punctuationCharacters)
}
func clip(_ l: String) -> String {
  let u = Array(l.utf16)
  return u.count > 20 ? String(decoding: u.suffix(20), as: UTF16.self) : l
}
func lowers(_ rawL: String, _ p: String, carve: Set<String>) -> Bool {
  let w = word(p)
  if ["I", "I'm", "I've", "I'll", "I'd"].contains(w) { return false }
  guard let f = w.first, f.isUppercase, !w.dropFirst().contains(where: \.isUppercase),
    !w.contains(where: \.isNumber), !NSSpellChecker.shared.hasLearnedWord(w.lowercased())
  else { return false }
  guard
    NSSpellChecker.shared.checkSpelling(
      of: w.lowercased(), startingAt: 0, language: englishID, wrap: false,
      inSpellDocumentWithTag: tag, wordCount: nil
    ).location == NSNotFound
  else { return false }
  if carve.contains(w.lowercased()) { return true }
  let l = clip(rawL)
  let s = l + p
  let t2 = NLTagger(tagSchemes: [.lexicalClass])
  t2.string = s
  t2.setLanguage(.english, range: s.startIndex..<s.endIndex)
  guard
    let tg2 = t2.tag(
      at: s.index(s.startIndex, offsetBy: l.count), unit: .word, scheme: .lexicalClass
    )
    .0, safeTags.contains(tg2)
  else { return false }
  return true
}
struct Pair {
  let keep: Bool
  let left: String
  let payload: String
}
var pairs: [Pair] = []
for line
  in (try! String(
    contentsOfFile:
      "/private/tmp/claude-501/-Users-m4pro-sv-Developer-EnviousLabs-EnviousWispr/ff88b620-7ce1-43d3-99d0-8dc68323ee9e/scratchpad/pairs.tsv",
    encoding: .utf8)).split(separator: "\n")
{
  let f = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
  if f.count == 3 {
    pairs.append(Pair(keep: f[0] == "keep", left: String(f[1]), payload: String(f[2])))
  }
}
let shouldLower = pairs.filter { !$0.keep }.count
print("\nCARVE-OUT VARIANTS on the \(pairs.count)-pair characterisation corpus")
for (name, carve) in [
  ("bounded 15 only          ", bounded),
  ("+ closed interjections   ", bounded.union(interjections)),
] {
  var lowered = 0
  var damage = 0
  for p in pairs where lowers(p.left, p.payload, carve: carve) {
    lowered += 1
    if p.keep { damage += 1 }
  }
  let correct = lowered - damage
  print(
    "  " + name + " lowered \(lowered)  agree \(correct)  disagree \(damage)  recall "
      + String(format: "%.1f%%", Double(correct) / Double(shouldLower) * 100))
}
