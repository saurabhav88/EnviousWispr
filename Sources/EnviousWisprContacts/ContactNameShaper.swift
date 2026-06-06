import Foundation

/// One contact name reduced to a single canonical term to import, tagged with
/// the originating contact so the coordinator can track per-contact provenance.
public struct ShapedName: Sendable, Equatable {
  public let contactID: String
  public let canonical: String

  public init(contactID: String, canonical: String) {
    self.contactID = contactID
    self.canonical = canonical
  }
}

/// Pure logic that turns raw contact names into the exact set of canonical terms
/// to import. This is the §3.4 design hinge in code.
///
/// `WordCorrector` registers every space-free (single-token) canonical as an
/// EXACT self-entry that rewrites the spoken word unconditionally on Pass 3 —
/// no fuzzy/threshold/stopword guard. So a lone common word like "Will" or
/// "May" imported as a single-token canonical would capitalize that word every
/// time the user dictates it. Multi-word canonicals get NO exact self-entry
/// (they fire only on the full phrase). The shaping rules below exploit that:
///
/// - When both names are present, always emit the full `"First Last"` canonical
///   (safe: multi-word, phrase-only) — this covers the name in context even when
///   neither part survives as a lone token.
/// - Additionally emit `given` or `family` ALONE only when that token is
///   distinctive (not a common English word, length ≥ 2, letters-only) so
///   "Ramachandran" / "Vasquez" still correct when said alone.
/// - A lone common-word name (in the stoplist) is skipped as a single token; the
///   full-name entry still covers it. A single-field contact whose only name is a
///   common word produces nothing (better than corrupting speech).
public enum ContactNameShaper {
  /// Lone tokens shorter than this are not imported on their own (still covered
  /// by the full-name entry). Guards single letters / initials.
  static let minLoneTokenLength = 2

  public static func shape(_ candidates: [CandidateName]) -> [ShapedName] {
    var out: [ShapedName] = []
    for candidate in candidates {
      let given = candidate.given
      let family = candidate.family
      let givenValid = isNameLike(given)
      let familyValid = isNameLike(family)

      var canonicals: [String] = []
      if givenValid && familyValid {
        canonicals.append("\(given) \(family)")
        if isDistinctiveLoneToken(given) { canonicals.append(given) }
        if isDistinctiveLoneToken(family) { canonicals.append(family) }
      } else if givenValid {
        if isDistinctiveLoneToken(given) { canonicals.append(given) }
      } else if familyValid {
        if isDistinctiveLoneToken(family) { canonicals.append(family) }
      }

      // De-dupe within one contact (e.g. given == family) — case-insensitive.
      var seen = Set<String>()
      for canonical in canonicals where seen.insert(canonical.lowercased()).inserted {
        out.append(ShapedName(contactID: candidate.contactID, canonical: canonical))
      }
    }
    return out
  }

  /// A token is name-like if it has at least one letter and no decimal digit
  /// (rejects phone-number-in-name junk while allowing accents, hyphens,
  /// apostrophes: "O'Brien", "Jean-Luc", "Nguyễn").
  static func isNameLike(_ token: String) -> Bool {
    guard !token.isEmpty else { return false }
    var hasLetter = false
    for scalar in token.unicodeScalars {
      if CharacterSet.decimalDigits.contains(scalar) { return false }
      if CharacterSet.letters.contains(scalar) { hasLetter = true }
    }
    return hasLetter
  }

  static func isDistinctiveLoneToken(_ token: String) -> Bool {
    guard isNameLike(token) else { return false }
    guard token.count >= minLoneTokenLength else { return false }
    return !commonWordStoplist.contains(token.lowercased())
  }

  /// Common English words that are also common given/family names. A lone token
  /// matching one of these is NOT imported on its own (the full-name entry still
  /// covers it). Erring generous on purpose: a false skip merely loses lone-token
  /// correction, while a miss capitalizes ordinary speech. Extensible.
  static let commonWordStoplist: Set<String> = [
    // Modal verbs / very high-frequency words that are also names.
    "will", "may", "mark", "bill", "drew", "rose", "grant", "chase", "chance",
    "hope", "grace", "faith", "joy", "art", "guy", "frank", "rich", "wade",
    "reed", "reid", "lance", "miles", "jack", "pat", "ray", "dean", "dale",
    // Seasons / months / time words used as names.
    "summer", "autumn", "april", "june", "august", "dawn", "noel",
    // Flowers / plants / nature names.
    "holly", "ivy", "lily", "daisy", "rose", "violet", "iris", "fern", "olive",
    "sage", "basil", "rosemary", "ginger", "jasmine", "poppy", "heather",
    "willow", "hazel", "laurel", "myrtle", "berry", "cherry", "plum",
    // Gems / precious words.
    "pearl", "ruby", "amber", "crystal", "jade", "opal", "coral", "gem",
    // Animals / birds used as names.
    "robin", "jay", "wren", "dove", "lark", "drake", "fox", "wolf", "bear",
    "hawk", "finch", "raven", "swift", "bird",
    // Sky / water / earth words.
    "star", "sky", "rain", "storm", "river", "brook", "lake", "bay", "ocean",
    "sea", "stone", "wood", "woods", "cliff", "glen", "ford", "heath", "vale",
    "field", "fields", "hill", "hills", "lane", "park", "parks", "meadow",
    // Colors used as surnames.
    "gray", "grey", "brown", "white", "black", "green",
    // Occupational surnames that are common words.
    "king", "knight", "baker", "cook", "hunter", "fisher", "carter", "potter",
    "porter", "mason", "marshall", "marshal", "sawyer", "archer", "chandler",
    "fletcher", "weaver", "tanner", "shepherd", "gardener", "page", "abbott",
    "bishop", "major", "sterling", "noble", "earl", "duke", "bell",
    // Sweet / mood / texture nicknames.
    "honey", "candy", "sugar", "sunny", "sandy", "misty", "stormy", "rocky",
    "buddy", "sonny", "merry", "melody", "harmony", "bliss",
    // Short function words (defensive — a malformed or single-field contact
    // could carry one; length guard already drops single letters).
    "an", "the", "is", "it", "in", "on", "of", "to", "at", "as", "be", "by",
    "do", "go", "he", "if", "me", "my", "no", "or", "so", "up", "us", "we",
  ]
}
