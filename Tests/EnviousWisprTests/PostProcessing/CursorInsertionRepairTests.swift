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

  // MARK: - Quote direction and word connectors (Codex review r1)

  @Test(
    "A quote that CLOSES a quotation still gets its separating space",
    arguments: ["He said \"hello\"", "She said 'no'"])
  func closingQuoteStillSeparates(_ left: String) {
    // The character alone cannot tell an opening quote from a closing one, and
    // the two demand opposite spacing. Treating every straight quote as an
    // opener ran the next word straight into the quotation: `hello"Store`.
    let payloads = CursorInsertionRepair.repair(
      text: "Store today.",
      context: CursorInsertionRepair.CaretText(left: left, right: ""),
      protectedWords: [], language: "en", lexicon: Self.prototypeLexicon)
    #expect(payloads.candidateRules.contains(.leadingSpace), "\(left)")
    #expect(payloads.repairedText?.hasPrefix(" ") == true, "\(left)")
  }

  // The COMPLETE quote-direction table. Two review rounds each found one wrong
  // cell of this decision one at a time, so the space is enumerated here rather
  // than sampled: every character class that can precede a straight quote, and
  // the direction it implies. A new class added to the rule without a row here
  // is the gap this table exists to close.
  @Test(
    "Quote direction is decided for every kind of preceding character",
    arguments: [
      // opening: nothing, whitespace, brackets, curly openers, introducers
      (left: "\"", opening: true),
      (left: "He said \"", opening: true),
      (left: "(\"", opening: true),
      (left: "\u{201C}\"", opening: true),
      (left: "He said:\"", opening: true),
      (left: "He said;\"", opening: true),
      (left: "He said\u{2014}\"", opening: true),
      (left: "He said\u{2013}\"", opening: true),
      (left: "He said-\"", opening: true),
      // closing: the quoted text, or terminal punctuation inside the quotation
      (left: "\"hello\"", opening: false),
      (left: "\"chapter 7\"", opening: false),
      (left: "\"Stop!\"", opening: false),
      (left: "\"Really?\"", opening: false),
      (left: "\"hello.\"", opening: false),
      (left: "\"hello,\"", opening: false),
      // unknown punctuation defaults to closing: adding an unwanted space is
      // cosmetic, omitting a needed one runs two words together
      (left: "path/\"", opening: false),
    ] as [(left: String, opening: Bool)])
  func quoteDirectionTable(_ testCase: (left: String, opening: Bool)) {
    let payloads = CursorInsertionRepair.repair(
      text: "Store today.",
      context: CursorInsertionRepair.CaretText(left: testCase.left, right: ""),
      protectedWords: [], language: "en", lexicon: Self.prototypeLexicon)
    let addedSpace = payloads.candidateRules.contains(.leadingSpace)
    #expect(
      addedSpace == !testCase.opening,
      "\(testCase.left): an opening quote takes no space, a closing one needs one")
  }

  @Test(
    "A quote that OPENS a quotation still suppresses the space",
    arguments: ["He said \"", "She said '", "He said \u{201C}"])
  func openingQuoteStillSuppresses(_ left: String) {
    let payloads = CursorInsertionRepair.repair(
      text: "Store today.",
      context: CursorInsertionRepair.CaretText(left: left, right: ""),
      protectedWords: [], language: "en", lexicon: Self.prototypeLexicon)
    #expect(payloads.candidateRules.contains(.leadingSpace) == false, "\(left)")
    #expect(payloads.candidateRules.contains(.caseKept(.afterOpener)), "\(left)")
  }

  @Test("No trailing space is added just inside a closing quotation")
  func noSpaceInsideAClosingQuote() {
    let payloads = CursorInsertionRepair.repair(
      text: "Store today.",
      context: CursorInsertionRepair.CaretText(left: "He said \u{201C}", right: "\u{201D}"),
      protectedWords: [], language: "en", lexicon: Self.prototypeLexicon)
    #expect(payloads.repairedText?.hasSuffix(" ") == false)
    #expect(payloads.candidateRules.contains(.trailingSpaceSkipped(.rightIsPunctuation)))
  }

  @Test(
    "A caret inside a contraction or hyphenated word is refused",
    arguments: [
      (left: "I can", right: "'t do it"),
      (left: "I can'", right: "t do it"),
      (left: "state", right: "-of-the-art"),
      (left: "state-", right: "of-the-art"),
      (left: "it\u{2019}", right: "s fine"),
    ] as [(left: String, right: String)])
  func connectorsAreWordInternal(_ testCase: (left: String, right: String)) {
    // One side is punctuation, so the plain letter-or-digit test called this
    // "between words" and inserted a space in the middle of one — the very
    // breakage the mid-word refusal exists to prevent, reached through a
    // character the guard did not recognise.
    let payloads = CursorInsertionRepair.repair(
      text: "Store today.",
      context: CursorInsertionRepair.CaretText(left: testCase.left, right: testCase.right),
      protectedWords: [], language: "en", lexicon: Self.prototypeLexicon)
    #expect(payloads.repairedText == nil, "\(testCase)")
    #expect(payloads.candidateRules == [.refusedInsideWord], "\(testCase)")
  }

  @Test(
    "A connector that is not joining two words does not trigger the refusal",
    arguments: [
      (left: "the Joneses'", right: " house"),
      (left: "- ", right: "bullet item"),
    ] as [(left: String, right: String)])
  func connectorsOnlyJoinRealWords(_ testCase: (left: String, right: String)) {
    let payloads = CursorInsertionRepair.repair(
      text: "Store today.",
      context: CursorInsertionRepair.CaretText(left: testCase.left, right: testCase.right),
      protectedWords: [], language: "en", lexicon: Self.prototypeLexicon)
    #expect(
      payloads.candidateRules.contains(.refusedInsideWord) == false, "\(testCase)")
  }

  // MARK: - Abbreviations and Unicode whitespace (Codex review r5)

  @Test(
    "An abbreviation keeps the period that belongs to the word",
    arguments: [
      "We need milk, eggs, etc.", "I spoke to Dr.", "Ask Mr.", "Meet at 9 a.m.",
      "Ship it to Acme Inc.",
    ])
  func abbreviationsKeepTheirPeriod(_ payload: String) {
    // Losing a character the user dictated is the worst outcome this feature can
    // produce. `etc.` inserted before existing text used to arrive as `etc`.
    let payloads = CursorInsertionRepair.repair(
      text: payload,
      context: CursorInsertionRepair.CaretText(left: "I said ", right: "yesterday"),
      protectedWords: [], language: "en", lexicon: Self.prototypeLexicon)
    #expect(payloads.candidateRules.contains(.droppedTerminalPeriod) == false, "\(payload)")
    #expect(payloads.repairedText?.contains(".") == true, "\(payload)")
  }

  @Test(
    "A dotted initialism keeps its period without being listed",
    arguments: ["I live in the U.S.", "She moved to the U.K.", "That is the a.k.a."])
  func dottedInitialismsKeepTheirPeriod(_ payload: String) {
    // Recognised structurally rather than by membership: a closed list arrived
    // incomplete twice, so every single-letter-per-dot token is covered without
    // anyone having to enumerate them.
    let payloads = CursorInsertionRepair.repair(
      text: payload,
      context: CursorInsertionRepair.CaretText(left: "I said ", right: "yesterday"),
      protectedWords: [], language: "en", lexicon: Self.prototypeLexicon)
    #expect(payloads.candidateRules.contains(.droppedTerminalPeriod) == false, "\(payload)")
  }

  @Test(
    "A caret inside an underscored identifier is refused",
    arguments: [
      (left: "rename foo", right: "_bar now"),
      (left: "rename foo_", right: "bar now"),
    ] as [(left: String, right: String)])
  func underscoreIsAWordConnector(_ testCase: (left: String, right: String)) {
    // Dictating into code editors is a real target, and `foo_|bar` was being
    // split by a leading space. Same class as the r1 contraction finding.
    let payloads = CursorInsertionRepair.repair(
      text: "Store today.",
      context: CursorInsertionRepair.CaretText(left: testCase.left, right: testCase.right),
      protectedWords: [], language: "en", lexicon: Self.prototypeLexicon)
    #expect(payloads.candidateRules == [.refusedInsideWord], "\(testCase)")
  }

  @Test("An ordinary sentence still loses its redundant full stop")
  func ordinarySentenceStillDropsThePeriod() {
    // The abbreviation guard must not disable the rule it protects.
    let payloads = CursorInsertionRepair.repair(
      text: "Store today.",
      context: CursorInsertionRepair.CaretText(left: "I went to the ", right: "yesterday"),
      protectedWords: [], language: "en", lexicon: Self.prototypeLexicon)
    #expect(payloads.candidateRules.contains(.droppedTerminalPeriod))
  }

  @Test(
    "Unicode separators count as whitespace, not as an anchor",
    arguments: ["I went to the\u{00A0}", "I went to the\u{2009}", "I went to the\u{2007}"])
  func unicodeWhitespaceIsSkipped(_ left: String) {
    // A non-breaking space is ordinary in text copied from a web page. Treating
    // it as a real character made it an anchor, so the repair added a SECOND
    // separator beside it.
    let payloads = CursorInsertionRepair.repair(
      text: "Store today.",
      context: CursorInsertionRepair.CaretText(left: left, right: ""),
      protectedWords: [], language: "en", lexicon: Self.prototypeLexicon)
    #expect(
      payloads.candidateRules.contains(.leadingSpace) == false, "\(left.debugDescription)")
    #expect(payloads.candidateRules.contains(.lowercasedFirst), "still a continuation")
  }

  @Test("A non-breaking space on the right does not hide the following content")
  func unicodeWhitespaceOnTheRightIsSkipped() {
    let payloads = CursorInsertionRepair.repair(
      text: "Store today.",
      context: CursorInsertionRepair.CaretText(left: "I went to the ", right: "\u{00A0}yesterday"),
      protectedWords: [], language: "en", lexicon: Self.prototypeLexicon)
    #expect(payloads.candidateRules.contains(.droppedTerminalPeriod))
  }

  // MARK: - Unsegmented scripts and the mid-word refusal (Codex review r4)

  @Test(
    "A caret between two characters of an unsegmented script is not mid-word",
    arguments: ["ja", "zh", "th"])
  func unsegmentedScriptsHaveNoMidWordRefusal(_ language: String) {
    // Japanese, Chinese and Thai run characters together, so the caret NORMALLY
    // sits between two "word characters". Refusing there fired on nearly every
    // position and sent every such dictation to a payload that appends an ASCII
    // space — making the no-spaces-in-CJK work unreachable in practice.
    let payloads = CursorInsertionRepair.repair(
      text: "\u{6674}\u{308C}",
      context: CursorInsertionRepair.CaretText(
        left: "\u{4ECA}\u{65E5}", right: "\u{306F}\u{3044}\u{3044}"),
      protectedWords: [], language: language, lexicon: Self.prototypeLexicon)
    #expect(payloads.candidateRules.contains(.refusedInsideWord) == false, "\(language)")
    #expect(payloads.repairedText == "\u{6674}\u{308C}", "no space at either end")
  }

  @Test("A space-using language keeps its mid-word refusal")
  func segmentedScriptsStillRefuseMidWord() {
    let payloads = CursorInsertionRepair.repair(
      text: "Store today.",
      context: CursorInsertionRepair.CaretText(left: "I went to the sto", right: "re today"),
      protectedWords: [], language: "en", lexicon: Self.prototypeLexicon)
    #expect(payloads.candidateRules == [.refusedInsideWord])
  }

  @Test(
    "No trailing space is left inside a closing straight quote",
    arguments: ["\" and left", "\"", "\"."])
  func noSpaceBeforeAClosingStraightQuote(_ right: String) {
    // The mirror of the r2 enumeration, which settled which quotes take a space
    // BEFORE the insertion and said nothing about one sitting right after it.
    let payloads = CursorInsertionRepair.repair(
      text: "Store today.",
      context: CursorInsertionRepair.CaretText(left: "He said \"hello ", right: right),
      protectedWords: [], language: "en", lexicon: Self.prototypeLexicon)
    #expect(payloads.repairedText?.hasSuffix(" ") == false, "\(right.debugDescription)")
    #expect(payloads.candidateRules.contains(.trailingSpaceSkipped(.rightIsPunctuation)))
  }

  @Test("A quote OPENING the next quotation still takes its space")
  func spaceKeptBeforeAnOpeningStraightQuote() {
    // `"hello` after the caret is a new quotation starting, not one closing, so
    // the insertion still needs separating from it.
    let payloads = CursorInsertionRepair.repair(
      text: "Store today.",
      context: CursorInsertionRepair.CaretText(left: "I went to the ", right: "\"hello\""),
      protectedWords: [], language: "en", lexicon: Self.prototypeLexicon)
    #expect(payloads.candidateRules.contains(.trailingSpace))
  }

  // MARK: - The right side, read two different ways (Codex review r3)

  @Test(
    "A space before the following text does not make the full stop survive",
    arguments: [" yesterday", "  yesterday", "\tyesterday"])
  func spacedRightContentStillDropsThePeriod(_ right: String) {
    // Spacing and the period rule ask different questions of the right side.
    // Reading both from the immediate character kept a mid-sentence full stop
    // whenever the existing text happened to start with a space.
    let payloads = CursorInsertionRepair.repair(
      text: "Store today.",
      context: CursorInsertionRepair.CaretText(left: "I went to the ", right: right),
      protectedWords: [], language: "en", lexicon: Self.prototypeLexicon)
    #expect(payloads.candidateRules.contains(.droppedTerminalPeriod), "\(right.debugDescription)")
    #expect(payloads.repairedText?.contains("today.") == false, "\(right.debugDescription)")
  }

  @Test("Content on the NEXT line leaves the dictated full stop alone")
  func contentOnTheNextLineKeepsThePeriod() {
    // A new line is a new sentence. The period belongs to the one just dictated.
    let payloads = CursorInsertionRepair.repair(
      text: "Store today.",
      context: CursorInsertionRepair.CaretText(left: "I went to the ", right: "\nyesterday"),
      protectedWords: [], language: "en", lexicon: Self.prototypeLexicon)
    #expect(payloads.candidateRules.contains(.droppedTerminalPeriod) == false)
    #expect(payloads.repairedText?.contains("today.") == true)
  }

  @Test("An existing space to the right still suppresses the trailing space")
  func spacingStillReadsTheImmediateCharacter() {
    // The spacing rule must keep seeing the space itself, or we would add a
    // second one — the two rules read the same window for different reasons.
    let payloads = CursorInsertionRepair.repair(
      text: "Store today.",
      context: CursorInsertionRepair.CaretText(left: "I went to the ", right: " yesterday"),
      protectedWords: [], language: "en", lexicon: Self.prototypeLexicon)
    #expect(payloads.candidateRules.contains(.trailingSpaceSkipped(.rightIsSpace)))
    #expect(payloads.repairedText?.hasSuffix(" ") == false)
  }

  // MARK: - An unverifiable caret

  // MEASURED in Ghostty, 2026-07-25: the character count grows as the user
  // types (42 -> 179 -> 198) while `AXSelectedTextRange` stays pinned at 0. The
  // reported caret is not the insertion point at all, so the "right window" is
  // the TOP of the terminal's scrollback rather than the text after the cursor.
  //
  // With nothing to the left there is nothing to repair — the capital stays and
  // no leading space is added either way — so the only rules that could still
  // act are the two that read the right window. Both would then be acting on
  // text that is not next to the caret, and one of them DELETES a character the
  // user dictated. That is why this refuses instead of trusting one side.
  @Test("Nothing to the left means no contextual claim at all")
  func noLeftAnchorRefusesTheCandidate() {
    let payloads = CursorInsertionRepair.repair(
      text: "Hello there.",
      context: CursorInsertionRepair.CaretText(left: "", right: "the store is closed."),
      protectedWords: [], language: "en", lexicon: Self.prototypeLexicon)
    #expect(
      payloads.repairedText == nil,
      "a caret we cannot place must not produce a contextual candidate")
    #expect(payloads.candidateRules == [.refusedNoLeftAnchor])
    #expect(payloads.legacyText == "Hello there. ", "today's payload is unchanged")
  }

  @Test("The user's full stop survives a caret that cannot be placed")
  func trailingPeriodSurvivesAnUnplaceableCaret() {
    // The concrete Ghostty failure: dictating a finished sentence into a
    // terminal used to arrive with its full stop removed, because the rule that
    // drops a redundant period believed the scrollback's first line was sitting
    // just after the caret.
    let payloads = CursorInsertionRepair.repair(
      text: "Deploy the release now.",
      context: CursorInsertionRepair.CaretText(
        left: "", right: "Last login: Fri Jul 25 on ttys004"),
      protectedWords: [], language: "en", lexicon: Self.prototypeLexicon)
    let delivered = payloads.repairedText ?? payloads.legacyText
    #expect(delivered.contains("now."), "the dictated full stop must survive")
    #expect(delivered == "Deploy the release now. ")
  }

  @Test("A line start is still a caret we cannot place")
  func lineStartAlsoRefuses() {
    // Same shape, honestly reached: the user pressed Return and dictated. There
    // is nothing to continue, so today's payload is already the right answer.
    let payloads = CursorInsertionRepair.repair(
      text: "Second thought.",
      context: CursorInsertionRepair.CaretText(left: "First thought.\n", right: "trailing text"),
      protectedWords: [], language: "en", lexicon: Self.prototypeLexicon)
    #expect(payloads.repairedText == nil)
    #expect(payloads.candidateRules == [.refusedNoLeftAnchor])
  }

  // MARK: - Language coverage

  /// The five words measured in the SHIPPED lexicon that are ordinary English
  /// lowercase words AND German nouns, which German capitalises mid-sentence
  /// without exception. Each one is a wrong-case defect an English-only rule
  /// would produce in the language spoken by the largest single share of our
  /// users, so they are the proof the gate is load-bearing rather than
  /// theoretical.
  static let germanNounCollisions = ["See", "Start", "Test", "Team", "Most"]

  @Test(
    "A word that is English-lowercase and a German noun is recased only in English",
    arguments: germanNounCollisions)
  func germanNounsKeepTheirCapital(_ word: String) {
    // The SHIPPED lexicon, not the prototype: the whole point is that these
    // words really are in the list we ship.
    let shipped = OrdinaryLowercaseLexicon.bundled
    #expect(shipped.isAvailable, "the shipped lexicon must load for this test to mean anything")

    let english = CursorInsertionRepair.repair(
      text: "\(word) is fine.",
      context: CursorInsertionRepair.CaretText(left: "I went to the ", right: ""),
      protectedWords: [], language: "en", lexicon: shipped)
    #expect(
      english.candidateRules.contains(.lowercasedFirst),
      "\(word) must still be recased in English, or this test proves nothing")

    let german = CursorInsertionRepair.repair(
      text: "\(word) ist gut.",
      context: CursorInsertionRepair.CaretText(left: "Ich gehe zum ", right: ""),
      protectedWords: [], language: "de", lexicon: shipped)
    #expect(german.repairedText?.hasPrefix(word) == true, "\(word) must keep its capital")
    #expect(german.candidateRules.contains(.caseSkipped(.languageNotSupported)))
    #expect(german.candidateRules.contains(.lowercasedFirst) == false)
  }

  @Test(
    "Only English is recased; every other language keeps the capital it was given",
    arguments: ["de", "fr", "es", "nl", "it", "pt", "ru", "sv", "tr", "ja", "zh"])
  func nonEnglishIsNeverRecased(_ language: String) {
    let payloads = CursorInsertionRepair.repair(
      text: "Store today.",
      context: CursorInsertionRepair.CaretText(left: "I went to the ", right: ""),
      protectedWords: [], language: language, lexicon: Self.prototypeLexicon)
    #expect(payloads.candidateRules.contains(.caseSkipped(.languageNotSupported)))
    #expect(payloads.repairedText?.contains("Store") == true)
  }

  @Test("Region variants resolve to their base language", arguments: ["en-US", "en_GB", "EN"])
  func englishVariantsStillRecase(_ language: String) {
    let payloads = CursorInsertionRepair.repair(
      text: "Store today.",
      context: CursorInsertionRepair.CaretText(left: "I went to the ", right: ""),
      protectedWords: [], language: language, lexicon: Self.prototypeLexicon)
    #expect(payloads.candidateRules.contains(.lowercasedFirst))
  }

  @Test("An unknown language spaces the seam but never recases", arguments: [nil, "", "und"])
  func unknownLanguageSpacesButDoesNotRecase(_ language: String?) {
    let payloads = CursorInsertionRepair.repair(
      text: "Store today.",
      context: CursorInsertionRepair.CaretText(left: "I went to the", right: ""),
      protectedWords: [], language: language, lexicon: Self.prototypeLexicon)
    #expect(payloads.candidateRules.contains(.leadingSpace))
    #expect(payloads.candidateRules.contains(.caseSkipped(.languageNotSupported)))
  }

  @Test(
    "A script that writes without spaces gets no space at either end",
    arguments: ["ja", "zh", "yue", "th", "lo", "my", "km"])
  func unsegmentedScriptsGetNoSpaces(_ language: String) {
    let payloads = CursorInsertionRepair.repair(
      text: "\u{4ECA}\u{65E5}\u{306F}\u{6674}\u{308C}",
      context: CursorInsertionRepair.CaretText(left: "\u{79C1}\u{306F}", right: ""),
      protectedWords: [], language: language, lexicon: Self.prototypeLexicon)
    #expect(payloads.candidateRules.contains(.leadingSpace) == false)
    #expect(payloads.candidateRules.contains(.trailingSpace) == false)
    #expect(payloads.candidateRules.contains(.trailingSpaceSkipped(.unsegmentedScript)))
    #expect(payloads.repairedText?.hasPrefix(" ") == false)
    #expect(payloads.repairedText?.hasSuffix(" ") == false)
  }

  @Test("Korean spaces its words, so it keeps the seam space")
  func koreanKeepsItsSpacing() {
    let payloads = CursorInsertionRepair.repair(
      text: "\u{C548}\u{B155}\u{D558}\u{C138}\u{C694}",
      context: CursorInsertionRepair.CaretText(left: "\u{C81C}\u{AC00}", right: ""),
      protectedWords: [], language: "ko", lexicon: Self.prototypeLexicon)
    #expect(payloads.candidateRules.contains(.leadingSpace))
    #expect(payloads.candidateRules.contains(.trailingSpace))
  }

  @Test("An unreadable caret context still yields today's payload in every language")
  func fallbackIsLanguageIndependent() {
    for language in ["en", "de", "ja", nil] {
      let payloads = CursorInsertionRepair.repair(
        text: "Store today.",
        context: nil,
        protectedWords: [], language: language, lexicon: Self.prototypeLexicon)
      #expect(payloads.legacyText == "Store today. ", "\(language ?? "nil")")
      #expect(payloads.repairedText == nil, "\(language ?? "nil")")
    }
  }
}
