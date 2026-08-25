import Testing

@testable import EnviousWisprAppKit

/// One authority decides which designs may be offered (#2376 Phase 4, C4).
///
/// **The picker does not get its own opinion, and this suite is what says so.**
/// The plan names catalog-versus-Settings drift as the risk to watch for the
/// appearance picker: two places deciding which designs are compatible, agreeing
/// on the day they are written and diverging the day a design is added.
/// `PillCatalog.offers` is defined in terms of `PillDesignSelections.resolve`, so
/// the two cannot disagree without `resolve` disagreeing with itself — and every
/// row here is generated over the cross-product, so a design added later is swept
/// with no edit.
///
/// **Product Outcome.** When these fail a user is offered a pill design that
/// cannot show the words their machine can produce, or is refused one that can.
@Suite(.tags(.productOutcome))
struct PillOfferabilityTests {

  // MARK: - resolve fails closed in BOTH directions

  /// **The mirror direction, which Phase 3 left open.** It guarded only "the
  /// capability has words and the design cannot hold them". The other way round —
  /// a with-words design selected for a pill that will show none — was accepted
  /// with `substituted: false`, and `RecordingDirectorCaptureTests` measures what
  /// that produces: a live display provider installed and a 400-point window on a
  /// machine with no preview, which is a wide empty panel.
  @Test(
    "a design that cannot hold the words the capability has is refused",
    arguments: RecordingPillDesign.allCases)
  func withWordsMismatchSubstitutes(chosen: RecordingPillDesign) {
    let resolution = PillDesignSelections(withoutWords: chosen, withWords: chosen)
      .resolve(capabilityHasWords: true)
    if chosen.canHoldWords {
      #expect(resolution.substituted == false, "\(chosen) can hold words and was substituted")
      #expect(resolution.design == chosen)
    } else {
      #expect(resolution.substituted, "\(chosen) cannot hold words and was accepted anyway")
      #expect(resolution.design == PillDesignSelections.canonicalWithWords)
      #expect(resolution.design.canHoldWords, "the substitute cannot hold words either")
    }
  }

  @Test(
    "a design that holds words is refused for a pill that will show none",
    arguments: RecordingPillDesign.allCases)
  func withoutWordsMismatchSubstitutes(chosen: RecordingPillDesign) {
    let resolution = PillDesignSelections(withoutWords: chosen, withWords: chosen)
      .resolve(capabilityHasWords: false)
    if chosen.canHoldWords {
      #expect(
        resolution.substituted,
        """
        \(chosen) holds words and was accepted for a pill with none. That is the \
        combination measured to install a live display provider and size a 400-point \
        window on a machine with no preview.
        """)
      #expect(resolution.design == PillDesignSelections.canonicalWithoutWords)
      #expect(resolution.design.canHoldWords == false, "the substitute holds words")
    } else {
      #expect(resolution.substituted == false, "\(chosen) holds no words and was substituted")
      #expect(resolution.design == chosen)
    }
  }

  /// The canonical substitutes must themselves be compatible, or a substitution
  /// hands back a value the next `resolve` would substitute again.
  @Test("the canonical substitutes are compatible with the group they serve")
  func canonicalSubstitutesAreCompatible() {
    #expect(PillDesignSelections.canonicalWithWords.canHoldWords)
    #expect(PillDesignSelections.canonicalWithoutWords.canHoldWords == false)
  }

  // MARK: - offers is resolve, and cannot drift from it

  /// **Generated over the whole cross-product**, so this sweeps a design added
  /// later with no edit here. Hand-picked rows cover the cells the author thought
  /// of, which is the same blind spot the check exists to cover for.
  @Test(
    "offers agrees with resolve, in both directions, for every design",
    arguments: RecordingPillDesign.allCases, [true, false])
  func offersIsDefinedByResolve(design: RecordingPillDesign, hasWords: Bool) {
    let offered = PillCatalog.offers(design, capabilityHasWords: hasWords)
    let resolution = PillDesignSelections(withoutWords: design, withWords: design)
      .resolve(capabilityHasWords: hasWords)
    #expect(
      offered == (resolution.substituted == false),
      """
      offers(\(design), hasWords: \(hasWords)) said \(offered) while resolve \
      substituted=\(resolution.substituted). These are one rule; if they can \
      disagree, the picker has an opinion of its own and will drift from the pill.
      """)
  }

  /// The paired positive and negative, so the sweep cannot pass by answering the
  /// same thing everywhere: every design is offerable in exactly one group.
  @Test(
    "each design is offered in exactly one capability state",
    arguments: RecordingPillDesign.allCases)
  func eachDesignBelongsToOneGroup(design: RecordingPillDesign) {
    let inWords = PillCatalog.offers(design, capabilityHasWords: true)
    let inSilence = PillCatalog.offers(design, capabilityHasWords: false)
    #expect(
      inWords != inSilence,
      """
      \(design) is offered in \(inWords && inSilence ? "both" : "neither") capability \
      state. A design offered in both is one the picker would show twice; a design \
      offered in neither can never be chosen at all.
      """)
  }

  // MARK: - The groups partition, so no design is unreachable

  @Test("the two groups partition every design exactly once")
  func groupsPartitionAllDesigns() {
    let withWords = PillCatalog.designs(holdingWords: true)
    let without = PillCatalog.designs(holdingWords: false)
    #expect(Set(withWords).isDisjoint(with: Set(without)))
    #expect(
      Set(withWords).union(without) == Set(RecordingPillDesign.allCases),
      """
      the groups cover \(withWords.count + without.count) of \
      \(RecordingPillDesign.allCases.count) designs, so one is offerable nowhere and \
      the picker cannot show it.
      """)
    #expect(!withWords.isEmpty, "no design can hold words, so the with-words group is empty")
    #expect(!without.isEmpty, "every design holds words, so the without-words group is empty")
  }

  /// Group membership and offerability must agree, or the picker lays a design
  /// out under a heading it is then greyed out beneath.
  @Test(
    "a design's group is the state it is offered in",
    arguments: RecordingPillDesign.allCases)
  func groupMembershipMatchesOfferability(design: RecordingPillDesign) {
    for hasWords in [true, false] {
      let inGroup = PillCatalog.designs(holdingWords: hasWords).contains(design)
      #expect(
        inGroup == PillCatalog.offers(design, capabilityHasWords: hasWords),
        "\(design) is grouped and offered differently at hasWords=\(hasWords)")
    }
  }
}
