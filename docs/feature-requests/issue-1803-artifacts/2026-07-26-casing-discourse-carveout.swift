import AppKit
import Foundation
import NaturalLanguage

let ck = NSSpellChecker.shared
let st = NSSpellChecker.uniqueSpellDocumentTag()
func dict(_ w: String) -> Bool {
  ck.checkSpelling(
    of: w.lowercased(), startingAt: 0, language: "en", wrap: false,
    inSpellDocumentWithTag: st, wordCount: nil
  ).location == NSNotFound
}
let safeTags: Set<NLTag> = [
  .verb, .adverb, .conjunction, .determiner, .pronoun, .adjective, .preposition, .particle,
  .interjection, .number,
]
// Indefinite pronouns and deictic time words (closed grammatical classes).
let safeNounsBase: Set<String> = [
  "yesterday", "today", "tomorrow", "tonight", "everything", "something", "nothing", "anything",
  "everyone", "someone", "anyone", "nobody", "everybody", "somebody", "none",
]
// Greetings, acknowledgements and politeness formulae. Derived from the top real
// dictation openers on this machine, all of which tag Noun yet are never proper
// nouns. Closed set, auditable, and every member is a discourse marker.
let safeDiscourse: Set<String> = [
  "hey", "hello", "hi", "yep", "yup", "yeah", "yes", "nope", "okay", "ok",
  "thanks", "thank", "please", "sorry", "sure", "welcome", "goodbye", "bye",
  "question", "answer", "note", "reminder", "update", "example",
]
func word(_ p: String) -> String {
  String(p.prefix(while: { !$0.isWhitespace })).trimmingCharacters(in: .punctuationCharacters)
}
func clip(_ l: String) -> String {
  let u = Array(l.utf16)
  return u.count > 20 ? String(decoding: u.suffix(20), as: UTF16.self) : l
}
func oracle(_ rawL: String, _ p: String, extended: Bool) -> Bool {
  let w = word(p)
  if ["I", "I'm", "I've", "I'll", "I'd"].contains(w) { return false }
  guard w.first?.isUppercase == true, !w.dropFirst().contains(where: \.isUppercase),
    !w.contains(where: \.isNumber), dict(w)
  else { return false }
  let lower = w.lowercased()
  if safeNounsBase.contains(lower) { return true }
  if extended, safeDiscourse.contains(lower) { return true }
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

// DAMAGE CHECK: does the extended carve-out let any name through?
let names: [(String, String)] = [
  ("I mentioned it and ", "Mark said he would be late."),
  ("we spoke and ", "Grace agreed to help."), ("the note said ", "Bill has the keys."),
  ("I heard ", "Rose is moving out."), ("she told me ", "Frank called twice."),
  ("he asked whether ", "Hope was coming along."), ("we agreed ", "Sue would handle it."),
  ("the ticket says ", "Slack is down again."), ("turns out ", "Google changed the API."),
  ("apparently ", "Apple shipped it early."), ("I read that ", "Amazon raised prices."),
  ("he said ", "Tesla recalled the batch."), ("I heard ", "Grant is leaving the team."),
  ("she said ", "Lily will be late."), ("apparently ", "Olive has the files."),
  ("he told me ", "Ted approved it."), ("we switched and ", "Linear is much faster."),
  ("I spoke and ", "Amber sent the design."), ("we heard ", "Baker is retiring."),
  ("I think ", "Bishop already knows."), ("she said ", "Dawn is handling it."),
  ("apparently ", "Holly sent it already."), ("I heard ", "Hunter moved to Denver."),
  ("he said ", "Nick is running late."), ("she told me ", "Pearl called earlier."),
  ("I heard ", "Ruby got the job."), ("apparently ", "Rust is faster here."),
  ("I read that ", "Angular dropped support."), ("he said ", "Notion is down."),
  ("I keep notes and ", "Obsidian syncs them."), ("we moved to ", "Phoenix last spring."),
  ("she works and ", "Oracle pays well."), ("I can't wait to go to ", "Steve's house."),
  ("we are flying to ", "Chicago on Friday."),
]
// COVERAGE: ordinary continuations, including the five real openers that failed.
let ordinary: [(String, String)] = [
  ("I can't wait to go to ", "The museum tonight."),
  ("I can't wait to ", "Go home and eat dinner."),
  ("remind me to ", "Send the invoice today."), ("I need to ", "Check the logs first."),
  ("we should ", "Call them back."), ("let me ", "Read it again."),
  ("I want to ", "Buy the tickets now."), ("please ", "Open the door."),
  ("I said ", "Yesterday was fine."), ("he thinks ", "Actually it works."),
  ("and ", "Because it matters."), ("I told him ", "The report is ready."),
  ("we were ", "Testing now."), ("I'm ", "Really tired today."),
  ("so ", "Okay let's start."), ("I'd like to ", "Work from home tomorrow."),
  ("we need to ", "Plan the release."), ("I have to ", "Write the summary."),
  ("try to ", "Fix it before Friday."), ("I'll ", "Email you the details."),
  ("let's ", "Build it properly."), ("we can ", "Start on Monday."),
  ("time to ", "Clean the kitchen."), ("going to ", "Drive there myself."),
  ("I might ", "Sleep in tomorrow."), ("we could ", "Watch it tonight."),
  ("I should ", "Study for the exam."), ("help me ", "Cook dinner."),
  ("about to ", "Run the tests."), ("need to ", "Pay the invoice."),
  ("he said ", "Today is busy."), ("we agreed ", "Tomorrow works better."),
  ("she said ", "Everything is ready."), ("I think ", "Something went wrong."),
  // the five real high-frequency openers that tagged Noun
  ("I called out ", "Hey can you check this."), ("he answered ", "Hello is anyone there."),
  ("and he said ", "Yep that works."), ("I have a quick ", "Question about the invoice."),
  ("I said ", "Thanks for the update."),
]
for extended in [false, true] {
  let dam = names.filter { oracle($0.0, $0.1, extended: extended) }
  let cov = ordinary.filter { oracle($0.0, $0.1, extended: extended) }
  let label = extended ? "WITH discourse carve-out   " : "base (pronouns/time only) "
  let precision = Double(cov.count) / Double(max(cov.count + dam.count, 1)) * 100
  print(
    label
      + "coverage \(cov.count)/\(ordinary.count)  DAMAGE \(dam.count)/\(names.count)  precision "
      + String(format: "%.1f%%", precision))
  if !dam.isEmpty { print("   damage: \(dam.map { word($0.1) })") }
  let miss = ordinary.filter { !oracle($0.0, $0.1, extended: extended) }
  if !miss.isEmpty { print("   missed: \(miss.map { word($0.1) })") }
}
