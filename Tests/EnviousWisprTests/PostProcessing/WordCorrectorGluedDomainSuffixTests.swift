import Foundation
import Testing

@testable import EnviousWisprCore
@testable import EnviousWisprPostProcessing

/// A custom word's own alias, glued to a recognized TLD with no space
/// ("EnviousWispr.com" as one ASR token), must correct the word AND keep the
/// domain suffix — never silently drop it.
///
/// Measured live from the founder's own dictation, 2026-08-21: "Enviousvisper.com"
/// corrected to "EnviousWispr" with the ".com" gone entirely. Root cause:
/// `WordCorrector.splitPunctuation` only strips LEADING/TRAILING characters
/// that are not letters or numbers, so a token ending in a letter ("...com")
/// never gets its internal "." recognized as a boundary at all — the whole
/// glued string, TLD included, was handed to the matching passes as one
/// "core", and a match replaced the entire thing.
@Suite("WordCorrector — a glued domain suffix survives correction", .tags(.productOutcome))
struct WordCorrectorGluedDomainSuffixTests {

  private static let enviousWispr = CustomWord(
    canonical: "EnviousWispr",
    aliases: [
      "envious visper", "envious whisper", "envious wisper",
      "mbs cisper", "envious cisper", "envious wispr",
      "in vious wispr", "envy us wispr", "NVS Visper", "NBS Vesper",
      "Enviousvisper",
    ],
    category: .brand)

  private func corrected(_ input: String, _ terms: [CustomWord] = [enviousWispr]) -> (
    text: String, replacements: Int
  ) {
    let result = WordCorrector().correct(input, against: terms)
    return (result.corrected, result.replacements.count)
  }

  @Test("A no-space alias glued directly to a recognized TLD keeps the TLD")
  func gluedAliasKeepsTLD() {
    // The founder's own reproduction, exactly. Regression pin for #2258-adjacent.
    let result = corrected("Enviousvisper.com")
    #expect(result.text == "EnviousWispr.com")
    #expect(result.replacements == 1)
  }

  @Test(
    "Every recognized TLD is preserved, not only .com",
    arguments: ["com", "org", "io", "co", "dev", "me", "net", "ai", "app", "xyz"])
  func everyRecognizedTLDIsPreserved(_ tld: String) {
    let result = corrected("Enviousvisper.\(tld)")
    #expect(result.text == "EnviousWispr.\(tld)")
    #expect(result.replacements == 1)
  }

  @Test("A suffix outside the recognized-TLD list ALSO survives (Codex round 3)")
  func suffixOutsideTheAllowlistAlsoSurvives() {
    // Superseded by Codex review round 3, P1: the peel trigger used to be
    // `recognizedTLDs` itself, so ".zzz" -- not in that ten-item list --
    // stayed unpeeled and fuzzy matching swallowed it exactly like the
    // original bug. The trigger is now any letter/digit/hyphen run after a
    // dot, so this survives too. `suffixOutsideAllowlistStillSurvives`
    // below covers the same shape for real-looking TLDs; this pins a
    // clearly-not-a-TLD string to prove the trigger isn't secretly still an
    // allowlist under a different name.
    let result = corrected("Enviousvisper.zzz")
    #expect(result.text == "EnviousWispr.zzz")
    #expect(result.replacements == 1)
  }

  @Test("A fuzzy (near-miss spelling) match ALSO keeps a glued TLD")
  func fuzzyMatchAlsoKeepsGluedTLD() {
    // "EnviousWhisper" is not a registered alias verbatim, so this exercises
    // the SIMILARITY-scored passes, not the exact/no-space passes above --
    // previously this input corrected NOTHING (the ".com" noise pulled the
    // similarity score below threshold), matching the founder's third
    // dictation ("EnviousWhisper.com" -> "no change").
    let result = corrected("EnviousWhisper.com")
    #expect(result.text == "EnviousWispr.com")
    #expect(result.replacements == 1)
  }

  @Test("A glued TLD inside a full sentence still corrects and keeps the domain")
  func gluedTLDInsideASentenceStillWorks() {
    let result = corrected("Hey, I keep trying to say Enviousvisper.com but it never works")
    #expect(result.text == "Hey, I keep trying to say EnviousWispr.com but it never works")
    #expect(result.replacements == 1)
  }

  @Test("The spaced alias form is unaffected — regression pin")
  func spacedAliasFormUnaffected() {
    let result = corrected("envious visper dot com")
    // No TLD glued to a single token here ("dot com" is two ordinary spoken
    // words) -- this fix's new branch never engages, and the alias still
    // corrects exactly as it always has.
    #expect(result.text == "EnviousWispr dot com")
    #expect(result.replacements == 1)
  }

  @Test("A TLD-shaped suffix on a word that matches NOTHING is left alone")
  func noMatchLeavesTheTokenAlone() {
    let result = corrected("totallyunrelatedword.com")
    #expect(result.text == "totallyunrelatedword.com")
    #expect(result.replacements == 0)
  }

  // MARK: Codex review findings (PR for #2281) — a saved alias that IS itself
  // a domain must not have its TLD peeled off before the exact lookup runs,
  // and a domain-shaped token must never feed the COMPOUND (multi-token)
  // passes and lose its TLD there instead.

  private static let gitHubDomainAlias = CustomWord(
    canonical: "GitHub.com", aliases: ["githab.com"], category: .brand)

  @Test("An exact alias that is ITSELF a domain still matches whole, unpeeled")
  func exactDomainShapedAliasStillMatches() {
    let result = corrected("githab.com", [Self.gitHubDomainAlias])
    #expect(result.text == "GitHub.com")
    #expect(result.replacements == 1)
  }

  private static let fooBar = CustomWord(
    canonical: "FooBar", aliases: ["foobar"], category: .brand)

  @Test(
    "A domain-shaped token before another word does not feed compound matching and lose its TLD")
  func domainTokenDoesNotFeedCompoundMatch() {
    // "foo.com" + "bar" superficially concatenates to "foobar" -- an accident
    // compound Pass 0 must not act on. Domain-bearing tokens stay opaque to
    // the compound passes exactly as they were before this fix.
    let result = corrected("foo.com bar", [Self.fooBar])
    #expect(result.text == "foo.com bar")
    #expect(result.replacements == 0)
  }

  @Test("Every recognized TLD survives a FUZZY (not just exact) single-word match")
  func everyRecognizedTLDSurvivesFuzzyMatch() {
    // Regression for the fix's own false start: trying the fuzzy passes on
    // the unpeeled token FIRST let several TLD lengths cross threshold and
    // get silently swallowed (org/net/ai/me/io/app all failed before this
    // was caught and corrected). Re-assert every TLD through the fuzzy path
    // specifically, using a near-miss spelling rather than the exact alias.
    for tld in ["com", "org", "io", "co", "dev", "me", "net", "ai", "app", "xyz"] {
      let result = corrected("EnviousWhisper.\(tld)")
      #expect(result.text == "EnviousWispr.\(tld)", "TLD '\(tld)' should survive a fuzzy match")
      #expect(result.replacements == 1, "TLD '\(tld)' should still count as one replacement")
    }
  }

  private static let gitHubBareAlias = CustomWord(
    canonical: "GitHub.com", aliases: ["githab"], category: .brand)

  @Test("A peeled TLD is not duplicated when the matched canonical already carries it")
  func peeledTLDNotDuplicatedWhenCanonicalAlreadyHasIt() {
    // Codex review round 2: canonical "GitHub.com" already IS a domain, but
    // its alias "githab" is bare. "githab.com" misses the (unpeeled) exact
    // Pass 3 -- the alias has no ".com" -- so it falls into the peel-and-
    // retry path, where "githab" DOES exact-match. Blindly reattaching the
    // peeled ".com" would produce "GitHub.com.com".
    let result = corrected("githab.com", [Self.gitHubBareAlias])
    #expect(result.text == "GitHub.com")
    #expect(result.replacements == 1)
  }

  // MARK: Codex review round 3 findings -- the peel trigger, the reattach
  // dedup, and the domain-shaped fuzzy path all needed to widen past the
  // narrow ten-TLD allowlist.

  @Test("A glued suffix OUTSIDE the recognized-TLD allowlist still survives correction")
  func suffixOutsideAllowlistStillSurvives() {
    // Codex review round 3, P1: the peel trigger was `recognizedTLDs`
    // itself, so a suffix like ".us" (not in that ten-item list) left the
    // token unpeeled, and fuzzy matching swallowed it exactly like the
    // original bug. The trigger no longer depends on that allowlist.
    for tld in ["us", "uk", "tech", "info"] {
      let result = corrected("Enviousvisper.\(tld)")
      #expect(result.text == "EnviousWispr.\(tld)", "'.\(tld)' should survive, allowlist or not")
      #expect(result.replacements == 1)
    }
  }

  private static let gitHubDomainAliasNearMiss = CustomWord(
    canonical: "GitHub.com", aliases: ["githab.com"], category: .brand)

  @Test("A near-miss (fuzzy) spelling of a domain-shaped alias still matches unpeeled")
  func fuzzyMatchOnDomainShapedAliasStillWorks() {
    // Codex review round 3, P1: peeling ALWAYS before matching broke fuzzy
    // correction for a domain-valued alias. "githib.com" is a one-letter
    // near miss of the alias "githab.com" -- comparing the whole glued
    // strings (both carrying ".com") scores high; peeling first strips the
    // TLD from only the INPUT side and the match is lost.
    let result = corrected("githib.com", [Self.gitHubDomainAliasNearMiss])
    #expect(result.text == "GitHub.com")
    #expect(result.replacements == 1)
  }

  @Test(
    "A peeled suffix that DIFFERS from the matched canonical's own TLD is still dropped, not appended"
  )
  func mismatchedPeeledSuffixStillDroppedNotAppended() {
    // Codex review round 3, P2: the dedup check only compared the peeled
    // suffix against the SAME suffix on the canonical. Canonical
    // "GitHub.com" matched via bare alias "githab", with input carrying a
    // DIFFERENT recognized TLD (".org"), still produced "GitHub.com.org".
    // The canonical is domain-shaped at all, so its own TLD wins outright.
    let result = corrected("githab.org", [Self.gitHubBareAlias])
    #expect(result.text == "GitHub.com")
    #expect(result.replacements == 1)
  }

  // MARK: Codex review round 4 findings -- exact/user precedence over a
  // fuzzy/pack match reachable only by peeling, and the same narrow-
  // allowlist inconsistency in the dedup check itself.

  private static let githibExactUserAlias = CustomWord(
    canonical: "GitHub Issue Board", aliases: ["githib"], category: .brand, source: .user)
  private static let githabDomainPackAlias = CustomWord(
    canonical: "GitHub.com", aliases: ["githab.com"], category: .brand, source: .pack)

  @Test("A user's own exact alias, reachable only by peeling, still outranks a fuzzy pack match")
  func exactUserAliasOutranksFuzzyPackMatch() {
    // Codex review round 4, P1: the unpeeled domain-restricted FUZZY pass
    // ran before the PEELED exact pass, so a fuzzy pack-tier hit on the raw
    // token ("githib.com" scored against pack alias "githab.com") could
    // preempt the user's own exact alias "githib", which only becomes
    // reachable once the ".com" is peeled off. Exact always beats fuzzy,
    // and user always beats pack -- both must hold regardless of whether
    // peeling is involved.
    let result = corrected(
      "githib.com", [Self.githibExactUserAlias, Self.githabDomainPackAlias])
    #expect(result.text == "GitHub Issue Board.com")
    #expect(result.replacements == 1)
  }

  private static let gitHubUnusualTLDBareAlias = CustomWord(
    canonical: "GitHub.us", aliases: ["githab"], category: .brand)

  @Test("Dedup recognizes a saved domain using a TLD outside the old allowlist too")
  func dedupRecognizesDomainCanonicalOutsideAllowlist() {
    // Codex review round 4, P2: `isDomainShaped` still used the narrow
    // ten-item TLD list even after the PEEL trigger was widened past it, so
    // a saved canonical like "GitHub.us" (".us" not in that list) was not
    // recognized as domain-shaped -- "githab.org" through this alias
    // produced "GitHub.us.org" instead of trusting the canonical's own TLD.
    let result = corrected("githab.org", [Self.gitHubUnusualTLDBareAlias])
    #expect(result.text == "GitHub.us")
    #expect(result.replacements == 1)
  }

  @Test("A near-miss of a domain-shaped alias using a TLD outside the old allowlist still matches")
  func fuzzyDomainMatchOutsideAllowlistStillWorks() {
    // Codex review round 4, P2, other half: the raw domain-restricted fuzzy
    // pass (round 3, P1) is gated by the same `isDomainShaped` check, so a
    // domain-shaped alias using an unusual TLD was invisible to it too.
    let alias = CustomWord(canonical: "GitHub.us", aliases: ["githab.us"], category: .brand)
    let result = corrected("githib.us", [alias])
    #expect(result.text == "GitHub.us")
    #expect(result.replacements == 1)
  }

  // MARK: Not a US-only fix. Founder correction (2026-08-21): this app is
  // used internationally, so the domain-suffix shape has to work for
  // accented, non-Latin-script, and multi-part (ccTLD + SLD) domains too --
  // not only plain ASCII words glued to ".com".

  @Test("A single-word ACCENTED brand keeps a glued TLD")
  func accentedSingleWordBrandKeepsGluedTLD() {
    let word = CustomWord(canonical: "Café", aliases: ["cafeh"], category: .brand)
    let result = corrected("cafeh.com", [word])
    #expect(result.text == "Café.com")
    #expect(result.replacements == 1)
  }

  @Test("A CYRILLIC brand corrects a near-miss and keeps a glued TLD")
  func cyrillicBrandCorrectsFuzzyMissAndKeepsGluedTLD() {
    let word = CustomWord(canonical: "Привет", aliases: ["привет"], category: .brand)
    let result = corrected("привед.com", [word])
    #expect(result.text == "Привет.com")
    #expect(result.replacements == 1)
  }

  @Test(
    "A two-part ccTLD (.co.jp, .co.uk, .com.au) is peeled and reattached whole, not just its last label"
  )
  func twoPartCcTLDPeeledAsOneUnit() {
    // Common everyday domain shape outside the US -- Japan (.co.jp), the UK
    // (.co.uk), Australia (.com.au). Peeling only the LAST label (the
    // original design) left "GitHub.co" behind and lost ".jp" outright, or
    // failed to match a bare alias at all because the leftover ".co" was
    // still noise on the comparison.
    let jp = CustomWord(canonical: "任天堂", aliases: ["にんてんどう"], category: .brand)
    #expect(corrected("にんてんどう.co.jp", [jp]).text == "任天堂.co.jp")

    let uk = CustomWord(canonical: "GitHub", aliases: ["githab"], category: .brand)
    #expect(corrected("githab.co.uk", [uk]).text == "GitHub.co.uk")

    let au = CustomWord(canonical: "EnviousWispr", aliases: ["Enviousvisper"], category: .brand)
    #expect(corrected("Enviousvisper.com.au", [au]).text == "EnviousWispr.com.au")
  }

  @Test("A canonical that is ITSELF a two-part ccTLD domain suppresses reattach correctly")
  func canonicalItselfTwoPartCcTLDSuppressesReattach() {
    // The dedup check (finding P2) must recognize "GitHub.co.uk" as
    // domain-shaped just as readily as "GitHub.com", so a mismatched
    // peeled suffix is still dropped rather than appended.
    let word = CustomWord(canonical: "GitHub.co.uk", aliases: ["githab"], category: .brand)
    let result = corrected("githab.org", [word])
    #expect(result.text == "GitHub.co.uk")
    #expect(result.replacements == 1)
  }

  // MARK: Codex review round 5 findings -- the domain-restricted fuzzy pass
  // must not run at all for a token with no dot, and a numeric-only tail is
  // never a domain suffix.

  private static let enviousWisprCloseNeighbors = CustomWord(
    canonical: "Right",
    aliases: ["enviouswhispr"],
    category: .brand)
  private static let enviousWisprDomainDistractor = CustomWord(
    canonical: "Wrong.com",
    aliases: ["enviouswhisper.com"],
    category: .brand)

  @Test("An ordinary no-dot token never runs the domain-restricted fuzzy pass at all")
  func ordinaryNoDotTokenSkipsDomainRestrictedFuzzy() {
    // Codex review round 5, P1: the domain-restricted fuzzy pass used to run
    // unconditionally, even for a token with no dot at all -- comparing it
    // against domain-shaped candidates it has no business being compared
    // against. "enviouswhisper" (no dot) could score against the
    // domain-shaped "enviouswhisper.com" candidate purely on shared prefix
    // length, preempting the correct bare candidate "enviouswhispr" that
    // only step 4 (peeled, unrestricted -- a no-op here since there's
    // nothing to peel) would otherwise have found.
    let result = corrected(
      "enviouswhisper",
      [Self.enviousWisprCloseNeighbors, Self.enviousWisprDomainDistractor])
    #expect(result.text == "Right")
    #expect(result.replacements == 1)
  }

  private static let versionOneAlias = CustomWord(canonical: "VersionOne", aliases: ["v1"])

  @Test("A numeric-only tail is never treated as a domain suffix")
  func numericOnlyTailIsNeverADomainSuffix() {
    // Codex review round 5, P2: a real TLD label is never purely numeric.
    // Without this exclusion, "v1.2" (an ordinary version number) peeled to
    // bare "v1", exact-matched an unrelated alias "v1", and produced
    // "VersionOne.2" -- correcting text that was never a domain at all.
    let result = corrected("v1.2", [Self.versionOneAlias])
    #expect(result.text == "v1.2")
    #expect(result.replacements == 0)
  }

  @Test("An IP-shaped token is never treated as a domain suffix")
  func ipShapedTokenIsNeverADomainSuffix() {
    // Same root as the version-number case: every label of an IPv4-style
    // token is numeric, so the LAST label check alone is what excludes it
    // (an IP is not glued to a real custom word in practice, but nothing
    // here should coincidentally rewrite one).
    let result = corrected("192.168.1.1", [Self.versionOneAlias])
    #expect(result.text == "192.168.1.1")
    #expect(result.replacements == 0)
  }

  // MARK: Codex review round 6 findings -- a dotted PRODUCT name is not a
  // domain even though it structurally looks like one, and an alphanumeric
  // version/build tail is not a domain suffix either.

  private static let nodeJSAlias = CustomWord(canonical: "Node.js", aliases: ["nodejs"])

  @Test("A dotted product-name canonical does NOT suppress a real glued TLD")
  func dottedProductNameCanonicalDoesNotSuppressGluedTLD() {
    // Codex review round 6, P1: "Node.js" is a real, common product name
    // that happens to end in a dot-suffix ("D3.js", "Vue.js", "Chart.js"
    // are the same shape), but it is not a domain. The old purely
    // structural `isDomainShaped` treated any all-letters tail as a domain
    // and suppressed the user's own glued ".com", producing "Node.js"
    // instead of "Node.js.com". Only a REAL TLD suppresses the reattach.
    let result = corrected("nodejs.com", [Self.nodeJSAlias])
    #expect(result.text == "Node.js.com")
    #expect(result.replacements == 1)
  }

  @Test("An alphanumeric version/build tail is never treated as a domain suffix")
  func alphanumericVersionTailIsNeverADomainSuffix() {
    // Codex review round 6, P2: the round-5 fix excluded only PURELY
    // numeric tails, so "v1.2beta" and "v1.2.3rc1" -- ordinary version/
    // build strings with letters mixed in -- still slipped through and
    // rewrote to "VersionOne.2beta" / "VersionOne.2.3rc1". A real TLD
    // label is ALL LETTERS (current ICANN policy bars digits from the TLD
    // position entirely), so any digit in the final label now excludes it.
    for input in ["v1.2beta", "v1.2.3rc1", "v1.0", "v1.2rc"] {
      let result = corrected(input, [Self.versionOneAlias])
      #expect(result.text == input, "'\(input)' must stay unchanged, got '\(result.text)'")
      #expect(result.replacements == 0)
    }
  }
}
