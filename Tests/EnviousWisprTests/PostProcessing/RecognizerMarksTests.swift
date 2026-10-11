import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPipeline
@testable import EnviousWisprPostProcessing

/// #3594: with Spoken punctuation on, the engine's own comma or period beside a mark the user speaks is
/// removed, and a command the engine wrote twice becomes one.
///
/// **Product Outcome.** When these fail the user sees a doubled or leftover mark next to a mark they
/// spoke (`,..`, `. ,`), a spoken mark that vanished, or a changed number or word in their dictated text.
///
/// Expectations are LITERAL and hand-written from the rules in the issue plan, never taken from the code
/// under test. The recorded-take rows use RAW ENGINE TEXT captured from the real app (Parakeet v3 and
/// WhisperKit), the hand-authored intended text, and the output of the code BEFORE this change (`today*`
/// fields), so no expectation is derived from the candidate.
@MainActor
@Suite("Recognizer marks beside spoken commands (#3594)", .tags(.productOutcome))
struct RecognizerMarksTests {

  private static let itn = InverseTextNormalizer()

  private static func english(_ input: String) -> String {
    itn.normalize(input, spokenPunctuation: true)
  }

  private static func startWord(_ input: String, _ language: String, start: String? = nil) -> String
  {
    itn.applyStartWordPunctuation(
      input, language: language,
      startWord: start ?? SpokenPunctuationRules.defaultStartWord(for: language) ?? "",
      protectedSentinels: []
    ).text
  }

  private static func newlines(_ text: String) -> Int { text.filter { $0 == "\n" }.count }

  // MARK: - English bare-word route: literal boundary rows

  nonisolated static let englishRows: [(String, String)] = [
    ("Hello. Period", "Hello."),
    ("hello period", "hello."),
    ("period hello", ". Hello"),
    ("Mr. period", "Mr."),
    ("3. period", "3."),
    ("U.S. comma", "U.S.,"),
    ("Dr. question mark", "Dr.?"),
    ("e.g. comma", "e.g.,"),
    ("p.m. comma", "p.m.,"),
    ("end.) comma", "end),"),
    ("\"quote.\" period", "\"quote\"."),
    ("period.period", "."),
    ("comma , comma", ","),
    ("colon: colon", ":"),
    ("period. period. period.", "."),
    ("period period", ".."),
    ("wait... period", "wait...."),
    ("example dot com period", "example.com."),
  ]

  @Test(
    "English: the engine's mark beside a spoken mark command is removed",
    arguments: RecognizerMarksTests.englishRows)
  func englishBoundaryRows(input: String, expected: String) {
    #expect(Self.english(input) == expected, "input \(input.debugDescription)")
  }

  @Test(
    "English: the sentence end in front of a line break stays; a mid-sentence phrase keeps today's reading"
  )
  func englishLineBreakRows() {
    #expect(Self.english("Hello there. New line. World is big.") == "Hello there. \n World is big.")
    #expect(Self.english("Add a new line.") == "Add a.")
    #expect(Self.english("a. New line. New line. b") == "a. \n B")
  }

  @Test(
    "English: a mark after a line break that follows a mark command or a pause mark is the engine's"
  )
  func englishBreakAfterMarkCommand() {
    let comma = Self.english("Dear Maria. Comma. New paragraph. Thanks")
    #expect(Self.newlines(comma) == 2, "got \(comma.debugDescription)")
    #expect(comma.hasPrefix("Dear Maria,"), "got \(comma.debugDescription)")
    #expect(comma.hasSuffix("Thanks"), "got \(comma.debugDescription)")

    let period = Self.english("Thanks for the update Period New paragraph. The next step")
    #expect(Self.newlines(period) == 2, "got \(period.debugDescription)")
    #expect(period.hasPrefix("Thanks for the update."), "got \(period.debugDescription)")
    #expect(period.hasSuffix("The next step"), "got \(period.debugDescription)")

    let pause = Self.english("Dear Maria, new paragraph, thank you for your help, period.")
    #expect(Self.newlines(pause) == 2, "got \(pause.debugDescription)")
    #expect(pause.hasSuffix("thank you for your help."), "got \(pause.debugDescription)")
  }

  @Test(
    "English: a standalone repeated break merges at helper level and normalizes to a lone period")
  func standaloneRepeatedBreak() {
    #expect(
      InverseTextNormalizer.reconcileEnglishRecognizerMarks("new line. New line.") == "new line.")
    #expect(Self.english("new line. New line.") == ".")
  }

  @Test("English: text with no command phrase, and commands the user spoke twice, are untouched")
  func englishUntouched() {
    for text in [
      "I like apples. They are good.", "Wait... What? Really?!", "Hello, world.",
      "The total is $25, and the tax is $3.",
    ] {
      #expect(Self.english(text) == text, "input \(text.debugDescription)")
    }
    #expect(Self.english("alpha comma comma beta") == "alpha,, beta")
  }

  @Test("English: switch off leaves the engine's marks and the command words")
  func englishSwitchOff() {
    #expect(
      Self.itn.normalize("Hello. Period", spokenPunctuation: false) == "Hello. Period")
  }

  // MARK: - Start-word routes: literal boundary rows

  @Test(
    "Start word: a pause mark between the start word and the command is tolerated",
    arguments: [
      ("de", "Diktiere. Punkt.", "."),
      ("de", "diktiere, Komma", ","),
      ("fr", "Place, virgule", ","),
    ])
  func startWordTolerance(language: String, input: String, expected: String) {
    #expect(Self.startWord(input, language) == expected, "input \(input.debugDescription)")
  }

  nonisolated static let startWordRows: [(String, String, String)] = [
    ("de", "Das ist toll. Diktiere Ausrufezeichen.", "Das ist toll!"),
    ("de", "Wie geht es dir. Diktiere Fragezeichen", "Wie geht es dir?"),
    ("de", "z.B. Diktiere Komma", "z.B.,"),
    ("de", "am 2. Diktiere Komma", "am 2.,"),
    ("de", "Es kostet 5. Diktiere Punkt", "Es kostet 5."),
    ("de", "Moment\u{2026} Diktiere Punkt", "Moment\u{2026}."),
    ("de", "Wirklich?! Diktiere Punkt", "Wirklich?!."),
    ("de", "Erste Zeile. Diktiere neue Zeile zweite", "Erste Zeile.\nZweite"),
    ("fr", "Comment \u{00E7}a va\u{00A0}? Place point d'interrogation", "Comment \u{00E7}a va?"),
    ("fr", "Comment \u{00E7}a va\u{202F}? Place point d'interrogation", "Comment \u{00E7}a va?"),
    ("fr", "Place the order. Place, virgule", "Place the order,"),
    (
        "es", "\u{00BF}C\u{00F3}mo est\u{00E1}s? A\u{00F1}ade punto",
        "\u{00BF}C\u{00F3}mo est\u{00E1}s."
      ),
  ]

  @Test(
    "Start word: the engine's sentence mark before a mark command is replaced; protected marks stay",
    arguments: RecognizerMarksTests.startWordRows)
  func startWordBoundaryRows(language: String, input: String, expected: String) {
    #expect(Self.startWord(input, language) == expected, "input \(input.debugDescription)")
  }

  @Test("Start word: a command the engine wrote twice becomes one; two the user spoke stay two")
  func startWordRepeats() {
    #expect(Self.startWord("Diktiere Punkt. Diktiere Punkt.", "de") == ".")
    #expect(Self.startWord("alpha Diktiere Punkt Diktiere Punkt beta", "de") == "alpha.. Beta")
  }

  @Test("Start word: an unrelated start word elsewhere in the text is byte-identical")
  func startWordUnrelatedOccurrence() {
    #expect(
      Self.startWord("Diktiere, bitte langsam. Das ist toll.", "de")
        == "Diktiere, bitte langsam. Das ist toll.")
  }

  // MARK: - Idempotence

  @Test("Both routes: a second pass over the output of every boundary row changes nothing")
  func idempotent() {
    for (input, _) in Self.englishRows + [
      ("He said \"Hello.\" period", ""),
      ("Hello there. New line. World is big.", ""),
      ("Add a new line.", ""),
      ("Dear Maria. Comma. New paragraph. Thanks", ""),
      ("Thanks for the update Period New paragraph. The next step", ""),
      ("a. New line. New line. b", ""),
      ("new line. New line.", ""),
      ("Dear Maria, new paragraph, thank you, period.", ""),
    ] {
      let once = Self.english(input)
      #expect(Self.english(once) == once, "english input \(input.debugDescription)")
    }
    for (language, input, _) in Self.startWordRows + [
      ("de", "Diktiere. Punkt.", "."), ("de", "diktiere, Komma", ","), ("fr", "Place, virgule", ","),
    ] {
      let once = Self.startWord(input, language)
      #expect(Self.startWord(once, language) == once, "\(language) input \(input.debugDescription)")
    }
  }

  // MARK: - Findings from the chunk review

  @Test("Start word: a mark that directly follows a start word is the engine's conversion and stays")
  func markAfterStartWordStays() {
    #expect(
      Self.startWord("Anna, Diktiere, Diktiere Komma Jonas", "de") == "Anna, Diktiere,, Jonas")
    #expect(Self.startWord("Hallo: Diktiere Komma", "de") == "Hallo,")
    #expect(Self.startWord("Hallo; Diktiere Punkt", "de") == "Hallo.")
  }

  @Test("English: a mark detached by ordinary whitespace or a line break is not glued to the word")
  func detachedMarkIsNotRemoved() {
    for input in ["word . comma", "word\n. comma", "word  . comma"] {
      #expect(
        InverseTextNormalizer.absorbRecognizerMarks(
          in: input, markForms: "comma", breakForms: "new line") == input,
        "input \(input.debugDescription)")
    }
  }

  @Test("English: the engine's sentence mark after a spoken number is removed; a numbered marker is not an ordinal here")
  func markAfterNumber() {
    #expect(Self.english("The total is twenty five dollars. Comma and the tax") == "The total is $25, and the tax")
    #expect(Self.english("It takes maybe ten. Period.") == "It takes maybe 10.")
    #expect(
      InverseTextNormalizer.absorbRecognizerMarks(
        in: "3. comma", markForms: "comma", breakForms: "new line") == "3 comma")
  }

  @Test("English: a command inside a hyphenated word, and an ellipsis or mixed run after a command, keep their marks")
  func commandBoundariesAndRuns() {
    // `semi-colon` holds no command (conversion needs whitespace before it), so its full stop stays.
    #expect(Self.english("It is a semi-colon.") == "It is a semi-colon.")
    // One or two engine marks after a command are the engine's; an ellipsis or a mixed run is not.
    #expect(Self.english("Wait comma...") == "Wait,...")
    #expect(Self.english("Wait comma?!") == "Wait,?!")
    #expect(Self.english("Wait comma.. Next") == "Wait, Next")
  }

  @Test("Start word: two different commands the engine separated by a mark are not a repeat")
  func differentCommandsAreNotARepeat() {
    // `point` is a prefix of `point d'interrogation`; the second is its own, complete command.
    #expect(Self.startWord("Salut Place point. Place point d'interrogation", "fr") == "Salut.?")
  }

  @Test("Start word: a repeat needs the start word again, and an ellipsis or mixed run between copies stays")
  func repeatNeedsTheStartWord() {
    // `Punkt` after the first command is an ordinary noun ("Punkt zwei"), not an engine copy.
    #expect(
      Self.startWord("Das ist erledigt Diktiere Punkt. Punkt zwei folgt", "de")
        == "Das ist erledigt. Punkt zwei folgt")
    #expect(Self.startWord("Diktiere Punkt. Punkt.com", "de") == ". Punkt.com")
    // Between two copies of a command, a mixed run or a three-dot ellipsis is not the engine's mark.
    #expect(Self.startWord("Warte Diktiere Punkt?! Diktiere Punkt", "de") == "Warte.?!.")
    #expect(Self.startWord("Diktiere Punkt. Diktiere Punkt.", "de") == ".")
  }

  @Test("Start word: a closing quote between two commands never costs the first command its mark")
  func closerBetweenCommandsKeepsTheFirstMark() {
    #expect(Self.startWord("Hallo Diktiere Fragezeichen\" Diktiere Komma", "de") == "Hallo?\",")
    #expect(Self.startWord("Hallo Diktiere Punkt) Diktiere Komma", "de") == "Hallo.),")
  }

  @Test("Start word: English with a start word has no ordinal dot, like the bare-word route")
  func englishStartWordHasNoOrdinalDot() {
    #expect(Self.startWord("It costs 5. Dictate comma next", "en", start: "Dictate") == "It costs 5, next")
    #expect(Self.startWord("am 2. Diktiere Komma weiter", "de") == "am 2., weiter")
  }

  // MARK: - Aligned scoring (independent of the code under test)

  /// Delete the CONVERTED spans from both sides before scoring: with a start word only a complete
  /// `start word [.,] command` span goes (a lone start word or command word is an ordinary word and
  /// stays), on the bare English route a command form goes. Forms come from `SpokenPunctuationRules`, which
  /// supplies inputs only; no expectation is read from the code under test.
  private static func cleaned(_ text: String, language: String, start: String) -> String {
    var t = text.lowercased().replacingOccurrences(of: "\u{00BF}", with: "")
      .replacingOccurrences(of: "\u{00A1}", with: "")
    // Production needs HORIZONTAL space between a start word and its command (a line break splits them), so
    // only horizontal space may be part of a converted span there; the bare English route takes any space.
    let formSpace = start.isEmpty ? #"\s+"# : #"[ \t\x{00A0}]+"#
    let forms = (SpokenPunctuationRules.startWordForms(for: language) ?? [])
      .sorted { $0.count > $1.count }
      .map {
        NSRegularExpression.escapedPattern(for: $0.lowercased())
          .replacingOccurrences(of: " ", with: formSpace)
          .replacingOccurrences(of: "'", with: #"['\x{2019}]"#)  // production accepts the typographic apostrophe
      }
      .joined(separator: "|")
    if start.isEmpty {
      t = t.replacingOccurrences(of: #"\b(?:"# + forms + #")\b"#, with: " ", options: .regularExpression)
    } else {
      t = t.replacingOccurrences(
        of: #"\b"# + NSRegularExpression.escapedPattern(for: start.lowercased()) + #"[.,]?[ \t\x{00A0}]+(?:"# + forms
          + #")\b[.,!?]?"#, with: " ", options: .regularExpression)
    }
    return t
  }

  private static let breakToken = "\u{00B6}"

  /// Ordered tokens: `word` + `marks` for each word (a mark standing alone attaches to the word before it,
  /// French spacing), and a break token carrying the line-break count for every whitespace run that holds one.
  private static func sequence(_ text: String, language: String, start: String) -> [String] {
    let closers = CharacterSet(charactersIn: "\"'\u{201C}\u{201D}\u{2018}\u{2019}()[]\u{00AB}\u{00BB}")
    var out: [(word: String, marks: String)] = []
    var run = ""
    var inSpace = false
    func flushSpace() {
      let n = run.filter { $0 == "\n" }.count
      if n > 0 { out.append((breakToken, String(n))) }
      run = ""
    }
    var piece = ""
    func flushWord() {
      guard !piece.isEmpty else { return }
      var word = piece
      var marks = ""
      while let last = word.last, ".,;:!?\u{2026}".contains(last) {
        if ".,;:!?".contains(last) { marks = String(last) + marks }
        word.removeLast()
      }
      word = word.trimmingCharacters(in: closers)
      if word.isEmpty, let previous = out.last, previous.word != breakToken {
        out[out.count - 1].marks += marks
      } else if !word.isEmpty || !marks.isEmpty {
        out.append((word, marks))
      }
      piece = ""
    }
    for character in cleaned(text, language: language, start: start) {
      if character.isWhitespace {
        if !inSpace { flushWord() }
        inSpace = true
        run.append(character)
      } else {
        if inSpace { flushSpace() }
        inSpace = false
        piece.append(character)
      }
    }
    if inSpace { flushSpace() } else { flushWord() }
    return out.map { $0.word + "\u{1}" + $0.marks }
  }

  private static func lcs(_ a: [String], _ b: [String]) -> Int {
    var previous = [Int](repeating: 0, count: b.count + 1)
    for x in a {
      var current = [0]
      for (j, y) in b.enumerated() {
        current.append(x == y ? previous[j] + 1 : max(previous[j + 1], current[j]))
      }
      previous = current
    }
    return previous[b.count]
  }

  /// Order-aware mark errors tied to the host word, and line/paragraph-break errors as positioned tokens.
  /// Only words present on BOTH sides are scored, so an engine wording difference is not charged to
  /// punctuation; break tokens always are.
  private static func alignedErrors(
    intended: String, got: String, language: String, start: String
  ) -> (marks: Int, breaks: Int) {
    func host(_ token: String) -> String { String(token.split(separator: "\u{1}", omittingEmptySubsequences: false)[0]) }
    var a = sequence(intended, language: language, start: start)
    var b = sequence(got, language: language, start: start)
    let shared = Set(a.map(host)).intersection(Set(b.map(host))).subtracting([breakToken])
    func keep(_ token: String) -> Bool { host(token) == breakToken || shared.contains(host(token)) }
    a = a.filter(keep)
    b = b.filter(keep)
    // A break is positioned by the number of scored words before it, so a moved break is an error.
    func positionBreaks(_ tokens: [String]) -> [String] {
      var wordPosition = 0
      return tokens.map { token in
        if host(token) == breakToken { return token + "\u{1}" + String(wordPosition) }
        wordPosition += 1
        return token
      }
    }
    a = positionBreaks(a)
    b = positionBreaks(b)
    let total = a.count + b.count - 2 * lcs(a, b)
    let breaksA = a.filter { host($0) == breakToken }
    let breaksB = b.filter { host($0) == breakToken }
    let breaks = breaksA.count + breaksB.count - 2 * lcs(breaksA, breaksB)
    return (total - breaks, breaks)
  }

  /// Measured with the throwaway prototype BEFORE the production code existed (annotations frozen first):
  /// aligned mark errors over all scored takes of the group, and positioned break errors. Production may
  /// not exceed them.
  private static let alignedCeiling: [String: Int] = [
    "parakeet/english": 16, "whisperKit/english": 8, "parakeet/startword": 59,
    "whisperKit/startword": 47,
  ]
  private static let breakCeiling: [String: Int] = [
    "parakeet/english": 0, "whisperKit/english": 0, "parakeet/startword": 1, "whisperKit/startword": 1,
  ]

  /// The scorer is only an instrument if it can fail: a mark swapped between repeated words, a paragraph
  /// break moved or split, and a mark on the wrong word all cost errors.
  @Test("The aligned scorer rejects swapped marks, moved or split breaks and a mark on the wrong word")
  func scorerControls() {
    func score(_ intended: String, _ got: String) -> (marks: Int, breaks: Int) {
      Self.alignedErrors(intended: intended, got: got, language: "en", start: "")
    }
    #expect(score("same, same.", "same, same.") == (0, 0))
    #expect(score("same, same.", "same. same,").marks > 0)
    #expect(score("alpha\n\nbeta gamma", "alpha\nbeta\ngamma").breaks > 0)
    #expect(score("alpha\n\nbeta gamma", "alpha beta gamma").breaks > 0)
    #expect(score("alpha beta, gamma", "alpha, beta gamma").marks > 0)
    #expect(score("alpha\n\nbeta gamma", "alpha beta\n\ngamma").breaks > 0)
    // A line break between a start word and its command is not a converted span: those words stay.
    func words(_ text: String) -> [String] {
      Self.cleaned(text, language: "de", start: "Diktiere").split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
    #expect(words("Anna Diktiere\nPunkt Jonas") != words("Anna Jonas"))
    #expect(words("Anna Diktiere Punkt Jonas") == words("Anna Jonas"))
  }

  @Test("Recorded takes: aligned errors stay under the ceiling and no take is worse than today; words are preserved")
  func recordedTakesAlignedAndWordsPreserved() async throws {
    var errors: [String: Int] = [:]
    var breaks: [String: Int] = [:]
    var problems: [String] = []
    func words(_ text: String, _ take: Take) -> [String] {
      Self.cleaned(text, language: take.lang, start: take.start)
        .split(whereSeparator: { " \n\t.,;:!?\u{2026}".contains($0) }).map(String.init)
    }
    for take in try Self.takes() where take.kind == "scored" {
      let out = try await run(take)
      let today = try #require(take.todayOutput)
      let now = Self.alignedErrors(intended: take.expected, got: out, language: take.lang, start: take.start)
      let before = Self.alignedErrors(intended: take.expected, got: today, language: take.lang, start: take.start)
      let key = "\(take.engine)/\(take.group)"
      errors[key, default: 0] += now.marks
      breaks[key, default: 0] += now.breaks
      if now.marks > before.marks || now.breaks > before.breaks {
        problems.append("worse than today: \(take.engine) \(take.id) marks \(now.marks) vs \(before.marks), breaks \(now.breaks) vs \(before.breaks) -> \(out.debugDescription)")
      }
      // Words are preserved: what the pre-change output said (minus the converted spans) is what the new
      // output says.
      let expectedWords = words(today, take)
      if expectedWords != words(out, take) {
        problems.append("words changed: \(take.engine) \(take.id) \(today.debugDescription) -> \(out.debugDescription)")
      }
    }
    for (key, ceiling) in Self.alignedCeiling {
      #expect((errors[key] ?? Int.max) <= ceiling, "\(key): \(errors[key] ?? -1) aligned errors, ceiling \(ceiling)")
    }
    for (key, ceiling) in Self.breakCeiling {
      #expect((breaks[key] ?? Int.max) <= ceiling, "\(key): \(breaks[key] ?? -1) break errors, ceiling \(ceiling)")
    }
    #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
  }

  // MARK: - Recorded engine takes

  private struct Take: Decodable {
    let id: String
    let engine: String
    let lang: String
    let group: String
    let start: String
    let raw: String
    let kind: String
    let expected: String
    let todayMissing: Int?
    let todayOutput: String?
  }

  private static let fixtureURL: URL = URL(filePath: #filePath)
    .deletingLastPathComponent()  // PostProcessing
    .deletingLastPathComponent()  // EnviousWisprTests
    .appending(path: "Resources/InverseTextNormalizer/recognizer-marks-matrix.jsonl")

  private static func takes() throws -> [Take] {
    let text = try String(contentsOf: fixtureURL, encoding: .utf8)
    let decoder = JSONDecoder()
    return try text.split(separator: "\n").map {
      try decoder.decode(Take.self, from: Data($0.utf8))
    }
  }

  private func run(_ take: Take) async throws -> String {
    let overrides: [String: String] =
      take.group == "startword" && take.lang == "en" ? ["en": take.start] : [:]
    let step = InverseTextNormalizationStep()
    step.spokenPunctuation = SpokenPunctuationSettings(enabled: true, startWordOverrides: overrides)
    step.backendSupportsLID = take.engine == "whisperKit"
    return try await step.process(TextProcessingContext(text: take.raw, language: take.lang)).text
  }

  private static func marks(_ text: String) -> [Character: Int] {
    var counts: [Character: Int] = [:]
    for c in text where ".,!?".contains(c) { counts[c, default: 0] += 1 }
    return counts
  }

  private static func difference(_ a: [Character: Int], _ b: [Character: Int]) -> Int {
    ".,!?".reduce(0) { $0 + max(0, (a[$1] ?? 0) - (b[$1] ?? 0)) }
  }

  private static func hasDoubledMark(_ text: String) -> Bool {
    text.range(of: #"[.,;:!?]\s*[.,;:!?]"#, options: .regularExpression) != nil
  }

  /// Measured with the throwaway prototype before the build: engine mark errors (missing plus stray) over
  /// all scored takes of the group. A group may not exceed them.
  private static let errorCeiling: [String: Int] = [
    "parakeet/english": 11, "whisperKit/english": 4, "parakeet/startword": 28,
    "whisperKit/startword": 15,
  ]

  @Test("Recorded takes: no doubled mark, no lost spoken mark, errors within the measured ceiling")
  func recordedScoredTakes() async throws {
    var errors: [String: Int] = [:]
    var rows: [String: Int] = [:]
    var problems: [String] = []
    for take in try Self.takes() where take.kind == "scored" {
      let out = try await run(take)
      let key = "\(take.engine)/\(take.group)"
      rows[key, default: 0] += 1
      let intended = Self.marks(take.expected)
      let got = Self.marks(out)
      let missing = Self.difference(intended, got)
      errors[key, default: 0] += missing + Self.difference(got, intended)
      if Self.hasDoubledMark(out) {
        problems.append("doubled mark: \(take.engine) \(take.id) -> \(out.debugDescription)")
      }
      if missing > (take.todayMissing ?? 0) {
        problems.append("lost a spoken mark: \(take.engine) \(take.id) -> \(out.debugDescription)")
      }
    }
    #expect(rows.values.reduce(0, +) == 223, "scored rows read: \(rows)")
    for (key, ceiling) in Self.errorCeiling {
      #expect(
        (errors[key] ?? Int.max) <= ceiling,
        "\(key): \(errors[key] ?? -1) errors, ceiling \(ceiling)")
    }
    #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
  }

  @Test(
    "Recorded takes: takes with no command, ordinary-word decoys and languages without a table equal today's output"
  )
  func recordedUnchangedTakes() async throws {
    var checked = 0
    var problems: [String] = []
    for take in try Self.takes() where take.kind == "same" || take.kind == "accepted" {
      let out = try await run(take)
      checked += 1
      if out != take.expected {
        problems.append(
          "\(take.engine) \(take.id): got \(out.debugDescription), expected \(take.expected.debugDescription)"
        )
      }
    }
    #expect(checked == 104, "unchanged rows read: \(checked)")
    #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
  }
}
