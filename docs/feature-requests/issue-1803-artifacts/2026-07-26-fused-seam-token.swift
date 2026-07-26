import Foundation
import NaturalLanguage

// Local diff review r2, P1: when the caret sits directly after a word, the
// repair inserts a leading space — but the tagger was being handed the RAW left
// window joined to the payload, fusing them into one token.
//
// Every corpus I measured used left contexts that already ended in a space, so
// none of them exercised this. That is the blind spot, not the tagger.
let safe: Set<NLTag> = [
  .verb, .adverb, .conjunction, .determiner, .pronoun, .adjective,
  .preposition, .particle, .interjection, .number,
]
func tag(_ left: String, _ payload: String) -> (String, Bool) {
  let joined = left + payload
  let t = NLTagger(tagSchemes: [.lexicalClass])
  t.string = joined
  t.setLanguage(.english, range: joined.startIndex..<joined.endIndex)
  guard
    let tg = t.tag(
      at: joined.index(joined.startIndex, offsetBy: left.count), unit: .word, scheme: .lexicalClass
    ).0
  else { return ("nil", false) }
  return (tg.rawValue, safe.contains(tg))
}

// Left contexts with NO trailing space — the caret sits right after a word.
let cases: [(String, String)] = [
  ("I mentioned it and", "Mark said he would be late."),
  ("we spoke and", "Grace agreed to help."),
  ("I heard", "Rose is moving out."),
  ("she told me", "Frank called twice."),
  ("tell", "Hunter we moved."),
  ("apparently", "Holly sent it already."),
  ("I saw", "Ruby last night."),
  ("the ticket says", "Slack is down again."),
  ("turns out", "Google changed the API."),
  ("we moved to", "Phoenix last spring."),
]

print("FUSED (raw left, the defect) vs SEPARATED (left + the inserted space)\n")
var fusedUnsafe = 0
var sepUnsafe = 0
for (left, payload) in cases {
  let fused = tag(left, payload)
  let separated = tag(left + " ", payload)
  if fused.1 { fusedUnsafe += 1 }
  if separated.1 { sepUnsafe += 1 }
  let word = payload.prefix(while: { !$0.isWhitespace })
  let flag = fused.1 ? "  <-- WOULD LOWERCASE A NAME" : ""
  print(
    "  \(word): fused=\(fused.0)/\(fused.1 ? "SAFE" : "refused")  separated=\(separated.0)/\(separated.1 ? "SAFE" : "refused")\(flag)"
  )
}
print("\n  names wrongly authorised when FUSED    : \(fusedUnsafe)/\(cases.count)")
print("  names wrongly authorised when SEPARATED: \(sepUnsafe)/\(cases.count)")
