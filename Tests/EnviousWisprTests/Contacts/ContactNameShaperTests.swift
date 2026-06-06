import EnviousWisprContacts
import Testing

/// #636 follow-up — per-name shaping: each distinctive name becomes its OWN
/// single-token canonical (no combined "First Last"), and a lone common word is
/// never imported as a single token (WordCorrector would rewrite it on its exact
/// pass, and there is no longer a combined entry to absorb it).
@Suite("ContactNameShaper — per-name shaping (#636 follow-up)")
struct ContactNameShaperTests {
  private func canonicals(_ candidates: [CandidateName]) -> [String] {
    ContactNameShaper.shape(candidates).map(\.canonical)
  }

  private func contact(_ given: String, _ family: String, id: String = "id") -> CandidateName {
    CandidateName(contactID: id, given: given, family: family)
  }

  @Test("Distinctive first and last become two separate tokens, no combined entry")
  func distinctiveFullNameSplits() {
    #expect(canonicals([contact("Malavika", "Chander")]) == ["Malavika", "Chander"])
    #expect(canonicals([contact("Rajesh", "Ramachandran")]) == ["Rajesh", "Ramachandran"])
  }

  // matcher-set-adversarial-tests: a common-word first name must NEVER become a
  // lone single-token canonical, and there is no longer a combined entry to fall
  // back on — only the distinctive surname survives.
  @Test("Common-word first name dropped; distinctive surname kept alone")
  func commonWordFirstNameDropped() {
    #expect(canonicals([contact("Will", "Vasquez")]) == ["Vasquez"])
  }

  @Test("Common-word surname dropped; distinctive first name kept alone")
  func commonWordSurnameDropped() {
    // "cook" is an occupational common word in the stoplist.
    #expect(canonicals([contact("Aisha", "Cook")]) == ["Aisha"])
  }

  @Test("Both names common words yields nothing")
  func bothCommonWordsYieldNothing() {
    #expect(canonicals([contact("Will", "May")]).isEmpty)
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

  @Test("Common-word match is case-insensitive")
  func commonWordCaseInsensitive() {
    // Lower/upper variants of stoplisted "will" are still dropped.
    #expect(canonicals([contact("will", "Vasquez")]) == ["Vasquez"])
    #expect(canonicals([contact("WILL", "Vasquez")]) == ["Vasquez"])
  }

  @Test("Hyphenated and apostrophe names are distinctive tokens")
  func hyphenAndApostropheKept() {
    #expect(canonicals([contact("Anne-Marie", "O'Connor")]) == ["Anne-Marie", "O'Connor"])
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
    // No combined "J Okafor" either — only the distinctive surname survives.
    #expect(canonicals([contact("J", "Okafor")]) == ["Okafor"])
  }

  @Test("Two-character distinctive surname is kept")
  func shortDistinctiveSurnameKept() {
    #expect(canonicals([contact("", "Ng")]) == ["Ng"])
  }

  @Test("Identical given and family dedupe within one contact")
  func intraContactDedupe() {
    #expect(canonicals([contact("Aaron", "Aaron")]) == ["Aaron"])
  }

  @Test("Both-empty contact yields nothing")
  func bothEmpty() {
    #expect(canonicals([contact("", "")]).isEmpty)
  }

  @Test(
    "A surname shared across contacts is emitted per contact (cross-contact dedupe is the importer's job)"
  )
  func duplicateSurnameAcrossContactsNotDedupedByShaper() {
    let out = ContactNameShaper.shape([
      contact("Arvind", "Vaish", id: "c1"),
      contact("Saurabh", "Vaish", id: "c2"),
    ])
    #expect(out.map(\.canonical) == ["Arvind", "Vaish", "Saurabh", "Vaish"])
    // Provenance distinguishes the two "Vaish" entries.
    #expect(out.filter { $0.canonical == "Vaish" }.map(\.contactID) == ["c1", "c2"])
  }

  @Test("Per-contact provenance is preserved on every shaped term")
  func provenancePreserved() {
    let shaped = ContactNameShaper.shape([contact("Rajesh", "Ramachandran", id: "abc")])
    #expect(shaped.map(\.canonical) == ["Rajesh", "Ramachandran"])
    #expect(shaped.allSatisfy { $0.contactID == "abc" })
  }
}
