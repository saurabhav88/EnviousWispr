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

// ---- CANDIDATE A: the Gemini proposal, transcribed verbatim -----------------
func geminiShouldCapitalize(leftContext: String, appendedText: String) -> Bool {
  let trimmed = appendedText.trimmingCharacters(in: .whitespacesAndNewlines)
  guard let firstWord = trimmed.components(separatedBy: .whitespaces).first, !firstWord.isEmpty
  else { return false }
  let lower = firstWord.lowercased()
  if ["i", "i'm", "i've", "i'll", "i'd"].contains(lower) { return true }
  if firstWord.count > 1, firstWord == firstWord.uppercased(), firstWord.allSatisfy({ $0.isLetter })
  {
    return true
  }
  let prefix = leftContext.isEmpty ? "" : "\(leftContext.trimmingCharacters(in: .whitespaces)) "
  let combined = prefix + trimmed
  let tagger = NLTagger(tagSchemes: [.nameType, .lexicalClass, .language])
  tagger.string = combined
  let target = prefix.endIndex
  let lang = tagger.dominantLanguage ?? .english
  if [
    NLLanguage.japanese, .simplifiedChinese, .traditionalChinese, .korean, .arabic, .hindi,
    .thai, .hebrew,
  ].contains(lang) {
    return false
  }
  if lang == .german {
    if tagger.tag(at: target, unit: .word, scheme: .lexicalClass).0 == .noun { return true }
  }
  if let name = tagger.tag(at: target, unit: .word, scheme: .nameType).0 {
    switch name {
    case .personalName, .placeName, .organizationName: return true
    default: break
    }
  }
  return false
}
func geminiLowercases(_ l: String, _ p: String) -> Bool {
  !geminiShouldCapitalize(leftContext: l, appendedText: p)
}

// ---- CANDIDATE B: system dictionary + lexicalClass in context ---------------
let safeTags: Set<NLTag> = [
  .verb, .adverb, .conjunction, .determiner, .pronoun, .adjective,
  .preposition, .particle, .interjection, .number,
]
let safeNouns: Set<String> = [
  "yesterday", "today", "tomorrow", "tonight", "everything", "something",
  "nothing", "anything", "everyone", "someone", "anyone", "nobody",
  "everybody", "somebody", "none",
]
func bLowercases(_ l: String, _ p: String) -> Bool {
  let w = String(p.prefix(while: { !$0.isWhitespace })).trimmingCharacters(
    in: .punctuationCharacters)
  if ["I", "I'm", "I've", "I'll", "I'd"].contains(w) { return false }
  guard dict(w) else { return false }
  let j = l + p
  let tg = NLTagger(tagSchemes: [.lexicalClass])
  tg.string = j
  tg.setLanguage(.english, range: j.startIndex..<j.endIndex)
  let tag = tg.tag(at: j.index(j.startIndex, offsetBy: l.count), unit: .word, scheme: .lexicalClass)
    .0
  if safeNouns.contains(w.lowercased()) { return true }
  guard let tag, safeTags.contains(tag) else { return false }
  return true
}

// ---- CORPUS ----------------------------------------------------------------
let mustKeep: [(String, String)] = [
  ("I mentioned it and ", "Mark said he would be late."),
  ("we spoke and ", "Grace agreed to help."),
  ("the note said ", "Bill has the keys."), ("I heard ", "Rose is moving out."),
  ("she told me ", "Frank called twice."), ("he asked whether ", "Hope was coming along."),
  ("we agreed ", "Sue would handle it."), ("the ticket says ", "Slack is down again."),
  ("turns out ", "Google changed the API."), ("apparently ", "Apple shipped it early."),
  ("I read that ", "Amazon raised prices."), ("he said ", "Tesla recalled the batch."),
  ("we moved to ", "Phoenix last spring."), ("she works at ", "Oracle now."),
  ("I spoke to ", "Amber about the design."), ("tell ", "Baker we are ready."),
  ("we saw ", "Bishop yesterday."), ("thank ", "Dawn for the notes."),
  ("ask ", "Holly to send it."), ("tell ", "Hunter we moved."),
  ("I saw ", "Lily earlier."), ("tell ", "Nick we are late."),
  ("thank ", "Olive for the gift."), ("call ", "Pearl this evening."),
  ("I saw ", "Ruby last night."), ("email ", "Ted the slides."),
  ("it runs on ", "Rust these days."), ("built with ", "Angular originally."),
  ("we use ", "Notion for docs."), ("switched to ", "Linear for tickets."),
  ("I keep notes in ", "Obsidian these days."), ("the file is on ", "Drive already."),
  ("I can't wait to go to ", "Steve's house."), ("we are flying to ", "Chicago on Friday."),
  ("I met ", "Barry at the office."), ("hire ", "Dean if he is free."),
  ("we flew to ", "Austin last week."), ("I live near ", "Jackson now."),
]
let shouldLower: [(String, String)] = [
  ("I can't wait to go to ", "The museum tonight."),
  ("I can't wait to ", "Go home and eat dinner."), ("remind me to ", "Send the invoice today."),
  ("I need to ", "Check the logs first."), ("we should ", "Call them back."),
  ("let me ", "Read it again."), ("I want to ", "Buy the tickets now."),
  ("please ", "Open the door."), ("I said ", "Yesterday was fine."),
  ("he thinks ", "Actually it works."), ("and ", "Because it matters."),
  ("I told him ", "The report is ready."), ("we were ", "Testing now."),
  ("I'm ", "Really tired today."), ("so ", "Okay let's start."),
  ("I'd like to ", "Work from home tomorrow."), ("we need to ", "Plan the release."),
  ("I have to ", "Write the summary."), ("try to ", "Fix it before Friday."),
  ("I'll ", "Email you the details."), ("let's ", "Build it properly."),
  ("we can ", "Start on Monday."), ("I want to ", "Learn that framework."),
  ("time to ", "Clean the kitchen."), ("going to ", "Drive there myself."),
  ("I might ", "Sleep in tomorrow."), ("we could ", "Watch it tonight."),
  ("I should ", "Study for the exam."), ("help me ", "Cook dinner."),
  ("about to ", "Run the tests."), ("need to ", "Pay the invoice."),
  ("he said ", "Today is busy."), ("we agreed ", "Tomorrow works better."),
  ("she said ", "Everything is ready."), ("I think ", "Something went wrong."),
]
func word(_ p: String) -> String {
  String(p.prefix(while: { !$0.isWhitespace })).trimmingCharacters(in: .punctuationCharacters)
}
func score(_ name: String, _ f: (String, String) -> Bool) {
  let dam = mustKeep.filter { f($0.0, $0.1) }
  let cov = shouldLower.filter { f($0.0, $0.1) }
  let decisions = dam.count + cov.count
  let precision = decisions == 0 ? 0 : Double(cov.count) / Double(decisions) * 100
  print("\n\(name)")
  print(
    String(
      format: "  coverage %d/%d   DAMAGE %d/%d   precision %.1f%%",
      cov.count, shouldLower.count, dam.count, mustKeep.count, precision))
  if !dam.isEmpty { print("  names wrongly lowercased: \(dam.map { word($0.1) })") }
  let missed = shouldLower.filter { !f($0.0, $0.1) }
  if !missed.isEmpty { print("  coverage missed: \(missed.map { word($0.1) })") }
}
score("A — Gemini proposal (nameType, default lowercase)", geminiLowercases)
score("B — system dictionary + lexicalClass + safe-noun set", bLowercases)

// The 799-word list this change deletes, kept beside the scorer so the
// comparison stays runnable after the shipped resource is gone.
let list = Set(
  (try! String(
    contentsOfFile:
      "docs/feature-requests/issue-1803-artifacts/ordinary-lowercase-words-baseline.txt",
    encoding: .utf8))
    .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter {
      !$0.isEmpty && !$0.hasPrefix("#")
    })
score("C — shipped 799-word hand list (today)") { _, p in list.contains(word(p).lowercased()) }
