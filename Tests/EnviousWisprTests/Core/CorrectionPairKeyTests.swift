import Foundation
import Testing

@testable import EnviousWisprCore

/// #996: the pair key is how the live learn path tells one correction from
/// another: the candidate filter keys each run by it, the watcher dedupes what
/// it already sent to the judge by it, and the learned coordinator matches a
/// mishearing against a word's aliases through its normalisation. If it lies,
/// the same fix is judged twice or a different pair is treated as covered.
/// Class: `.productOutcome`.
@Suite(.tags(.productOutcome)) struct CorrectionPairKeyTests {

  @Test("the same pair in different casing and normalisation forms is ONE key")
  func pairKeyFoldsCaseAndNormalisation() {
    let a = CorrectionPairKey.make(original: "Sarah", corrected: "Saira")
    let b = CorrectionPairKey.make(original: "sarah", corrected: "SAIRA")
    // "é" precomposed versus "e" + combining acute: NFC makes them one.
    let c = CorrectionPairKey.make(original: "Jose", corrected: "Jos\u{00E9}")
    let d = CorrectionPairKey.make(original: "Jose", corrected: "Jose\u{0301}")
    #expect(a == b)
    #expect(c == d)
    #expect(a.hasPrefix("v1:["))
  }

  @Test("different pairs, reversed pairs and separator-bearing strings never collide")
  func pairKeyCannotCollide() {
    let forward = CorrectionPairKey.make(original: "Sarah", corrected: "Saira")
    let reversed = CorrectionPairKey.make(original: "Saira", corrected: "Sarah")
    #expect(forward != reversed)
    // An original containing what a naive `a|b` separator scheme would use.
    let tricky1 = CorrectionPairKey.make(original: "a\",\"b", corrected: "c")
    let tricky2 = CorrectionPairKey.make(original: "a", corrected: "b\",\"c")
    #expect(tricky1 != tricky2)
    let quote = CorrectionPairKey.make(original: "say \"hi\"", corrected: "say \\hi")
    #expect(quote != CorrectionPairKey.make(original: "say \\hi", corrected: "say \"hi\""))
  }

  @Test(
    "the key's array decodes back to exactly the two normalised strings with an independent JSON reader"
  )
  func pairKeyIsRealJSON() throws {
    let cases: [(String, String)] = [
      ("Sarah", "Saira"), ("a\",\"b", "c\\d"), ("tab\there", "new\nline"), ("Müller", "Mueller"),
      ("emoji 🙂", "control \u{01}"),
    ]
    for (o, c) in cases {
      let key = CorrectionPairKey.make(original: o, corrected: c)
      let json = String(key.dropFirst("v1:".count))
      let decoded = try JSONDecoder().decode([String].self, from: Data(json.utf8))
      #expect(
        decoded == [CorrectionPairKey.normalise(o), CorrectionPairKey.normalise(c)], "\(o) -> \(c)")
    }
  }
}
