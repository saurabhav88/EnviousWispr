import NaturalLanguage

/// The production word-class check behind `CursorInsertionRepair`'s German
/// casing branch.
///
/// Kept apart from `CursorInsertionRepair` so that type stays pure and its tests
/// need no `NaturalLanguage` — the same shape as the injected lexicon.
enum GermanWordClass {

  /// Whether the FIRST word of `text` is being used as a noun.
  ///
  /// Two measured decisions are baked in here and neither is arbitrary:
  ///
  /// **The dictation is tagged ALONE, never with the surrounding document.**
  /// Adding the document's left context made accuracy WORSE, flipping `morgen`
  /// (tomorrow, an adverb) to `Morgen` (morning, a noun). It is also the cheaper
  /// and more private option.
  ///
  /// **The word is left CAPITALISED, as polish produced it.** Lowercasing it
  /// first collapses the tagger to 52% and mislabels 23 of 25 real nouns as
  /// adverbs, because a lowercase sentence-initial word is ungrammatical German
  /// that the model never saw. At sentence-start position the capital carries no
  /// information in German — every German sentence starts with one — which is
  /// what forces the tagger back onto lexical knowledge.
  ///
  /// Fails CLOSED: no tag means "treat it as a noun", which keeps the capital.
  static let isNounInContext: @Sendable (String) -> Bool = { text in
    guard !text.isEmpty else { return true }
    let tagger = NLTagger(tagSchemes: [.lexicalClass])
    tagger.string = text
    tagger.setLanguage(.german, range: text.startIndex..<text.endIndex)
    guard
      let tag = tagger.tag(at: text.startIndex, unit: .word, scheme: .lexicalClass).0
    else { return true }
    return tag == .noun || tag == .personalName || tag == .placeName
      || tag == .organizationName
  }
}
