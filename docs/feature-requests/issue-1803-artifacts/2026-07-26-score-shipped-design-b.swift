import AppKit
import Foundation
import NaturalLanguage

// Scores WHAT SHIPS against the list it replaces, on the real labelled corpus.
//
// This exists because the headline figures in the #1803 commit message and plan
// were originally produced by an untracked scratch script, which is the same
// reproducibility defect review caught in the two sibling scorers. The decision
// below is transcribed from EnglishWordOracleRuntime.makeOracle and
// EnglishWordOracle.mayLower, deliberately INCLUDING the absence of a
// `setLanguage` call on the tagger: an earlier scratch version set it and
// reported one fewer disagreement, so the instrument has to match the product
// rather than the other way round.
//
// Corpus: regenerate with `2026-07-26-build-real-labelled-pairs.py` beside this
// file, then point `pairsPath` at its output. It derives from the founder's own
// dictations and is deliberately not tracked.
//
// Run from the repository root: `swift docs/feature-requests/issue-1803-artifacts/2026-07-26-score-shipped-design-b.swift`

let pairsPath =
  "/private/tmp/claude-501/-Users-m4pro-sv-Developer-EnviousLabs-EnviousWispr/ff88b620-7ce1-43d3-99d0-8dc68323ee9e/scratchpad/pairs.tsv"
let baselineListPath =
  "docs/feature-requests/issue-1803-artifacts/ordinary-lowercase-words-baseline.txt"

let checker = NSSpellChecker.shared
let documentTag = NSSpellChecker.uniqueSpellDocumentTag()

// Mirrors EnglishWordOracleRuntime.resolveEnglishLanguage.
let english =
  checker.availableLanguages.filter {
    $0.replacingOccurrences(of: "_", with: "-").split(separator: "-", maxSplits: 1).first?
      .lowercased() == "en"
  }.sorted().first ?? "en"

func inDictionary(_ word: String) -> Bool {
  checker.checkSpelling(
    of: word.lowercased(), startingAt: 0, language: english, wrap: false,
    inSpellDocumentWithTag: documentTag, wordCount: nil
  ).location == NSNotFound
}

// PasteService.caretContextWindow — 20 UTF-16 units of left context, no more.
func clipToWindow(_ left: String) -> String {
  let units = Array(left.utf16)
  return units.count > 20 ? String(decoding: units.suffix(20), as: UTF16.self) : left
}

// The fused-token fix: a left window ending mid-word would otherwise join the
// payload into one token ("andMark") and the tagger would read a verb.
func separated(_ rawLeft: String) -> String {
  let clipped = clipToWindow(rawLeft)
  return clipped + ((clipped.last?.isWhitespace ?? true) ? "" : " ")
}

func firstWord(_ payload: String) -> String {
  String(payload.prefix(while: { !$0.isWhitespace }))
    .trimmingCharacters(in: .punctuationCharacters)
}

let nameTags: Set<NLTag> = [.personalName, .placeName, .organizationName]

func isRecognizedName(_ left: String, _ payload: String) -> Bool {
  let joined = left + payload
  let tagger = NLTagger(tagSchemes: [.nameType])
  tagger.string = joined
  let index = joined.index(joined.startIndex, offsetBy: left.count)
  guard let tag = tagger.tag(at: index, unit: .word, scheme: .nameType).0 else { return false }
  return nameTags.contains(tag)
}

// Refusals shared by every candidate, ahead of any word knowledge.
func passesSharedGuards(_ word: String) -> Bool {
  guard let first = word.first, first.isUppercase,
    !word.dropFirst().contains(where: \.isUppercase),
    !word.contains(where: \.isNumber),
    !["I", "I'm", "I've", "I'll", "I'd"].contains(word)
  else { return false }
  return true
}

/// Design B, as shipped: is it a name here, and if not, is it even English?
func shippedLowercases(_ left: String, _ payload: String) -> Bool {
  let word = firstWord(payload)
  guard passesSharedGuards(word) else { return false }
  guard !isRecognizedName(separated(left), payload) else { return false }
  return inDictionary(word)
}

let baselineList = Set(
  (try! String(contentsOfFile: baselineListPath, encoding: .utf8))
    .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty && !$0.hasPrefix("#") })

func baselineLowercases(_ left: String, _ payload: String) -> Bool {
  let word = firstWord(payload)
  guard passesSharedGuards(word) else { return false }
  return baselineList.contains(word.lowercased())
}

struct Pair {
  let keep: Bool
  let left: String
  let payload: String
}

var pairs: [Pair] = []
for line in (try! String(contentsOfFile: pairsPath, encoding: .utf8)).split(separator: "\n") {
  let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
  guard fields.count == 4 else { continue }
  pairs.append(Pair(keep: fields[1] == "keep", left: String(fields[2]), payload: String(fields[3])))
}
precondition(!pairs.isEmpty, "corpus did not load — regenerate it, see the header")
precondition(baselineList.count > 500, "baseline list did not load")

let shouldLower = pairs.filter { !$0.keep }.count
print("REAL LABELLED CONTINUATION PAIRS: \(pairs.count)  (\(pairs.count - shouldLower) must keep)")
print("baseline list entries: \(baselineList.count)   dictionary language: \(english)\n")

for (label, decide) in [
  ("the 799-word list this replaces", baselineLowercases),
  ("SHIPPED — name check, then dictionary", shippedLowercases),
] as [(String, (String, String) -> Bool)] {
  var lowered = 0
  var damage = 0
  var damaged: [String: Int] = [:]
  for pair in pairs where decide(pair.left, pair.payload) {
    lowered += 1
    if pair.keep {
      damage += 1
      damaged[firstWord(pair.payload), default: 0] += 1
    }
  }
  print(label)
  print("   lowercased \(lowered)   correct \(lowered - damage)   DAMAGE \(damage)")
  print(
    "   precision "
      + String(format: "%.2f%%", Double(lowered - damage) / Double(max(lowered, 1)) * 100)
      + "   recall "
      + String(format: "%.1f%%", Double(lowered - damage) / Double(shouldLower) * 100))
  let worst = damaged.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(10)
  if !worst.isEmpty {
    print("   most-damaged: " + worst.map { "\($0.key)(\($0.value))" }.joined(separator: " "))
  }
  print("")
}
