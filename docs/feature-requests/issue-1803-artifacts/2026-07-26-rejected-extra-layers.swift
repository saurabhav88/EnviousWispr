import AppKit
import Foundation
import NaturalLanguage
let ck = NSSpellChecker.shared, st = NSSpellChecker.uniqueSpellDocumentTag()
func dict(_ w: String) -> Bool { ck.checkSpelling(of: w.lowercased(), startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: st, wordCount: nil).location == NSNotFound }
let safeTags: Set<NLTag> = [.verb,.adverb,.conjunction,.determiner,.pronoun,.adjective,.preposition,.particle,.interjection,.number]
let safeNouns: Set<String> = ["yesterday","today","tomorrow","tonight","everything","something","nothing","anything","everyone","someone","anyone","nobody","everybody","somebody","none"]
func tag(_ l: String, _ p: String) -> NLTag? {
  let j = l + p; let t = NLTagger(tagSchemes: [.lexicalClass]); t.string = j
  t.setLanguage(.english, range: j.startIndex..<j.endIndex)
  return t.tag(at: j.index(j.startIndex, offsetBy: l.count), unit: .word, scheme: .lexicalClass).0
}
func nameTag(_ l: String, _ p: String) -> Bool {
  let j = l + p; let t = NLTagger(tagSchemes: [.nameType]); t.string = j
  let x = t.tag(at: j.index(j.startIndex, offsetBy: l.count), unit: .word, scheme: .nameType).0
  return x == .personalName || x == .placeName || x == .organizationName
}
func lowered(_ p: String) -> String {
  guard let f = p.first else { return p }
  return String(f).lowercased() + p.dropFirst()
}
func word(_ p: String) -> String { String(p.prefix(while: { !$0.isWhitespace })).trimmingCharacters(in: .punctuationCharacters) }

func base(_ l: String, _ p: String) -> Bool {
  let w = word(p)
  if ["I","I'm","I've","I'll","I'd"].contains(w) { return false }
  guard dict(w) else { return false }
  if safeNouns.contains(w.lowercased()) { return true }
  guard let t = tag(l, p), safeTags.contains(t) else { return false }
  return true
}
// B + nameType veto
func bName(_ l: String, _ p: String) -> Bool { base(l, p) && !nameTag(l, p) }
// B + "does the capital carry meaning?" — tag the same sentence with the first
// word lowercased; if the tag CHANGES, the capital is load-bearing.
func bAgree(_ l: String, _ p: String) -> Bool { base(l, p) && tag(l, p) == tag(l, lowered(p)) }
func bBoth(_ l: String, _ p: String) -> Bool { bAgree(l, p) && !nameTag(l, p) }

let mustKeep: [(String,String)] = [
  ("I mentioned it and ","Mark said he would be late."),("we spoke and ","Grace agreed to help."),
  ("the note said ","Bill has the keys."),("I heard ","Rose is moving out."),
  ("she told me ","Frank called twice."),("he asked whether ","Hope was coming along."),
  ("we agreed ","Sue would handle it."),("the ticket says ","Slack is down again."),
  ("turns out ","Google changed the API."),("apparently ","Apple shipped it early."),
  ("I read that ","Amazon raised prices."),("he said ","Tesla recalled the batch."),
  ("we moved to ","Phoenix last spring."),("she works at ","Oracle now."),
  ("I spoke to ","Amber about the design."),("tell ","Baker we are ready."),
  ("we saw ","Bishop yesterday."),("thank ","Dawn for the notes."),
  ("ask ","Holly to send it."),("tell ","Hunter we moved."),("I saw ","Lily earlier."),
  ("tell ","Nick we are late."),("thank ","Olive for the gift."),("call ","Pearl this evening."),
  ("I saw ","Ruby last night."),("email ","Ted the slides."),("it runs on ","Rust these days."),
  ("built with ","Angular originally."),("we use ","Notion for docs."),
  ("switched to ","Linear for tickets."),("I keep notes in ","Obsidian these days."),
  ("the file is on ","Drive already."),("I can't wait to go to ","Steve's house."),
  ("we are flying to ","Chicago on Friday."),("I met ","Barry at the office."),
  ("hire ","Dean if he is free."),("we flew to ","Austin last week."),("I live near ","Jackson now."),
]
let shouldLower: [(String,String)] = [
  ("I can't wait to go to ","The museum tonight."),("I can't wait to ","Go home and eat dinner."),
  ("remind me to ","Send the invoice today."),("I need to ","Check the logs first."),
  ("we should ","Call them back."),("let me ","Read it again."),("I want to ","Buy the tickets now."),
  ("please ","Open the door."),("I said ","Yesterday was fine."),("he thinks ","Actually it works."),
  ("and ","Because it matters."),("I told him ","The report is ready."),("we were ","Testing now."),
  ("I'm ","Really tired today."),("so ","Okay let's start."),("I'd like to ","Work from home tomorrow."),
  ("we need to ","Plan the release."),("I have to ","Write the summary."),("try to ","Fix it before Friday."),
  ("I'll ","Email you the details."),("let's ","Build it properly."),("we can ","Start on Monday."),
  ("I want to ","Learn that framework."),("time to ","Clean the kitchen."),("going to ","Drive there myself."),
  ("I might ","Sleep in tomorrow."),("we could ","Watch it tonight."),("I should ","Study for the exam."),
  ("help me ","Cook dinner."),("about to ","Run the tests."),("need to ","Pay the invoice."),
  ("he said ","Today is busy."),("we agreed ","Tomorrow works better."),
  ("she said ","Everything is ready."),("I think ","Something went wrong."),
]
func score(_ n: String, _ f: (String,String) -> Bool) {
  let d = mustKeep.filter { f($0.0,$0.1) }, c = shouldLower.filter { f($0.0,$0.1) }
  let p = Double(c.count) / Double(max(c.count + d.count,1)) * 100
  print(String(format: "%-46s cov %2d/%d  DAMAGE %2d/%d  precision %5.1f%%", (n as NSString).utf8String!, c.count, shouldLower.count, d.count, mustKeep.count, p))
  if !d.isEmpty { print("      damage: \(d.map { word($0.1) })") }
  let m = shouldLower.filter { !f($0.0,$0.1) }
  if !m.isEmpty { print("      missed: \(m.map { word($0.1) })") }
}
score("B  dict + POS + safe-nouns", base)
score("B + nameType veto", bName)
score("B + capital-carries-meaning check", bAgree)
score("B + both vetoes", bBoth)
let t0 = DispatchTime.now().uptimeNanoseconds
for _ in 0..<300 { _ = bBoth("I can't wait to go to ", "The museum tonight.") }
print(String(format: "\nfull B+both decision: %.3f ms warm", Double(DispatchTime.now().uptimeNanoseconds-t0)/1_000_000/300))
