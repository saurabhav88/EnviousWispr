import Testing

@testable import EnviousWisprPostProcessing

// The deterministic cursor-insertion repair (#1785 Chunk 2).
//
// The 52-case matrix is 13 caret situations x 4 realistic payloads, GENERATED
// from the frozen prototype rather than transcribed, so a mistyped expectation
// cannot quietly bless wrong behaviour. It carries the four defects the matrix
// itself caught: a double period, the single-character comma-versus-period
// misclassification, a mid-word stray period, and the opening-quote path that
// previously reached the right answer for the wrong reason.
//
// Repair MECHANICS are tested against an injected lexicon matching the
// prototype. The shipped production lexicon deliberately does not contain
// arbitrary object nouns such as `store`, and it was not padded to preserve a
// prototype illustration; `OrdinaryLowercaseLexiconTests` covers the real one.
@Suite("CursorInsertionRepair")
struct CursorInsertionRepairTests {

  struct MatrixCase: Sendable, CustomStringConvertible {
    let caret: String
    let left: String
    let right: String
    let payload: String
    let expectedRepaired: String?
    let expectedDocument: String?
    let expectedRules: [CursorInsertionRepair.AppliedRule]

    var description: String { "\(payload) @ \(caret)" }
  }

  /// The prototype's representative word set. Proves the SHAPE of the rule
  /// without depending on the production lexicon's membership decisions.
  static let prototypeLexicon = OrdinaryLowercaseLexicon(
    words: [
      "store", "the", "and", "but", "so", "then", "because", "which", "that",
      "what", "if", "when", "where", "while", "or", "just", "also", "really",
      "testing", "yesterday", "today", "tomorrow", "it", "this", "we", "they",
      "pricing", "integration", "legal", "next",
    ],
    isAvailable: true)

  static let protectedWords: Set<String> = ["TL;DR", "iPhone", "GitHub"]

  // GENERATED from docs/feature-requests/issue-1785-artifacts/
  // cursor_repair_v2.py by emit_matrix_fixture.py. The prototype is the
  // frozen contract; these rows are not hand-written, because a mistyped
  // expectation would bless wrong behaviour instead of catching it.
  static let matrix: [MatrixCase] = [
    MatrixCase(
      caret: "empty field",
      left: "",
      right: "",
      payload: "Store today.",
      expectedRepaired: "Store today. ",
      expectedDocument: "Store today. ",
      expectedRules: [.caseKept(.nothingLeft), .trailingSpace]),
    MatrixCase(
      caret: "mid-word",
      left: "I went to the sto",
      right: "re today",
      payload: "Store today.",
      expectedRepaired: nil,
      expectedDocument: nil,
      expectedRules: [.refusedInsideWord]),
    MatrixCase(
      caret: "mid-sentence, text right",
      left: "I went to the ",
      right: "yesterday",
      payload: "Store today.",
      expectedRepaired: "store today ",
      expectedDocument: "I went to the store today yesterday",
      expectedRules: [.lowercasedFirst, .droppedTerminalPeriod, .trailingSpace]),
    MatrixCase(
      caret: "after letter, no space",
      left: "I went to the",
      right: "",
      payload: "Store today.",
      expectedRepaired: " store today. ",
      expectedDocument: "I went to the store today. ",
      expectedRules: [.leadingSpace, .lowercasedFirst, .trailingSpace]),
    MatrixCase(
      caret: "after full stop + space",
      left: "I went home. ",
      right: "",
      payload: "Store today.",
      expectedRepaired: "Store today. ",
      expectedDocument: "I went home. Store today. ",
      expectedRules: [.caseKept(.afterTerminator), .trailingSpace]),
    MatrixCase(
      caret: "after comma + space",
      left: "I went home, ",
      right: "",
      payload: "Store today.",
      expectedRepaired: "store today. ",
      expectedDocument: "I went home, store today. ",
      expectedRules: [.lowercasedFirst, .trailingSpace]),
    MatrixCase(
      caret: "after full stop, no space",
      left: "I went home.",
      right: "",
      payload: "Store today.",
      expectedRepaired: " Store today. ",
      expectedDocument: "I went home. Store today. ",
      expectedRules: [.leadingSpace, .caseKept(.afterTerminator), .trailingSpace]),
    MatrixCase(
      caret: "start of new line",
      left: "First line.\n",
      right: "",
      payload: "Store today.",
      expectedRepaired: "Store today. ",
      expectedDocument: "First line.\nStore today. ",
      expectedRules: [.caseKept(.lineStart), .trailingSpace]),
    MatrixCase(
      caret: "after opening quote",
      left: "He said \"",
      right: "",
      payload: "Store today.",
      expectedRepaired: "Store today. ",
      expectedDocument: "He said \"Store today. ",
      expectedRules: [.caseKept(.afterOpener), .trailingSpace]),
    MatrixCase(
      caret: "before a full stop",
      left: "I went to the ",
      right: ".",
      payload: "Store today.",
      expectedRepaired: "store today",
      expectedDocument: "I went to the store today.",
      expectedRules: [
        .lowercasedFirst, .droppedTerminalPeriod, .trailingSpaceSkipped(.rightIsPunctuation),
      ]),
    MatrixCase(
      caret: "after digit",
      left: "I bought 5",
      right: "",
      payload: "Store today.",
      expectedRepaired: " store today. ",
      expectedDocument: "I bought 5 store today. ",
      expectedRules: [.leadingSpace, .lowercasedFirst, .trailingSpace]),
    MatrixCase(
      caret: "after colon",
      left: "Note: ",
      right: "",
      payload: "Store today.",
      expectedRepaired: "store today. ",
      expectedDocument: "Note: store today. ",
      expectedRules: [.lowercasedFirst, .trailingSpace]),
    MatrixCase(
      caret: "multiple spaces after stop",
      left: "I went home.   ",
      right: "",
      payload: "Store today.",
      expectedRepaired: "Store today. ",
      expectedDocument: "I went home.   Store today. ",
      expectedRules: [.caseKept(.afterTerminator), .trailingSpace]),
    MatrixCase(
      caret: "empty field",
      left: "",
      right: "",
      payload: "TL;DR.",
      expectedRepaired: "TL;DR. ",
      expectedDocument: "TL;DR. ",
      expectedRules: [.caseKept(.nothingLeft), .trailingSpace]),
    MatrixCase(
      caret: "mid-word",
      left: "I went to the sto",
      right: "re today",
      payload: "TL;DR.",
      expectedRepaired: nil,
      expectedDocument: nil,
      expectedRules: [.refusedInsideWord]),
    MatrixCase(
      caret: "mid-sentence, text right",
      left: "I went to the ",
      right: "yesterday",
      payload: "TL;DR.",
      expectedRepaired: "TL;DR ",
      expectedDocument: "I went to the TL;DR yesterday",
      expectedRules: [.caseSkipped(.protectedWord), .droppedTerminalPeriod, .trailingSpace]),
    MatrixCase(
      caret: "after letter, no space",
      left: "I went to the",
      right: "",
      payload: "TL;DR.",
      expectedRepaired: " TL;DR. ",
      expectedDocument: "I went to the TL;DR. ",
      expectedRules: [.leadingSpace, .caseSkipped(.protectedWord), .trailingSpace]),
    MatrixCase(
      caret: "after full stop + space",
      left: "I went home. ",
      right: "",
      payload: "TL;DR.",
      expectedRepaired: "TL;DR. ",
      expectedDocument: "I went home. TL;DR. ",
      expectedRules: [.caseKept(.afterTerminator), .trailingSpace]),
    MatrixCase(
      caret: "after comma + space",
      left: "I went home, ",
      right: "",
      payload: "TL;DR.",
      expectedRepaired: "TL;DR. ",
      expectedDocument: "I went home, TL;DR. ",
      expectedRules: [.caseSkipped(.protectedWord), .trailingSpace]),
    MatrixCase(
      caret: "after full stop, no space",
      left: "I went home.",
      right: "",
      payload: "TL;DR.",
      expectedRepaired: " TL;DR. ",
      expectedDocument: "I went home. TL;DR. ",
      expectedRules: [.leadingSpace, .caseKept(.afterTerminator), .trailingSpace]),
    MatrixCase(
      caret: "start of new line",
      left: "First line.\n",
      right: "",
      payload: "TL;DR.",
      expectedRepaired: "TL;DR. ",
      expectedDocument: "First line.\nTL;DR. ",
      expectedRules: [.caseKept(.lineStart), .trailingSpace]),
    MatrixCase(
      caret: "after opening quote",
      left: "He said \"",
      right: "",
      payload: "TL;DR.",
      expectedRepaired: "TL;DR. ",
      expectedDocument: "He said \"TL;DR. ",
      expectedRules: [.caseKept(.afterOpener), .trailingSpace]),
    MatrixCase(
      caret: "before a full stop",
      left: "I went to the ",
      right: ".",
      payload: "TL;DR.",
      expectedRepaired: "TL;DR",
      expectedDocument: "I went to the TL;DR.",
      expectedRules: [
        .caseSkipped(.protectedWord), .droppedTerminalPeriod,
        .trailingSpaceSkipped(.rightIsPunctuation),
      ]),
    MatrixCase(
      caret: "after digit",
      left: "I bought 5",
      right: "",
      payload: "TL;DR.",
      expectedRepaired: " TL;DR. ",
      expectedDocument: "I bought 5 TL;DR. ",
      expectedRules: [.leadingSpace, .caseSkipped(.protectedWord), .trailingSpace]),
    MatrixCase(
      caret: "after colon",
      left: "Note: ",
      right: "",
      payload: "TL;DR.",
      expectedRepaired: "TL;DR. ",
      expectedDocument: "Note: TL;DR. ",
      expectedRules: [.caseSkipped(.protectedWord), .trailingSpace]),
    MatrixCase(
      caret: "multiple spaces after stop",
      left: "I went home.   ",
      right: "",
      payload: "TL;DR.",
      expectedRepaired: "TL;DR. ",
      expectedDocument: "I went home.   TL;DR. ",
      expectedRules: [.caseKept(.afterTerminator), .trailingSpace]),
    MatrixCase(
      caret: "empty field",
      left: "",
      right: "",
      payload: "I went there.",
      expectedRepaired: "I went there. ",
      expectedDocument: "I went there. ",
      expectedRules: [.caseKept(.nothingLeft), .trailingSpace]),
    MatrixCase(
      caret: "mid-word",
      left: "I went to the sto",
      right: "re today",
      payload: "I went there.",
      expectedRepaired: nil,
      expectedDocument: nil,
      expectedRules: [.refusedInsideWord]),
    MatrixCase(
      caret: "mid-sentence, text right",
      left: "I went to the ",
      right: "yesterday",
      payload: "I went there.",
      expectedRepaired: "I went there ",
      expectedDocument: "I went to the I went there yesterday",
      expectedRules: [.caseSkipped(.pronounI), .droppedTerminalPeriod, .trailingSpace]),
    MatrixCase(
      caret: "after letter, no space",
      left: "I went to the",
      right: "",
      payload: "I went there.",
      expectedRepaired: " I went there. ",
      expectedDocument: "I went to the I went there. ",
      expectedRules: [.leadingSpace, .caseSkipped(.pronounI), .trailingSpace]),
    MatrixCase(
      caret: "after full stop + space",
      left: "I went home. ",
      right: "",
      payload: "I went there.",
      expectedRepaired: "I went there. ",
      expectedDocument: "I went home. I went there. ",
      expectedRules: [.caseKept(.afterTerminator), .trailingSpace]),
    MatrixCase(
      caret: "after comma + space",
      left: "I went home, ",
      right: "",
      payload: "I went there.",
      expectedRepaired: "I went there. ",
      expectedDocument: "I went home, I went there. ",
      expectedRules: [.caseSkipped(.pronounI), .trailingSpace]),
    MatrixCase(
      caret: "after full stop, no space",
      left: "I went home.",
      right: "",
      payload: "I went there.",
      expectedRepaired: " I went there. ",
      expectedDocument: "I went home. I went there. ",
      expectedRules: [.leadingSpace, .caseKept(.afterTerminator), .trailingSpace]),
    MatrixCase(
      caret: "start of new line",
      left: "First line.\n",
      right: "",
      payload: "I went there.",
      expectedRepaired: "I went there. ",
      expectedDocument: "First line.\nI went there. ",
      expectedRules: [.caseKept(.lineStart), .trailingSpace]),
    MatrixCase(
      caret: "after opening quote",
      left: "He said \"",
      right: "",
      payload: "I went there.",
      expectedRepaired: "I went there. ",
      expectedDocument: "He said \"I went there. ",
      expectedRules: [.caseKept(.afterOpener), .trailingSpace]),
    MatrixCase(
      caret: "before a full stop",
      left: "I went to the ",
      right: ".",
      payload: "I went there.",
      expectedRepaired: "I went there",
      expectedDocument: "I went to the I went there.",
      expectedRules: [
        .caseSkipped(.pronounI), .droppedTerminalPeriod, .trailingSpaceSkipped(.rightIsPunctuation),
      ]),
    MatrixCase(
      caret: "after digit",
      left: "I bought 5",
      right: "",
      payload: "I went there.",
      expectedRepaired: " I went there. ",
      expectedDocument: "I bought 5 I went there. ",
      expectedRules: [.leadingSpace, .caseSkipped(.pronounI), .trailingSpace]),
    MatrixCase(
      caret: "after colon",
      left: "Note: ",
      right: "",
      payload: "I went there.",
      expectedRepaired: "I went there. ",
      expectedDocument: "Note: I went there. ",
      expectedRules: [.caseSkipped(.pronounI), .trailingSpace]),
    MatrixCase(
      caret: "multiple spaces after stop",
      left: "I went home.   ",
      right: "",
      payload: "I went there.",
      expectedRepaired: "I went there. ",
      expectedDocument: "I went home.   I went there. ",
      expectedRules: [.caseKept(.afterTerminator), .trailingSpace]),
    MatrixCase(
      caret: "empty field",
      left: "",
      right: "",
      payload: "iPhone is nice.",
      expectedRepaired: "iPhone is nice. ",
      expectedDocument: "iPhone is nice. ",
      expectedRules: [.caseKept(.nothingLeft), .trailingSpace]),
    MatrixCase(
      caret: "mid-word",
      left: "I went to the sto",
      right: "re today",
      payload: "iPhone is nice.",
      expectedRepaired: nil,
      expectedDocument: nil,
      expectedRules: [.refusedInsideWord]),
    MatrixCase(
      caret: "mid-sentence, text right",
      left: "I went to the ",
      right: "yesterday",
      payload: "iPhone is nice.",
      expectedRepaired: "iPhone is nice ",
      expectedDocument: "I went to the iPhone is nice yesterday",
      expectedRules: [.caseSkipped(.alreadyLower), .droppedTerminalPeriod, .trailingSpace]),
    MatrixCase(
      caret: "after letter, no space",
      left: "I went to the",
      right: "",
      payload: "iPhone is nice.",
      expectedRepaired: " iPhone is nice. ",
      expectedDocument: "I went to the iPhone is nice. ",
      expectedRules: [.leadingSpace, .caseSkipped(.alreadyLower), .trailingSpace]),
    MatrixCase(
      caret: "after full stop + space",
      left: "I went home. ",
      right: "",
      payload: "iPhone is nice.",
      expectedRepaired: "iPhone is nice. ",
      expectedDocument: "I went home. iPhone is nice. ",
      expectedRules: [.caseKept(.afterTerminator), .trailingSpace]),
    MatrixCase(
      caret: "after comma + space",
      left: "I went home, ",
      right: "",
      payload: "iPhone is nice.",
      expectedRepaired: "iPhone is nice. ",
      expectedDocument: "I went home, iPhone is nice. ",
      expectedRules: [.caseSkipped(.alreadyLower), .trailingSpace]),
    MatrixCase(
      caret: "after full stop, no space",
      left: "I went home.",
      right: "",
      payload: "iPhone is nice.",
      expectedRepaired: " iPhone is nice. ",
      expectedDocument: "I went home. iPhone is nice. ",
      expectedRules: [.leadingSpace, .caseKept(.afterTerminator), .trailingSpace]),
    MatrixCase(
      caret: "start of new line",
      left: "First line.\n",
      right: "",
      payload: "iPhone is nice.",
      expectedRepaired: "iPhone is nice. ",
      expectedDocument: "First line.\niPhone is nice. ",
      expectedRules: [.caseKept(.lineStart), .trailingSpace]),
    MatrixCase(
      caret: "after opening quote",
      left: "He said \"",
      right: "",
      payload: "iPhone is nice.",
      expectedRepaired: "iPhone is nice. ",
      expectedDocument: "He said \"iPhone is nice. ",
      expectedRules: [.caseKept(.afterOpener), .trailingSpace]),
    MatrixCase(
      caret: "before a full stop",
      left: "I went to the ",
      right: ".",
      payload: "iPhone is nice.",
      expectedRepaired: "iPhone is nice",
      expectedDocument: "I went to the iPhone is nice.",
      expectedRules: [
        .caseSkipped(.alreadyLower), .droppedTerminalPeriod,
        .trailingSpaceSkipped(.rightIsPunctuation),
      ]),
    MatrixCase(
      caret: "after digit",
      left: "I bought 5",
      right: "",
      payload: "iPhone is nice.",
      expectedRepaired: " iPhone is nice. ",
      expectedDocument: "I bought 5 iPhone is nice. ",
      expectedRules: [.leadingSpace, .caseSkipped(.alreadyLower), .trailingSpace]),
    MatrixCase(
      caret: "after colon",
      left: "Note: ",
      right: "",
      payload: "iPhone is nice.",
      expectedRepaired: "iPhone is nice. ",
      expectedDocument: "Note: iPhone is nice. ",
      expectedRules: [.caseSkipped(.alreadyLower), .trailingSpace]),
    MatrixCase(
      caret: "multiple spaces after stop",
      left: "I went home.   ",
      right: "",
      payload: "iPhone is nice.",
      expectedRepaired: "iPhone is nice. ",
      expectedDocument: "I went home.   iPhone is nice. ",
      expectedRules: [.caseKept(.afterTerminator), .trailingSpace]),
  ]

  // MARK: - The frozen 52-case matrix

  @Test("Matrix row produces the frozen document and rule reasoning", arguments: matrix)
  func matrixRow(_ testCase: MatrixCase) {
    let payloads = CursorInsertionRepair.repair(
      text: testCase.payload,
      context: CursorInsertionRepair.CaretText(left: testCase.left, right: testCase.right),
      protectedWords: Self.protectedWords,
      lexicon: Self.prototypeLexicon)

    #expect(payloads.repairedText == testCase.expectedRepaired, "\(testCase)")
    if let expectedDocument = testCase.expectedDocument {
      #expect(
        (testCase.left + (payloads.repairedText ?? "") + testCase.right)
          == expectedDocument, "\(testCase)")
    } else {
      // Refused: no candidate, so §6 delivers legacyText and this layer
      // asserts only that nothing was invented.
      #expect(payloads.repairedText == nil, "\(testCase)")
    }
    #expect(payloads.candidateRules == testCase.expectedRules, "\(testCase)")
    // legacyText is independent of context in every row.
    #expect(payloads.legacyText == CursorInsertionRepair.legacyPayload(testCase.payload))
  }

  // MARK: - The nine protected production cases

  /// Each must survive a continuation context — the one place the rule fires —
  /// with its capitalisation untouched, and each for a NAMED reason.
  static let protectedRegressions: [(word: String, reason: CursorInsertionRepair.CaseSkipReason)] =
    [
      ("PostHog", .mixedCaseOrAcronym),
      ("SwiftUI", .mixedCaseOrAcronym),
      ("GitHub", .protectedWord),
      ("NASA", .mixedCaseOrAcronym),
      ("iPhone", .alreadyLower),
      ("Monday", .alwaysCapitalized),
      ("TL;DR", .protectedWord),
      ("Kubernetes", .notKnownLowercase),
      ("Lindsay", .notKnownLowercase),
    ]

  @Test(
    "Protected word keeps its capital in a continuation context",
    arguments: protectedRegressions)
  func protectedWordSurvives(
    _ testCase: (word: String, reason: CursorInsertionRepair.CaseSkipReason)
  ) {
    let payloads = CursorInsertionRepair.repair(
      text: "\(testCase.word) is fine.",
      context: CursorInsertionRepair.CaretText(left: "I think ", right: ""),
      protectedWords: Self.protectedWords,
      lexicon: Self.prototypeLexicon)

    #expect(
      payloads.repairedText?.hasPrefix(testCase.word) == true,
      "\(testCase.word) must not be recased")
    #expect(payloads.candidateRules.contains(.caseSkipped(testCase.reason)))
    #expect(payloads.candidateRules.contains(.lowercasedFirst) == false)
  }

  @Test("Digit-bearing identifier keeps its capital")
  func digitBearingIdentifierSurvives() {
    let payloads = CursorInsertionRepair.repair(
      text: "Kubernetes v2 shipped.",
      context: CursorInsertionRepair.CaretText(left: "I think ", right: ""),
      protectedWords: [],
      lexicon: Self.prototypeLexicon)
    #expect(payloads.repairedText?.hasPrefix("Kubernetes") == true)
  }

  // MARK: - legacyText is exactly today's rule

  @Test(
    "legacyText matches today's trailing-space rule exactly",
    arguments: [
      ("", " "),
      ("hello", "hello "),
      ("hello ", "hello "),
      ("hello\n", "hello\n "),
      ("hello\t", "hello\t "),
      ("hello  ", "hello  "),
    ])
  func legacyPayloadIsExact(_ testCase: (input: String, expected: String)) {
    let payloads = CursorInsertionRepair.repair(
      text: testCase.input, context: nil, protectedWords: [],
      lexicon: Self.prototypeLexicon)
    #expect(payloads.legacyText == testCase.expected)
    // Only a single trailing space is ever appended, and never a second one.
    #expect(
      payloads.legacyText
        == (testCase.input.hasSuffix(" ")
          ? testCase.input : testCase.input + " "))
  }

  // MARK: - nil context

  @Test("nil context yields no candidate and claims no rule")
  func nilContextYieldsNoCandidate() {
    let payloads = CursorInsertionRepair.repair(
      text: "Store today.", context: nil, protectedWords: [],
      lexicon: Self.prototypeLexicon)
    #expect(payloads.repairedText == nil)
    #expect(payloads.candidateRules.isEmpty)
    #expect(
      payloads.legacyText == "Store today. ",
      "nil context must still carry today's trailing space, NOT the raw input")
  }

  @Test("nil context never returns the raw input unchanged")
  func nilContextIsNotRawInput() {
    let payloads = CursorInsertionRepair.repair(
      text: "no trailing space", context: nil, protectedWords: [],
      lexicon: Self.prototypeLexicon)
    #expect(payloads.legacyText != "no trailing space")
  }

  @Test("A readable context produces a candidate without choosing a route")
  func readableContextProducesCandidateOnly() {
    let payloads = CursorInsertionRepair.repair(
      text: "Store today.",
      context: CursorInsertionRepair.CaretText(left: "I went to the ", right: ""),
      protectedWords: [], lexicon: Self.prototypeLexicon)
    #expect(payloads.repairedText != nil)
    #expect(payloads.legacyText == "Store today. ")
    // Both payloads are offered; nothing here selects one.
    #expect(payloads.repairedText != payloads.legacyText)
  }

  // MARK: - Guard 5: the first-person pronoun family

  @Test(
    "Pronoun family is protected by the guard itself, not by lexicon absence",
    arguments: [
      "I", "I'm", "I've", "I'll", "I'd", "I\u{2019}m", "I\u{2019}ve",
      "I\u{2019}ll", "I\u{2019}d",
    ])
  func pronounFamilyProtectedEvenWhenInjectedIntoLexicon(_ word: String) {
    // Deliberately poison the lexicon with every normalised pronoun spelling.
    // If the guard relied on absence, these would now lowercase.
    let poisoned = OrdinaryLowercaseLexicon(
      words: ["i", "i'm", "i've", "i'll", "i'd"], isAvailable: true)

    let payloads = CursorInsertionRepair.repair(
      text: "\(word) went there.",
      context: CursorInsertionRepair.CaretText(left: "and so ", right: ""),
      protectedWords: [], lexicon: poisoned)

    #expect(
      payloads.repairedText?.hasPrefix(word) == true,
      "\(word) must keep its capital even when the lexicon says otherwise")
    #expect(payloads.candidateRules.contains(.caseSkipped(.pronounI)))
    #expect(payloads.candidateRules.contains(.lowercasedFirst) == false)
  }

  @Test("Guard 5 recognises the pronoun family directly")
  func pronounRecognitionIsDirect() {
    for word in ["I", "I'm", "I've", "I'll", "I'd", "I\u{2019}m"] {
      #expect(CursorInsertionRepair.isFirstPersonPronoun(word), "\(word)")
    }
    for word in ["Iowa", "Ideal", "If", "Instead", "i"] {
      #expect(CursorInsertionRepair.isFirstPersonPronoun(word) == false, "\(word)")
    }
  }

  // MARK: - Guard precedence

  @Test("Protected spelling beats lexicon membership")
  func protectedBeatsLexicon() {
    let lexicon = OrdinaryLowercaseLexicon(words: ["store"], isAvailable: true)
    let payloads = CursorInsertionRepair.repair(
      text: "Store today.",
      context: CursorInsertionRepair.CaretText(left: "I went to the ", right: ""),
      protectedWords: ["Store"], lexicon: lexicon)
    #expect(payloads.candidateRules.contains(.caseSkipped(.protectedWord)))
  }

  @Test("A multi-word protected canonical wins before lexicon lookup")
  func multiWordProtectedCanonicalWins() {
    // Matching only the first token would compare "The", miss the protected set,
    // find `the` in the lexicon, and ship "the Who".
    let payloads = CursorInsertionRepair.repair(
      text: "The Who announced it.",
      context: CursorInsertionRepair.CaretText(left: "We discussed ", right: ""),
      protectedWords: ["The Who"],
      lexicon: OrdinaryLowercaseLexicon(words: ["the"], isAvailable: true))

    #expect(payloads.repairedText?.hasPrefix("The Who") == true)
    #expect(payloads.candidateRules.contains(.caseSkipped(.protectedWord)))
    #expect(payloads.candidateRules.contains(.lowercasedFirst) == false)
  }

  @Test(
    "Shipped multi-word builtins are protected by the rule, not by coincidence",
    arguments: [("Envious Labs", "envious"), ("VS Code", "vs")])
  func shippedMultiWordBuiltinsProtected(_ testCase: (canonical: String, firstWord: String)) {
    // These survive today only because their first words happen to be absent
    // from the lexicon. Poison the lexicon with those words to prove the
    // protection is the guard's doing.
    let payloads = CursorInsertionRepair.repair(
      text: "\(testCase.canonical) shipped it.",
      context: CursorInsertionRepair.CaretText(left: "I heard ", right: ""),
      protectedWords: [testCase.canonical],
      lexicon: OrdinaryLowercaseLexicon(words: [testCase.firstWord], isAvailable: true))

    #expect(payloads.repairedText?.hasPrefix(testCase.canonical) == true)
    #expect(payloads.candidateRules.contains(.caseSkipped(.protectedWord)))
  }

  @Test("A protected canonical does not shadow a longer word starting with it")
  func protectedDoesNotShadowLongerWord() {
    // "Store" is protected; "Storefront" is a different word and must not
    // inherit that protection.
    let payloads = CursorInsertionRepair.repair(
      text: "Storefront opened.",
      context: CursorInsertionRepair.CaretText(left: "I saw the ", right: ""),
      protectedWords: ["Store"],
      lexicon: OrdinaryLowercaseLexicon(words: ["storefront"], isAvailable: true))

    #expect(payloads.candidateRules.contains(.caseSkipped(.protectedWord)) == false)
    #expect(payloads.candidateRules.contains(.lowercasedFirst))
  }

  @Test("Acronym guard beats lexicon membership")
  func acronymBeatsLexicon() {
    let lexicon = OrdinaryLowercaseLexicon(words: ["nasa"], isAvailable: true)
    let payloads = CursorInsertionRepair.repair(
      text: "NASA said no.",
      context: CursorInsertionRepair.CaretText(left: "I think ", right: ""),
      protectedWords: [], lexicon: lexicon)
    #expect(payloads.candidateRules.contains(.caseSkipped(.mixedCaseOrAcronym)))
  }

  @Test("Digit guard beats lexicon membership")
  func digitBeatsLexicon() {
    let lexicon = OrdinaryLowercaseLexicon(words: ["s3"], isAvailable: true)
    let payloads = CursorInsertionRepair.repair(
      text: "S3 is down.",
      context: CursorInsertionRepair.CaretText(left: "I think ", right: ""),
      protectedWords: [], lexicon: lexicon)
    #expect(payloads.candidateRules.contains(.caseSkipped(.containsDigit)))
  }

  @Test("Weekday guard beats lexicon membership")
  func weekdayBeatsLexicon() {
    let lexicon = OrdinaryLowercaseLexicon(words: ["monday"], isAvailable: true)
    let payloads = CursorInsertionRepair.repair(
      text: "Monday works.",
      context: CursorInsertionRepair.CaretText(left: "I think ", right: ""),
      protectedWords: [], lexicon: lexicon)
    #expect(payloads.candidateRules.contains(.caseSkipped(.alwaysCapitalized)))
  }

  @Test("An unknown word keeps today's capitalisation")
  func unknownWordKeepsCapital() {
    let payloads = CursorInsertionRepair.repair(
      text: "Zorbitrax launched.",
      context: CursorInsertionRepair.CaretText(left: "I think ", right: ""),
      protectedWords: [], lexicon: Self.prototypeLexicon)
    #expect(payloads.repairedText?.hasPrefix("Zorbitrax") == true)
    #expect(payloads.candidateRules.contains(.caseSkipped(.notKnownLowercase)))
  }

  // MARK: - An unusable lexicon disables case repair ONLY

  @Test("Unavailable lexicon still applies spacing and terminal-period repair")
  func unavailableLexiconStillRepairsSpacingAndPeriod() {
    let payloads = CursorInsertionRepair.repair(
      text: "Store today.",
      // Comma to the left, letter to the right: the leading-space and
      // terminal-period rules both fire, and it is NOT mid-word, because a
      // letter touching a letter would refuse before any of this runs.
      context: CursorInsertionRepair.CaretText(left: "I went home,", right: "yesterday"),
      protectedWords: [], lexicon: .unavailable)

    #expect(payloads.candidateRules.contains(.caseSkipped(.lexiconUnavailable)))
    #expect(payloads.candidateRules.contains(.leadingSpace))
    #expect(payloads.candidateRules.contains(.droppedTerminalPeriod))
    #expect(payloads.candidateRules.contains(.trailingSpace))
    #expect(payloads.repairedText == " Store today ", "case is left alone")
  }

  // MARK: - Terminal punctuation

  @Test(
    "Only a terminal full stop is removable",
    arguments: [
      ("Store today.", true),
      ("Store today?", false),
      ("Store today!", false),
    ])
  func onlyFullStopIsRemoved(_ testCase: (payload: String, dropped: Bool)) {
    let payloads = CursorInsertionRepair.repair(
      text: testCase.payload,
      context: CursorInsertionRepair.CaretText(left: "I went to the ", right: "yesterday"),
      protectedWords: [], lexicon: Self.prototypeLexicon)
    #expect(
      payloads.candidateRules.contains(.droppedTerminalPeriod) == testCase.dropped,
      "\(testCase.payload)")
  }

  @Test("No double period when inserting before existing punctuation")
  func noDoublePeriod() {
    let payloads = CursorInsertionRepair.repair(
      text: "Store today.",
      context: CursorInsertionRepair.CaretText(left: "I went to the ", right: "."),
      protectedWords: [], lexicon: Self.prototypeLexicon)
    #expect(payloads.repairedText?.contains("..") == false)
    let document = "I went to the " + (payloads.repairedText ?? "") + "."
    #expect(document == "I went to the store today.")
  }

  // MARK: - The comma-versus-period case a single character could not express

  @Test(
    "One character to the left is not enough to decide case",
    arguments: [
      ("I went home. ", false),
      ("I went home, ", true),
    ])
  func skipBackDistinguishesCommaFromPeriod(_ testCase: (left: String, lowered: Bool)) {
    // Both left windows END in a space. Only skipping back to the last real
    // character can tell a finished sentence from a continuing one.
    let payloads = CursorInsertionRepair.repair(
      text: "That works.",
      context: CursorInsertionRepair.CaretText(left: testCase.left, right: ""),
      protectedWords: [],
      lexicon: OrdinaryLowercaseLexicon(words: ["that"], isAvailable: true))
    #expect(
      payloads.candidateRules.contains(.lowercasedFirst) == testCase.lowered,
      "\(testCase.left)")
  }

  // MARK: - Adversarial input shapes

  @Test("Empty dictation yields today's payload and no contextual claim")
  func emptyTextIsSafe() {
    let payloads = CursorInsertionRepair.repair(
      text: "",
      context: CursorInsertionRepair.CaretText(left: "I went to the ", right: ""),
      protectedWords: [], lexicon: Self.prototypeLexicon)
    #expect(payloads.legacyText == " ")
    #expect(payloads.candidateRules.isEmpty)
  }

  @Test(
    "Leading punctuation and quotes are not eligible for case repair",
    arguments: ["\"Store today.", "(Store today.", "'Store today."])
  func leadingPunctuationIsNotEligible(_ payload: String) {
    let payloads = CursorInsertionRepair.repair(
      text: payload,
      context: CursorInsertionRepair.CaretText(left: "I went to the ", right: ""),
      protectedWords: [], lexicon: Self.prototypeLexicon)
    #expect(payloads.candidateRules.contains(.caseSkipped(.alreadyLower)))
    #expect(payloads.candidateRules.contains(.lowercasedFirst) == false)
  }

  @Test("An emoji-leading payload is left alone")
  func emojiLeadingPayload() {
    let payloads = CursorInsertionRepair.repair(
      text: "🚀 Store today.",
      context: CursorInsertionRepair.CaretText(left: "I went to the ", right: ""),
      protectedWords: [], lexicon: Self.prototypeLexicon)
    #expect(payloads.repairedText?.contains("🚀") == true)
    #expect(payloads.candidateRules.contains(.lowercasedFirst) == false)
  }

  @Test("A combining-mark first character is handled as one Character")
  func combiningMarkFirstCharacter() {
    // "É" as E + combining acute. Must not be split by any indexing.
    let payloads = CursorInsertionRepair.repair(
      text: "E\u{0301}cole opened.",
      context: CursorInsertionRepair.CaretText(left: "I saw ", right: ""),
      protectedWords: [], lexicon: Self.prototypeLexicon)
    #expect(payloads.repairedText?.isEmpty == false)
    #expect(payloads.candidateRules.contains(.caseSkipped(.notKnownLowercase)))
  }

  @Test("A tab to the left counts as separation")
  func tabIsSeparation() {
    let payloads = CursorInsertionRepair.repair(
      text: "Store today.",
      context: CursorInsertionRepair.CaretText(left: "I went to the\t", right: ""),
      protectedWords: [], lexicon: Self.prototypeLexicon)
    #expect(payloads.candidateRules.contains(.leadingSpace) == false)
  }

  @Test("A newline to the left is a sentence boundary, not whitespace to skip")
  func newlineIsBoundary() {
    let payloads = CursorInsertionRepair.repair(
      text: "Store today.",
      context: CursorInsertionRepair.CaretText(left: "First line.\n", right: ""),
      protectedWords: [], lexicon: Self.prototypeLexicon)
    #expect(payloads.candidateRules.contains(.caseKept(.lineStart)))
    #expect(payloads.candidateRules.contains(.leadingSpace) == false)
  }

  @Test("Right-side whitespace suppresses the trailing space")
  func rightWhitespaceSuppressesTrailingSpace() {
    let payloads = CursorInsertionRepair.repair(
      text: "Store today.",
      context: CursorInsertionRepair.CaretText(left: "I went to the ", right: " yesterday"),
      protectedWords: [], lexicon: Self.prototypeLexicon)
    #expect(payloads.candidateRules.contains(.trailingSpaceSkipped(.rightIsSpace)))
  }

  @Test(
    "Closing brackets suppress the trailing space",
    arguments: [")", "]", "}", ",", ";", ":"])
  func closingPunctuationSuppressesTrailingSpace(_ right: String) {
    let payloads = CursorInsertionRepair.repair(
      text: "Store today.",
      context: CursorInsertionRepair.CaretText(left: "I went to the ", right: right),
      protectedWords: [], lexicon: Self.prototypeLexicon)
    #expect(
      payloads.candidateRules.contains(.trailingSpaceSkipped(.rightIsPunctuation)),
      "\(right)")
  }

  @Test("A payload already ending in a space gains no second one")
  func noDoubleTrailingSpace() {
    let payloads = CursorInsertionRepair.repair(
      text: "Store today. ",
      context: CursorInsertionRepair.CaretText(left: "I went to the ", right: ""),
      protectedWords: [], lexicon: Self.prototypeLexicon)
    #expect(payloads.repairedText?.hasSuffix("  ") == false)
  }

  @Test("Protected-word matching is exact, not case-insensitive")
  func protectedMatchingIsExact() {
    let payloads = CursorInsertionRepair.repair(
      text: "Store today.",
      context: CursorInsertionRepair.CaretText(left: "I went to the ", right: ""),
      protectedWords: ["store"], lexicon: Self.prototypeLexicon)
    #expect(
      payloads.candidateRules.contains(.caseSkipped(.protectedWord)) == false,
      "a lowercase protected entry must not shadow the capitalised token")
  }
}
