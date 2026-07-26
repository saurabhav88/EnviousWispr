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
func tagIn(_ l: String, _ p: String) -> String {
  let j = l + p
  let t = NLTagger(tagSchemes: [.lexicalClass])
  t.string = j
  t.setLanguage(.english, range: j.startIndex..<j.endIndex)
  return t.tag(at: j.index(j.startIndex, offsetBy: l.count), unit: .word, scheme: .lexicalClass).0?
    .rawValue ?? "nil"
}

// The highest-frequency real openers the oracle LOSES, each in a plausible
// continuation rather than the ungrammatical synthetic frame of the first run.
let cases: [(String, String, String)] = [
  ("Testing", "we were ", "Testing the new build."),
  ("Hey", "I called out ", "Hey can you check this."),
  ("Okay", "and he said ", "Okay that works for me."),
  ("Yeah", "and she said ", "Yeah that sounds right."),
  ("Let's", "I think ", "Let's ship it tomorrow."),
  ("Hello", "he answered ", "Hello is anyone there."),
  ("Test", "we should ", "Test the new build."),
  ("Yep", "and he said ", "Yep that works."),
  ("Great", "I thought ", "Great news about the release."),
  ("Draft", "can you ", "Draft the reply for me."),
  ("Question", "I have a quick ", "Question about the invoice."),
  ("First", "we should ", "First check the logs."),
  ("Open", "can you ", "Open the door please."),
  ("Remember", "please ", "Remember to lock up."),
  ("Thanks", "I said ", "Thanks for the update."),
  ("Update", "can you ", "Update the ticket please."),
  ("Use", "we should ", "Use the other approach."),
  ("Hold", "please ", "Hold the line a moment."),
]

print("WHY THE TOP LOSSES FAIL  (dictionary result / tag in a plausible continuation)")
for (w, l, p) in cases {
  let pad = String(repeating: " ", count: max(0, 10 - w.count))
  print("  " + w + pad + "dict=" + (dict(w) ? "yes " : "NO  ") + " tag=" + tagIn(l, p))
}
