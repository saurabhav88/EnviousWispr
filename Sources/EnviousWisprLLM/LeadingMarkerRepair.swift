import Foundation

/// Deterministic AFM-only repair for deleted sentence-leading discourse
/// markers (#963). The on-device model keeps stripping intentional openers
/// ("Actually", "Basically", ...) despite explicit prompt rules — measured
/// 13/20 on the onset-marker corpus with the strongest prompt wording, with
/// the model deleting "actually" from inputs nearly identical to the prompt's
/// own KEEP example. Instruction-only preservation is a ceiling; this helper
/// restores the marker after the fact.
///
/// Scope guards (Codex grounded review, 2026-06-12):
///   - English-only (`expectedLanguage == "en"`); nil/unknown skips.
///   - Runs on the post-`EnviousOutputFilter` text (wrapper/preamble already
///     stripped). When the filter fell back to raw, the raw input still
///     starts with the marker, so the repair no-ops naturally.
///   - Blank output returns unchanged (the connector's empty-response guard
///     owns that path).
///   - Fires ONLY when the dictation's first token is a marker and the
///     polished output no longer starts with it — revision collapses like
///     "set it to thirty, actually make it sixty" never begin with a marker,
///     so they are untouched.
enum LeadingMarkerRepair {

  /// Marker → whether the restored opener takes a trailing comma.
  /// "Literally" reads as an intensifier ("Literally every slot is taken"),
  /// not a set-off discourse comment, so it gets a space instead.
  static let markers: [String: Bool] = [
    "actually": true,
    "basically": true,
    "honestly": true,
    "well": true,
    "overall": true,
    "literally": false,
  ]

  /// First-person tokens that keep their capital when the repair prepends a
  /// marker in front of them. Stored in `normalize`d form (lowercased,
  /// apostrophes stripped) so "I'm" → "im" matches.
  private static let keepCapitalized: Set<String> = ["i", "im", "ill", "ive", "id"]

  /// Restore a deleted leading discourse marker. Returns `output` unchanged
  /// whenever any scope guard fails.
  static func repair(input: String, output: String, expectedLanguage: String?) -> String {
    guard expectedLanguage == "en" else { return output }

    let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedOutput.isEmpty else { return output }

    let inputTokens = input.split(whereSeparator: \.isWhitespace)
    // A marker-only dictation has nothing to repair against (and the
    // pipeline's too-short gate skips polish well before this point).
    guard inputTokens.count >= 2 else { return output }

    guard let marker = markers.keys.first(where: { $0 == normalize(inputTokens[0]) })
    else { return output }

    let outputTokens = trimmedOutput.split(whereSeparator: \.isWhitespace)
    guard let firstOutputToken = outputTokens.first else { return output }
    // Output still opens with the marker — nothing was deleted.
    guard normalize(firstOutputToken) != marker else { return output }

    let needsComma = markers[marker] ?? true
    let capitalizedMarker = marker.prefix(1).uppercased() + marker.dropFirst()
    let separator = needsComma ? ", " : " "

    // Lowercase the output's old opening word ONLY when it provably
    // corresponds to the input's second token (so "Monday" or other proper
    // nouns the model capitalized for its own reasons stay intact), is not a
    // first-person form, and is not acronym-shaped ("API" must not become
    // "aPI" — any uppercase after the first character means the whole word's
    // casing is intentional, not sentence-initial).
    var body = trimmedOutput
    let firstNormalized = normalize(firstOutputToken)
    let restIsLowercase = firstOutputToken.dropFirst().unicodeScalars.allSatisfy {
      !CharacterSet.uppercaseLetters.contains($0)
    }
    if !keepCapitalized.contains(firstNormalized),
      firstNormalized == normalize(inputTokens[1]),
      restIsLowercase,
      let firstScalar = body.unicodeScalars.first,
      CharacterSet.uppercaseLetters.contains(firstScalar)
    {
      body = body.prefix(1).lowercased() + body.dropFirst()
    }

    return capitalizedMarker + separator + body
  }

  /// Lowercase a token and strip punctuation so "Actually," / "actually" /
  /// "Let's" / "lets" compare as equal across the ASR/polish boundary.
  private static func normalize(_ token: Substring) -> String {
    String(token)
      .lowercased()
      .replacingOccurrences(of: "'", with: "")
      .replacingOccurrences(of: "\u{2019}", with: "")
      .trimmingCharacters(in: .punctuationCharacters)
  }
}
