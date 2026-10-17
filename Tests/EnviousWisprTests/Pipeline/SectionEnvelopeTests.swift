import Foundation
import Testing

@testable import EnviousWisprPipeline

/// The finite wire grammar, not a linguistic quality score.
@Suite(.tags(.driftGuard))
struct SectionEnvelopeTests {
  @Test("Independent literal encoding and decoding preserve section ownership and tag-shaped content")
  func literalPayloads() {
    let sections = [#"Keep <s2> and </s02> literally."#, #"Keep <\s3> and <\\s4> too."#, "Cafe\u{301} 日本語 👩🏽‍💻"]
    let expected = #"<s1>Keep <\s2> and </\s02> literally.</s1>"# + "\n"
      + #"<s2>Keep <\\s3> and <\\\s4> too.</s2>"# + "\n<s3>Cafe\u{301} 日本語 👩🏽‍💻</s3>"
    #expect(Array(SectionEnvelope.wrap(sections).utf8) == Array(expected.utf8))
    let decoded = SectionEnvelope.unwrap(expected, expected: 3)
    #expect(decoded?.map { Array($0.utf8) } == sections.map { Array($0.utf8) })
  }

  @Test("Complete empty bodies are decoded, surrounding whitespace is transport only")
  func emptyBody() {
    #expect(SectionEnvelope.unwrap(" \n<s1>  Hello. \n</s1>\n<s2> \n </s2>\t", expected: 2) == ["Hello.", ""])
    #expect(SectionEnvelope.unwrap("", expected: 0) == nil)
  }

  @Test("Malformed replies never return a partial mapping", arguments: [
    "<s1>A</s1>",
    "<s1>A</s1><s2>B</s2><s3>C</s3>",
    "<s1>A</s1><s1>B</s1>",
    "<s2>B</s2><s1>A</s1>",
    "<s01>A</s01><s2>B</s2>",
    "<s1>A</s2><s2>B</s2>",
    "<s1>A<s2>B</s2>",
    "<s1>A<s2>B</s1><s2>C</s2>",
    "<s1>A</s1>extra<s2>B</s2>",
    "<s1>A</s1><s2>B</s2></s3>",
    "Preamble <s1>A</s1><s2>B</s2>",
    "<s1>A</s1><s2>B</s2> trailing"
  ])
  func malformed(reply: String) {
    #expect(SectionEnvelope.unwrap(reply, expected: 2) == nil)
  }

  @Test("Batch addendum contains only the measured section bookkeeping")
  func addendum() {
    #expect(SectionEnvelope.addendum(count: 2) == "\n\nThe text contains 2 sections, each between <sK> and </sK> for K from 1 to 2. Clean each section on its own. Return all sections, in the same order, with the same tags, and nothing outside the tags. Never merge, drop, reorder or add a section.")
  }
}
