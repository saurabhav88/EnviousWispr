import EnviousWisprContacts
import Testing

/// #636 — the §3.4 design hinge: shaping contact names so a lone common word
/// never becomes a single-token canonical (which `WordCorrector` would rewrite
/// unconditionally on its exact pass).
@Suite("ContactNameShaper — import shaping (#636)")
struct ContactNameShaperTests {
  private func canonicals(_ candidates: [CandidateName]) -> [String] {
    ContactNameShaper.shape(candidates).map(\.canonical)
  }

  private func contact(_ given: String, _ family: String, id: String = "id") -> CandidateName {
    CandidateName(contactID: id, given: given, family: family)
  }

  @Test("Distinctive full name yields the full canonical plus both lone tokens")
  func distinctiveFullName() {
    let out = canonicals([contact("Rajesh", "Ramachandran")])
    #expect(out.contains("Rajesh Ramachandran"))
    #expect(out.contains("Rajesh"))
    #expect(out.contains("Ramachandran"))
  }

  // matcher-set-adversarial-tests: the common-word first name "Will" must NEVER
  // become a lone single-token canonical — that would capitalize the spoken
  // verb "will" on every dictation via the corrector's exact pass.
  @Test("Common-word first name kept only in the full name, never as a lone token")
  func commonWordFirstNameNotLone() {
    let out = canonicals([contact("Will", "Vasquez")])
    #expect(out.contains("Will Vasquez"))  // full phrase is safe (multi-word)
    #expect(out.contains("Vasquez"))  // distinctive surname lone is fine
    #expect(!out.contains("Will"))  // lone common word is NEVER imported
  }

  @Test("Common-word surname also excluded as a lone token")
  func commonWordSurnameNotLone() {
    // "cook" is an occupational common word in the stoplist.
    let out = canonicals([contact("Aisha", "Cook")])
    #expect(out.contains("Aisha Cook"))
    #expect(out.contains("Aisha"))
    #expect(!out.contains("Cook"))
  }

  @Test("Single-field contact whose only name is a common word yields nothing")
  func loneCommonWordOnlyProducesNothing() {
    #expect(canonicals([contact("May", "")]).isEmpty)
    #expect(canonicals([contact("", "Rose")]).isEmpty)
  }

  @Test("Distinctive single-field contact yields just that token")
  func distinctiveSingleField() {
    #expect(canonicals([contact("", "Vasquez")]) == ["Vasquez"])
    #expect(canonicals([contact("Ramachandran", "")]) == ["Ramachandran"])
  }

  @Test("Names containing digits are treated as junk")
  func digitsAreJunk() {
    // Family field is a phone fragment → dropped; distinctive given kept.
    #expect(canonicals([contact("Spam", "555-1234")]) == ["Spam"])
    // Given field has a digit → not name-like → contact yields nothing.
    #expect(canonicals([contact("Line 2", "")]).isEmpty)
  }

  @Test("Single-letter initials are not captured as lone tokens")
  func initialsNotLone() {
    let out = canonicals([contact("J", "Okafor")])
    #expect(out.contains("J Okafor"))
    #expect(out.contains("Okafor"))
    #expect(!out.contains("J"))
  }

  @Test("Two-character distinctive surname is kept")
  func shortDistinctiveSurnameKept() {
    #expect(canonicals([contact("", "Ng")]) == ["Ng"])
  }

  @Test("Identical given and family dedupe within one contact")
  func intraContactDedupe() {
    let out = canonicals([contact("Aaron", "Aaron")])
    #expect(out.contains("Aaron Aaron"))
    #expect(out.filter { $0 == "Aaron" }.count == 1)
  }

  @Test("Both-empty contact yields nothing")
  func bothEmpty() {
    #expect(canonicals([contact("", "")]).isEmpty)
  }

  @Test("Per-contact provenance is preserved on every shaped term")
  func provenancePreserved() {
    let shaped = ContactNameShaper.shape([contact("Rajesh", "Ramachandran", id: "abc")])
    #expect(!shaped.isEmpty)
    #expect(shaped.allSatisfy { $0.contactID == "abc" })
  }
}
