import AppKit
import Foundation
import NaturalLanguage

// Re-score the characterisation corpus with the caret sitting DIRECTLY after a
// word — the case every prior corpus structurally excluded, and the one the
// fused-token defect lived in. Reproduces the shipped decision including the
// separator fix, so this measures what actually ships.
let ck = NSSpellChecker.shared
let st = NSSpellChecker.uniqueSpellDocumentTag()
let english =
  ck.availableLanguages.filter {
    $0.replacingOccurrences(of: "_", with: "-").split(separator: "-", maxSplits: 1).first?
      .lowercased() == "en"
  }.sorted().first ?? "en"
let sentinel = "zqx\(UInt32.random(in: 100_000...999_999))vkj"
func spelled(_ w: String) -> Bool {
  ck.checkSpelling(
    of: w, startingAt: 0, language: english, wrap: false,
    inSpellDocumentWithTag: st, wordCount: nil
  ).location == NSNotFound
}
func dict(_ w: String) -> Bool {
  guard spelled(w.lowercased()) else { return false }
  return !spelled(sentinel)
}
let safeTags: Set<NLTag> = [
  .verb, .adverb, .conjunction, .determiner, .pronoun, .adjective, .preposition, .particle,
  .interjection, .number,
]
let exceptions: Set<String> = [
  "everything", "something", "nothing", "anything", "everyone", "someone", "anyone", "everybody",
  "yesterday", "today", "tomorrow", "tonight",
]
func word(_ p: String) -> String {
  String(p.prefix(while: { !$0.isWhitespace })).trimmingCharacters(in: .punctuationCharacters)
}
func clip(_ l: String) -> String {
  let u = Array(l.utf16)
  return u.count > 20 ? String(decoding: u.suffix(20), as: UTF16.self) : l
}
/// `separator: true` reproduces the SHIPPED behaviour (Rule 1 inserts a space
/// and the tagger is given it). `false` reproduces the defect.
func lowers(_ rawLeft: String, _ p: String, separator: Bool) -> Bool {
  let w = word(p)
  if ["I", "I'm", "I've", "I'll", "I'd"].contains(w) { return false }
  guard let f = w.first, f.isUppercase, !w.dropFirst().contains(where: \.isUppercase),
    !w.contains(where: \.isNumber), !ck.hasLearnedWord(w.lowercased()), dict(w)
  else { return false }
  if exceptions.contains(w.lowercased()) { return true }
  let l = clip(rawLeft) + (separator ? " " : "")
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
      "/private/tmp/claude-501/-Users-m4pro-sv-Developer-EnviousLabs-EnviousWispr/ff88b620-7ce1-43d3-99d0-8dc68323ee9e/scratchpad/pairs_nospace.tsv",
    encoding: .utf8)).split(separator: "\n")
{
  let f = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
  if f.count == 4 {
    pairs.append(Pair(keep: f[1] == "keep", left: String(f[2]), payload: String(f[3])))
  }
}
let shouldLower = pairs.filter { !$0.keep }.count
for separator in [false, true] {
  var lowered = 0
  var disagree = 0
  for p in pairs where lowers(p.left, p.payload, separator: separator) {
    lowered += 1
    if p.keep { disagree += 1 }
  }
  let label = separator ? "SHIPPED (separator given)" : "DEFECT  (fused token)   "
  print(
    "  \(label)  lowered \(lowered)  agree \(lowered - disagree)  DISAGREE \(disagree)  recall "
      + String(format: "%.1f%%", Double(lowered - disagree) / Double(shouldLower) * 100))
}
print("\n  rows: \(pairs.count), of which \(pairs.count - shouldLower) carry a stored capital")
