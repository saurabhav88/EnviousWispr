import AppKit
import Foundation
import NaturalLanguage
let ck = NSSpellChecker.shared, st = NSSpellChecker.uniqueSpellDocumentTag()
func dict(_ w: String) -> Bool { ck.checkSpelling(of: w.lowercased(), startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: st, wordCount: nil).location == NSNotFound }
let safeTags: Set<NLTag> = [.verb,.adverb,.conjunction,.determiner,.pronoun,.adjective,.preposition,.particle,.interjection,.number]
let safeNouns: Set<String> = ["yesterday","today","tomorrow","tonight","everything","something","nothing","anything","everyone","someone","anyone","nobody","everybody","somebody","none"]
func clip(_ l: String) -> String { let u = Array(l.utf16); return u.count > 20 ? String(decoding: u.suffix(20), as: UTF16.self) : l }
func word(_ p: String) -> String { String(p.prefix(while: { !$0.isWhitespace })).trimmingCharacters(in: .punctuationCharacters) }
func decide(_ rawL: String, _ p: String) -> (lower: Bool, pos: String, name: String) {
  let l = clip(rawL), w = word(p)
  let j = l + p
  let t = NLTagger(tagSchemes: [.lexicalClass]); t.string = j
  t.setLanguage(.english, range: j.startIndex..<j.endIndex)
  let pos = t.tag(at: j.index(j.startIndex, offsetBy: l.count), unit: .word, scheme: .lexicalClass).0
  let n = NLTagger(tagSchemes: [.nameType]); n.string = j
  let nm = n.tag(at: j.index(j.startIndex, offsetBy: l.count), unit: .word, scheme: .nameType).0
  var lower = false
  if !["I","I'm","I've","I'll","I'd"].contains(w), dict(w) {
    if safeNouns.contains(w.lowercased()) { lower = true }
    else if let pos, safeTags.contains(pos) { lower = true }
  }
  return (lower, pos?.rawValue ?? "nil", nm?.rawValue ?? "nil")
}
print("THE FOUR AMBIGUOUS PAIRS — the hardest cases in the proposed dataset\n")
let cases: [(String,String,String,Bool)] = [
  ("EN_05","I am eating an ","Apple for snack.", true),          // want lowercase
  ("EN_06","I am visiting the ","Apple store downtown.", false), // want capital
  ("EN_07","Please pay the ","Bill tomorrow morning.", true),    // want lowercase
  ("EN_08","Please call ","Bill tomorrow morning.", false),      // want capital
  ("EN_02","We are going to meet with ","Steve at the office.", false),
  ("EN_03","I am flying out to ","Chicago on Friday.", false),
  ("EN_04","They just bought shares in ","Microsoft yesterday.", false),
  ("EN_11","Send the request to the ","API endpoint.", false),
  ("EN_15","We spent the whole afternoon ","Running in the park.", true),
  ("EN_01","I can't wait to go to ","The museum tonight.", true),
]
var right = 0
for (id, l, p, wantLower) in cases {
  let d = decide(l, p)
  let ok = d.lower == wantLower
  if ok { right += 1 }
  print("\(ok ? "PASS" : "FAIL") \(id)  \"\(word(p))\"  pos=\(d.pos) name=\(d.name)  lowercased=\(d.lower) want=\(wantLower)")
}
print("\n\(right)/\(cases.count) correct")
