import AppKit
import Foundation

// Positive control for the learned-word refusal. Without this, "the refusal
// changed nothing" is indistinguishable from "the refusal never ran".
let ck = NSSpellChecker.shared
let tag = NSSpellChecker.uniqueSpellDocumentTag()
let probe = "zorbitraxian"  // nonsense: cannot collide with anything real

func spelledCorrectly(_ w: String) -> Bool {
  ck.checkSpelling(
    of: w, startingAt: 0, language: "en", wrap: false,
    inSpellDocumentWithTag: tag, wordCount: nil
  ).location == NSNotFound
}

print("BEFORE learning:")
print("  hasLearnedWord(\(probe)) = \(ck.hasLearnedWord(probe))")
print("  spelled correctly        = \(spelledCorrectly(probe))")

ck.learnWord(probe)
print("AFTER learnWord:")
let learned = ck.hasLearnedWord(probe)
let nowValid = spelledCorrectly(probe)
print("  hasLearnedWord(\(probe)) = \(learned)")
print("  spelled correctly        = \(nowValid)")

// The claim under test: a learned word becomes "a valid ordinary word" to the
// dictionary, so without an explicit refusal it would be eligible for lowering.
print("\nCLAIM: a learned word passes the dictionary check and so would be lowercased.")
print("  claim holds: \(nowValid && learned)")

// Does an already-real word report as learned? (It must not, or the refusal
// would suppress ordinary vocabulary.)
print("  hasLearnedWord(\"yesterday\") = \(ck.hasLearnedWord("yesterday"))")
print("  hasLearnedWord(\"go\")        = \(ck.hasLearnedWord("go"))")

// RESTORE. Leaving a learned word behind would pollute the founder's dictionary.
ck.unlearnWord(probe)
print("\nAFTER unlearnWord (restore):")
print("  hasLearnedWord(\(probe)) = \(ck.hasLearnedWord(probe))")
print("  spelled correctly        = \(spelledCorrectly(probe))")
