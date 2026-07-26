import AppKit
import Foundation
import NaturalLanguage
let ck = NSSpellChecker.shared, st = NSSpellChecker.uniqueSpellDocumentTag()
func dict(_ w: String) -> Bool { ck.checkSpelling(of: w.lowercased(), startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: st, wordCount: nil).location == NSNotFound }
let safeTags: Set<NLTag> = [.verb,.adverb,.conjunction,.determiner,.pronoun,.adjective,.preposition,.particle,.interjection,.number]
let safeNouns: Set<String> = ["yesterday","today","tomorrow","tonight","everything","something","nothing","anything","everyone","someone","anyone","nobody","everybody","somebody","none"]
func word(_ p: String) -> String { String(p.prefix(while: { !$0.isWhitespace })).trimmingCharacters(in: .punctuationCharacters) }
func lowers(_ l: String, _ p: String) -> Bool {
  let w = word(p)
  if ["I","I'm","I've","I'll","I'd"].contains(w) { return false }
  guard dict(w) else { return false }
  if safeNouns.contains(w.lowercased()) { return true }
  let j = l + p; let t = NLTagger(tagSchemes: [.lexicalClass]); t.string = j
  t.setLanguage(.english, range: j.startIndex..<j.endIndex)
  guard let tg = t.tag(at: j.index(j.startIndex, offsetBy: l.count), unit: .word, scheme: .lexicalClass).0,
        safeTags.contains(tg) else { return false }
  return true
}
// Names as the SUBJECT of the continuation — how a dictated second thought actually opens.
let names: [(String,String)] = [
  ("I mentioned it and ","Mark said he would be late."),("we spoke and ","Grace agreed to help."),
  ("the note said ","Bill has the keys."),("I heard ","Rose is moving out."),
  ("she told me ","Frank called twice."),("he asked whether ","Hope was coming along."),
  ("we agreed ","Sue would handle it."),("the ticket says ","Slack is down again."),
  ("turns out ","Google changed the API."),("apparently ","Apple shipped it early."),
  ("I read that ","Amazon raised prices."),("he said ","Tesla recalled the batch."),
  ("I heard ","Grant is leaving the team."),("she said ","Lily will be late."),
  ("apparently ","Olive has the files."),("he told me ","Ted approved it."),
  ("we switched and ","Linear is much faster."),("I spoke and ","Amber sent the design."),
  ("we heard ","Baker is retiring."),("I think ","Bishop already knows."),
  ("she said ","Dawn is handling it."),("apparently ","Holly sent it already."),
  ("I heard ","Hunter moved to Denver."),("he said ","Nick is running late."),
  ("she told me ","Pearl called earlier."),("I heard ","Ruby got the job."),
  ("apparently ","Rust is faster here."),("I read that ","Angular dropped support."),
  ("he said ","Notion is down."),("I keep notes and ","Obsidian syncs them."),
  ("we moved to ","Phoenix last spring."),("she works and ","Oracle pays well."),
  ("I can't wait to go to ","Steve's house."),("we are flying to ","Chicago on Friday."),
]
let ordinary: [(String,String)] = [
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
let dam = names.filter { lowers($0.0,$0.1) }, cov = ordinary.filter { lowers($0.0,$0.1) }
print("REALISTIC CORPUS — names as the subject of the continuation")
print("  ordinary words lowercased : \(cov.count)/\(ordinary.count)")
print("  names wrongly lowercased  : \(dam.count)/\(names.count) \(dam.map { word($0.1) })")
print(String(format: "  precision                 : %.1f%%", Double(cov.count)/Double(max(cov.count+dam.count,1))*100))
print("  coverage missed: \(ordinary.filter { !lowers($0.0,$0.1) }.map { word($0.1) })")
