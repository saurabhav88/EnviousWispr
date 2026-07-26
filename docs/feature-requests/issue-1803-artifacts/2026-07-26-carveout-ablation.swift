import AppKit
import Foundation
import NaturalLanguage

// r2 finding 4: the plan ablated the DELETED sibling set but never reported
// "no exceptions" vs "15 exceptions". Run that, per-entry, so each survivor is
// justified by a shipped contract or a measured contribution.
let ck = NSSpellChecker.shared
let st = NSSpellChecker.uniqueSpellDocumentTag()
let englishID =
  ck.availableLanguages.filter {
    $0.replacingOccurrences(of: "_", with: "-").split(separator: "-", maxSplits: 1).first?
      .lowercased() == "en"
  }.sorted().first ?? "en"
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
let fifteen: [String] = [
  "everything", "something", "nothing", "anything", "everyone", "someone", "anyone", "nobody",
  "everybody", "somebody", "none", "yesterday", "today", "tomorrow", "tonight",
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
    !w.contains(where: \.isNumber), !ck.hasLearnedWord(w.lowercased()), dict(w)
  else { return false }
  if carve.contains(w.lowercased()) { return true }
  let l = clip(rawL)
  let s = l + p
  let t = NLTagger(tagSchemes: [.lexicalClass])
  t.string = s
  t.setLanguage(.english, range: s.startIndex..<s.endIndex)
  guard
    let tg = t.tag(at: s.index(s.startIndex, offsetBy: l.count), unit: .word, scheme: .lexicalClass)
      .0, safeTags.contains(tg)
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
  let f = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
  if f.count == 4 {
    pairs.append(Pair(keep: f[1] == "keep", left: String(f[2]), payload: String(f[3])))
  }
}
func run(_ carve: Set<String>) -> (lowered: Int, agree: Int, disagree: Int) {
  var lo = 0
  var dis = 0
  for p in pairs where lowers(p.left, p.payload, carve: carve) {
    lo += 1
    if p.keep { dis += 1 }
  }
  return (lo, lo - dis, dis)
}
let none = run([])
let all15 = run(Set(fifteen))
print("ABLATION on \(pairs.count) characterisation rows")
print("  no exceptions : lowered \(none.lowered)  agree \(none.agree)  disagree \(none.disagree)")
print(
  "  15 exceptions : lowered \(all15.lowered)  agree \(all15.agree)  disagree \(all15.disagree)")
print(
  "  the 15 buy    : +\(all15.agree - none.agree) agreements, +\(all15.disagree - none.disagree) disagreements"
)
print("\nPER-ENTRY contribution (rows this entry alone rescues):")
for w in fifteen {
  let one = run([w])
  let delta = one.agree - none.agree
  let bad = one.disagree - none.disagree
  let note = w == "yesterday" ? "   <- existing shipped contract" : ""
  print("  \(w): +\(delta) agree, +\(bad) disagree\(note)")
}
