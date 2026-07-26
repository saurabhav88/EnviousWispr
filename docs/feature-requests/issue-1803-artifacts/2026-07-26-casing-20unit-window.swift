import AppKit
import Foundation
import NaturalLanguage
let ck = NSSpellChecker.shared, st = NSSpellChecker.uniqueSpellDocumentTag()
func dict(_ w: String) -> Bool { ck.checkSpelling(of: w.lowercased(), startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: st, wordCount: nil).location == NSNotFound }
let safeTags: Set<NLTag> = [.verb,.adverb,.conjunction,.determiner,.pronoun,.adjective,.preposition,.particle,.interjection,.number]
let safeNouns: Set<String> = ["yesterday","today","tomorrow","tonight","everything","something","nothing","anything","everyone","someone","anyone","nobody","everybody","somebody","none"]
func word(_ p: String) -> String { String(p.prefix(while: { !$0.isWhitespace })).trimmingCharacters(in: .punctuationCharacters) }
func clip(_ l: String) -> String {
  let u = Array(l.utf16); guard u.count > 20 else { return l }
  return String(decoding: u.suffix(20), as: UTF16.self)
}
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
// REALISTIC long left contexts — every one exceeds 20 units and gets clipped mid-word.
let longNames: [(String,String)] = [
  ("I was thinking about this last night and I mentioned it and ","Mark said he would be late."),
  ("we had a long conversation this morning and ","Grace agreed to help."),
  ("I checked with the front desk and the note said ","Bill has the keys."),
  ("there is a lot going on right now and I heard ","Rose is moving out."),
  ("I was out walking the dog when she told me ","Frank called twice."),
  ("the incident channel is going wild and the ticket says ","Slack is down again."),
  ("we spent all week on the integration and turns out ","Google changed the API."),
  ("the keynote was earlier than expected so apparently ","Apple shipped it early."),
  ("everyone is complaining about shipping costs and I read that ","Amazon raised prices."),
  ("the recall notice went out this morning and he said ","Tesla recalled the batch."),
  ("I asked around the office and she said ","Lily will be late."),
  ("we compared all the trackers we could find and switched and ","Linear is much faster."),
  ("the whole team relocated over the summer and we moved to ","Phoenix last spring."),
  ("we spent the afternoon driving around and I can't wait to go to ","Steve's house."),
  ("the tickets came through yesterday and we are flying to ","Chicago on Friday."),
  ("I have been reading about systems languages and apparently ","Rust is faster here."),
]
let longOrdinary: [(String,String)] = [
  ("it has been a really long week and I can't wait to go to ","The museum tonight."),
  ("we finished everything early today so I can't wait to ","Go home and eat dinner."),
  ("the invoice has been sitting in my drafts so remind me to ","Send the invoice today."),
  ("something looks off with the deployment and I need to ","Check the logs first."),
  ("they left three voicemails this afternoon so we should ","Call them back."),
  ("I skimmed it the first time around so let me ","Read it again."),
  ("the presale opens in about ten minutes and I want to ","Buy the tickets now."),
  ("it is freezing out here on the porch so please ","Open the door."),
  ("we talked about the schedule and I said ","Yesterday was fine."),
  ("I have three meetings back to back so I'd like to ","Work from home tomorrow."),
  ("the roadmap is completely out of date and we need to ","Plan the release."),
  ("the deadline moved up by a week so I have to ","Write the summary."),
  ("the build has been red since Tuesday so try to ","Fix it before Friday."),
  ("once the contract is countersigned I'll ","Email you the details."),
  ("we are not cutting corners this time so let's ","Build it properly."),
  ("the kitchen is a complete disaster so it is time to ","Clean the kitchen."),
  ("the rental fell through at the last minute so I am going to ","Drive there myself."),
  ("nothing is on the calendar before noon so I might ","Sleep in tomorrow."),
  ("the exam is first thing Monday morning so I should ","Study for the exam."),
  ("the guests arrive in about an hour so help me ","Cook dinner."),
]
for clipped in [false, true] {
  let f: (String,String) -> Bool = { l, p in lowers(clipped ? clip(l) : l, p) }
  let dam = longNames.filter { f($0.0,$0.1) }, cov = longOrdinary.filter { f($0.0,$0.1) }
  print(String(format: "%@ coverage %2d/%d  DAMAGE %d/%d  precision %.1f%%",
    clipped ? "CLIPPED to 20 units (REAL): " : "FULL sentence            : ",
    cov.count, longOrdinary.count, dam.count, longNames.count,
    Double(cov.count)/Double(max(cov.count+dam.count,1))*100))
  if !dam.isEmpty { print("   damage: \(dam.map { word($0.1) })") }
  let m = longOrdinary.filter { !f($0.0,$0.1) }
  if !m.isEmpty { print("   missed: \(m.map { word($0.1) })") }
}
print("\nall \(longNames.count + longOrdinary.count) left contexts exceed 20 units: \((longNames+longOrdinary).allSatisfy { $0.0.utf16.count > 20 })")
print("example clips:")
for s in ["it has been a really long week and I can't wait to go to ", "I was thinking about this last night and I mentioned it and "] {
  print("  '\(clip(s))'")
}
