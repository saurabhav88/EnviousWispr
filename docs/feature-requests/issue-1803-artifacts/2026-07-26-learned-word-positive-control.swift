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

// ---------------------------------------------------------------------------
// CASE FOLDING. Cloud review (PR #1815) raised that `mayLower` queries only the
// lowercased form, so a user who teaches macOS a CAPITALISED brand — `Sentry`,
// `Olive` — would slip past the refusal and be lowered by the dictionary. That
// is exactly the population design B is weakest on, so it had to be measured
// rather than reasoned about. The probe above tests a lowercase word only,
// which is the gap that let the question stand.
// ---------------------------------------------------------------------------
let capProbe = "Zqxvkjbrandone"  // taught capitalised
let lowProbe = "zqxvkjbrandtwo"  // taught lowercase

print("\nCASE FOLDING — control, before teaching (every value must be false):")
for w in [capProbe, capProbe.lowercased(), lowProbe, lowProbe.uppercased()] {
  print("  hasLearnedWord(\(w)) = \(ck.hasLearnedWord(w))   ordinary = \(spelledCorrectly(w))")
}
guard !ck.hasLearnedWord(capProbe), !ck.hasLearnedWord(lowProbe),
  !spelledCorrectly(capProbe.lowercased())
else {
  print("\nABORT: probes are not clean, any result below would be meaningless")
  exit(1)
}

ck.learnWord(capProbe)
ck.learnWord(lowProbe)

let capExact = ck.hasLearnedWord(capProbe)
let capLower = ck.hasLearnedWord(capProbe.lowercased())
let lowExact = ck.hasLearnedWord(lowProbe)
let lowCapped = ck.hasLearnedWord(lowProbe.prefix(1).uppercased() + lowProbe.dropFirst())
let lowUpper = ck.hasLearnedWord(lowProbe.uppercased())

print("\nTaught \"\(capProbe)\" capitalised and \"\(lowProbe)\" lowercase:")
print("  taught-capitalised, queried exact       -> \(capExact)")
print("  taught-capitalised, queried LOWERCASE   -> \(capLower)   <-- what mayLower does")
print("  taught-lowercase,   queried exact       -> \(lowExact)")
print("  taught-lowercase,   queried Capitalised -> \(lowCapped)")
print("  taught-lowercase,   queried UPPERCASE   -> \(lowUpper)")

// RESTORE before printing the verdict, so an early exit cannot leave them behind.
ck.unlearnWord(capProbe)
ck.unlearnWord(lowProbe)

print("\nVERDICT on the review finding:")
if capExact && !capLower {
  print("  CONFIRMED — a capitalised learned word is invisible to the lowercase query.")
} else if capExact && capLower {
  print("  REFUTED — the lookup folds case, so the lowercase query already finds it.")
} else {
  print("  INVALID PROBE — learnWord did not register at all (exact=\(capExact)).")
}
print("  restored: \(!ck.hasLearnedWord(capProbe) && !ck.hasLearnedWord(lowProbe))")
