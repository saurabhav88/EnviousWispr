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
/// to import: each distinctive name becomes its OWN single-token canonical.
///
/// `WordCorrector` registers every space-free (single-token) canonical as an
/// EXACT self-entry that rewrites the spoken word unconditionally on Pass 3, with
/// no fuzzy/threshold/stopword guard. A space-containing canonical gets NO such
/// self-entry, so a combined "First Last" entry corrected nothing; we no longer
/// emit one. The per-name rules below exploit the single-token behavior:
///
/// - Emit `given` and/or `family` ALONE, each only when that token is distinctive
///   (not a common English word, length >= 2, letters-only) so "Ramachandran" /
///   "Vasquez" still correct when said.
/// - A lone common-word name (in the stoplist) is skipped: importing "Will" or
///   "May" as a single-token canonical would capitalize that ordinary word on
///   every dictation. A contact whose only names are common words yields nothing
///   (better than corrupting speech).
public enum ContactNameShaper {
  /// Lone tokens shorter than this are not imported on their own (still covered
  /// by the full-name entry). Guards single letters / initials.
  static let minLoneTokenLength = 2

  public static func shape(_ candidates: [CandidateName]) -> [ShapedName] {
    var out: [ShapedName] = []
    for candidate in candidates {
      // Per-name shaping: each distinctive name becomes its own single-token
      // canonical. No combined "First Last" entry (a space-containing canonical
      // gets no exact self-entry in WordCorrector, so it corrected nothing).
      var canonicals: [String] = []
      if isDistinctiveLoneToken(candidate.given) { canonicals.append(candidate.given) }
      if isDistinctiveLoneToken(candidate.family) { canonicals.append(candidate.family) }

      // De-dupe within one contact (e.g. given == family), case-insensitive.
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

  /// Whether `token` is in the common-word stoplist (case-insensitive). Exposed
  /// `package` so the import-side alias enrichment can drop any generated alias
  /// that is itself a common word: an alias DOES enter `WordCorrector`'s
  /// unconditional single-alias self-map, so a common-word alias would rewrite
  /// ordinary speech. PostProcessing cannot import this module, so the filter
  /// lives at the AppKit enrichment call site (#636 follow-up).
  package static func isCommonWord(_ token: String) -> Bool {
    commonWordStoplist.contains(token.lowercased())
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
