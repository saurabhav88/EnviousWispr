import AppKit
import Foundation
import NaturalLanguage

let ck = NSSpellChecker.shared
let st = NSSpellChecker.uniqueSpellDocumentTag()

// Resolve English deterministically; never the user's selected language, never nil.
let englishID: String? = ck.availableLanguages
  .filter {
    $0.replacingOccurrences(of: "_", with: "-").split(separator: "-", maxSplits: 1).first?
      .lowercased() == "en"
  }
  .sorted().first
guard let englishID else { fatalError("no English dictionary") }

func dict(_ w: String) -> Bool {
  ck.checkSpelling(
    of: w.lowercased(), startingAt: 0, language: englishID, wrap: false,
    inSpellDocumentWithTag: st, wordCount: nil
  ).location == NSNotFound
}
let safeTags: Set<NLTag> = [
  .verb, .adverb, .conjunction, .determiner, .pronoun, .adjective, .preposition, .particle,
  .interjection, .number,
]
// THE SHIPPED SET: 12 frozen compatibility exceptions. An earlier version of
// this file carried the REJECTED 39-word set (these 12 plus `nobody`,
// `somebody`, `none`, 18 greetings and 6 open-class nouns), so the headline
// table it produced described a design that is not being shipped. Caught by
// grounded review r4, 2026-07-26.
let safeNouns: Set<String> = [
  "yesterday", "today", "tomorrow", "tonight", "everything", "something", "nothing", "anything",
  "everyone", "someone", "anyone", "everybody",
]
func word(_ p: String) -> String {
  String(p.prefix(while: { !$0.isWhitespace })).trimmingCharacters(in: .punctuationCharacters)
}
func clip(_ l: String) -> String {
  let u = Array(l.utf16)
  return u.count > 20 ? String(decoding: u.suffix(20), as: UTF16.self) : l
}
func oracle(_ rawL: String, _ p: String, refuseLearned: Bool) -> Bool {
  let w = word(p)
  if ["I", "I'm", "I've", "I'll", "I'd"].contains(w) { return false }
  guard let f = w.first, f.isUppercase, !w.dropFirst().contains(where: \.isUppercase),
    !w.contains(where: \.isNumber)
  else { return false }
  if refuseLearned, ck.hasLearnedWord(w.lowercased()) { return false }
  guard dict(w) else { return false }
  if safeNouns.contains(w.lowercased()) { return true }
  let l = clip(rawL)
  let j = l + p
  let t = NLTagger(tagSchemes: [.lexicalClass])
  t.string = j
  t.setLanguage(.english, range: j.startIndex..<j.endIndex)
  guard
    let tag = t.tag(
      at: j.index(j.startIndex, offsetBy: l.count), unit: .word, scheme: .lexicalClass
    )
    .0, safeTags.contains(tag)
  else { return false }
  return true
}
let list = Set(
  (try! String(
    contentsOfFile: "Sources/EnviousWisprPostProcessing/Resources/ordinary-lowercase-words.txt",
    encoding: .utf8))
    .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty && !$0.hasPrefix("#") })
func listSays(_ p: String) -> Bool {
  let w = word(p)
  if ["I", "I'm", "I've", "I'll", "I'd"].contains(w) { return false }
  return list.contains(w.lowercased().replacingOccurrences(of: "\u{2019}", with: "'"))
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
  let f = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
  if f.count == 4 {
    pairs.append(Pair(keep: f[1] == "keep", left: String(f[2]), payload: String(f[3])))
  }
}
func score(_ name: String, _ decide: (String, String) -> Bool) {
  var lowered = 0
  var damage = 0
  var missed = 0
  var damagedWords: [String: Int] = [:]
  for p in pairs {
    let d = decide(p.left, p.payload)
    if d {
      lowered += 1
      if p.keep {
        damage += 1
        damagedWords[word(p.payload), default: 0] += 1
      }
    } else if !p.keep {
      missed += 1
    }
  }
  let correct = lowered - damage
  let precision = Double(correct) / Double(max(lowered, 1)) * 100
  let recall = Double(correct) / Double(pairs.filter { !$0.keep }.count) * 100
  print(name)
  print("   lowercased \(lowered)  correct \(correct)  DAMAGE \(damage)")
  print(
    "   precision " + String(format: "%.2f%%", precision) + "   recall "
      + String(format: "%.1f%%", recall))
  let top = damagedWords.sorted { $0.value > $1.value }.prefix(15).map { "\($0.key)(\($0.value))" }
  if !top.isEmpty { print("   most-damaged words: \(top.joined(separator: " "))") }
}
print(
  "REAL LABELLED CONTINUATION PAIRS: \(pairs.count) (\(pairs.filter(\.keep).count) must-keep)\n")
print("English dictionary selected: \(englishID)\n")
score("A — shipped 799-word list (today)") { _, p in listSays(p) }
print("")
score("B — system dictionary + word type + carve-outs") { l, p in oracle(l, p, refuseLearned: false)
}
print("")
score("C — B, plus refusing macOS learned words") { l, p in oracle(l, p, refuseLearned: true) }
