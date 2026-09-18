import Foundation
import Testing

@testable import EnviousWisprPostProcessing

/// #3038: a spoken "slash" is READ before it is written, in both switch positions, by the
/// decision table in `InverseTextNormalizer.slashReading`. When one of these fails the user sees
/// `Slash exit.` in a terminal, `apples, bananas, or strawberries` instead of the list they
/// said, `using/exit` glued to the verb, or `we/the budget` where they meant the verb.
///
/// Three fixtures, all run through the REAL `normalize`, exact match, no folding:
/// - the reading table, one row at a time, positive and nearest negative;
/// - `spoken-slash-core.jsonl`: the 68 `core` and 9 `robustness` cases of the founder's
///   264-case external benchmark (`docs/audits/2026-09-18-3038-benchmark/`), expected outputs
///   authored independently of this implementation; the six documented misses carry their
///   ACTUAL output too, so a change in either direction is visible;
/// - `spoken-slash-traps.jsonl`: the 42 sentences the external and grounded reviews used to
///   break earlier versions of the table.
///
/// The setting is OFF in every row unless stated: that is the shipped default and the whole
/// point of the change.
@Suite(.tags(.productOutcome))
struct SpokenSlashReadingTests {

  private static let itn = InverseTextNormalizer()

  private static func off(_ s: String) -> String { itn.normalize(s, spokenPunctuation: false) }
  private static func on(_ s: String) -> String { itn.normalize(s, spokenPunctuation: true) }

  struct Row: Decodable {
    let id: String
    let input: String
    let expected: String
    let documented_miss: String?
    let actual: String?
  }

  static func loadRows(_ file: String) throws -> [Row] {
    let text = try String(
      contentsOf: InverseTextNormalizerParityTests.resourceDir.appending(path: file), encoding: .utf8)
    let decoder = JSONDecoder()
    return try text.split(separator: "\n").compactMap { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.isEmpty == false else { return nil }
      return try decoder.decode(Row.self, from: Data(trimmed.utf8))
    }
  }

  // MARK: - The founder's takes (app.log, 2026-09-18)

  @Test("A lone command loses the recogniser's capital and period")
  func loneCommand() {
    #expect(Self.off("Slash exit.") == "/exit")
    #expect(Self.off("Slash clear.") == "/clear")
    #expect(Self.off("slash compact") == "/compact")
    // Two sentences are two commands, and each keeps its own period.
    #expect(Self.off("slash clear. slash exit.") == "/clear. /exit.")
    // A command followed by more words is not a lone command.
    #expect(Self.off("Slash exit please.") == "/exit please.")
  }

  @Test("A command in a sentence keeps the space before it")
  func commandInSentence() {
    #expect(
      Self.off("Favorite Claude Code command is slash wfp.")
        == "Favorite Claude Code command is /wfp.")
    #expect(
      Self.off("Man, I love using slash exit as a command to close out of Claude Code quickly.")
        == "Man, I love using /exit as a command to close out of Claude Code quickly.")
    #expect(Self.off("Type slash help please.") == "Type /help please.")
    #expect(Self.off("Run slash compact and then slash exit.") == "Run /compact and then /exit.")
    #expect(Self.off("In Slack I use slash away a lot.") == "In Slack I use /away a lot.")
  }

  @Test("The recogniser's list comma is dropped and the list glues")
  func picnicList() {
    #expect(
      Self.off("For the picnic tomorrow, please bring apples, slash bananas, slash strawberries.")
        == "For the picnic tomorrow, please bring apples/bananas/strawberries.")
    #expect(
      Self.off("For tomorrow's meeting we need apples slash oranges slash bananas.")
        == "For tomorrow's meeting we need apples/oranges/bananas.")
  }

  /// The exact phrases the settings footnote, the What's New card and the help article quote,
  /// as standalone inputs, so the copy can never advertise an output the engine does not
  /// produce (`SpokenPunctuationCopy.helpFootnote`).
  @Test("The advertised examples are real outputs")
  func advertisedExamples() {
    #expect(Self.off("slash clear") == "/clear")
    #expect(Self.off("command is slash wfp") == "command is /wfp")
    #expect(Self.off("pros slash cons") == "pros/cons")
    #expect(Self.off("slash the budget") == "slash the budget")
    // The known miss the copy names.
    #expect(Self.off("slash prices") == "/prices")
  }

  // MARK: - The reading table, one row at a time

  @Test("Row 0: nothing after the marker keeps the word")
  func row0() {
    #expect(Self.off("the note talks about a missing slash.") == "the note talks about a missing slash.")
    #expect(Self.off("the meeting ends with slash") == "the meeting ends with slash")
    // A trailing "slash" at the end of a spoken path has no reading in the table either; the
    // word stays and polish may write the slash (documented; the baked negative row moved).
    #expect(Self.off("example.com slash docs slash") == "example.com/docs slash")
  }

  @Test("Row B1: a capitalised marker mid-sentence is a name")
  func rowB1ProperNoun() {
    #expect(
      Self.off("I liked Slash on that live recording, but the vocals were too quiet.")
        == "I liked Slash on that live recording, but the vocals were too quiet.")
    #expect(
      Self.off("We called the new internal tool Slash because its icon looked like a diagonal line.")
        == "We called the new internal tool Slash because its icon looked like a diagonal line.")
  }

  @Test("Rows B2 and B2': two markers in a row")
  func rowB2DoubleMarker() {
    #expect(Self.off("Use slash slash to show the punctuation menu.") == "Use /slash to show the punctuation menu.")
    // A scheme's pair glues only before a WRITTEN domain. The spoken-URL passes run BEFORE the
    // slash reading and refuse a domain preceded by the word "slash" (#2315 boundary), so
    // writing `://` before "example dot com" would leave a domain the next pass converts; the
    // words stay instead, exactly as before #3038.
    #expect(Self.off("https slash slash example dot com") == "https slash slash example dot com")
    #expect(Self.on("https colon slash slash example.com slash docs") == "https://example.com/docs")
    // A letter-by-letter scheme ("h t t p colon") glues too; the host is spelled the same way.
    #expect(Self.on("h t t p colon slash slash w w w dot x") == "h t t p://w w w dot x")
    #expect(Self.off("The note says: slash slash is the delimiter.") == "The note says: /slash is the delimiter.")
    #expect(
      Self.off("the variable H slash slash is malformed") == "the variable H slash slash is malformed")
  }

  @Test("Row 1: listed function pairs and pronoun pairs glue; near misses do not")
  func row1Pairs() {
    #expect(Self.off("Use and slash or in that clause.") == "Use and/or in that clause.")
    #expect(Self.off("The on slash off switch broke.") == "The on/off switch broke.")
    #expect(Self.off("It's a yes slash no question.") == "It's a yes/no question.")
    #expect(Self.off("It is a his slash her bathroom.") == "It is a his/her bathroom.")
    #expect(Self.off("He slash she can decide.") == "He/she can decide.")
    #expect(Self.off("Use he slash him pronouns.") == "Use he/him pronouns.")
    #expect(Self.off("They slash them works for me.") == "They/them works for me.")
    // Subject plus possessive is the verb, not a pair.
    #expect(Self.off("We slash our prices.") == "We slash our prices.")
    #expect(Self.off("You slash your bill in half.") == "You slash your bill in half.")
    // "to" never pairs.
    #expect(
      Self.off("We need to slash from five days to three.")
        == "We need to slash from five days to three.")
    // Not a listed pair: a verb with a particle after a conjunction keeps its words.
    #expect(Self.off("Raise the sword and slash down.") == "Raise the sword and slash down.")
  }

  @Test("Row B3: written neighbours glue")
  func rowB3WrittenNeighbours() {
    #expect(Self.off("Keep the A slash B test name.") == "Keep the A/B test name.")
    // The punctuation tighten that follows the pass pulls ".." onto the previous word; that
    // pre-existing tighten, not the reading, owns the missing space (benchmark EN077).
    #expect(Self.off("loads from .. slash shared slash defaults.json") == "loads from../shared/defaults.json")
  }

  @Test("Rows 2 and 3: a determiner, modal or subject pronoun before the marker keeps the word")
  func rows2and3LeftRefusals() {
    #expect(Self.off("Put a slash between the two words.") == "Put a slash between the two words.")
    #expect(Self.off("The slash commands are listed under shortcuts.") == "The slash commands are listed under shortcuts.")
    #expect(Self.off("The forward slash key sticks.") == "The forward slash key sticks.")
    #expect(Self.off("They will slash prices next week.") == "They will slash prices next week.")
    #expect(Self.off("I slash costs by cancelling unused services.") == "I slash costs by cancelling unused services.")
    #expect(Self.off("We can probably slash the waiting time.") == "We can probably slash the waiting time.")
  }

  @Test("Row 4: a determiner, pronoun, auxiliary, modal, conjunction or indefinite after the marker keeps the word")
  func row4RightRefusals() {
    #expect(Self.off("Slash the budget.") == "Slash the budget.")
    #expect(Self.off("Let's slash it.") == "Let's slash it.")
    #expect(
      Self.off("I need to finish this essay slash I really want to watch TV.")
        == "I need to finish this essay slash I really want to watch TV.")
    #expect(Self.off("How are your exams going slash are you free tomorrow?") == "How are your exams going slash are you free tomorrow?")
    #expect(Self.off("Slash and burn.") == "Slash and burn.")
    #expect(Self.off("Please do not just slash everything to fit.") == "Please do not just slash everything to fit.")
    // A glued chain never overrides this row.
    #expect(
      Self.off("Bring apples slash oranges slash the fruit in the fridge.")
        == "Bring apples/oranges slash the fruit in the fridge.")
    #expect(Self.off("Tea slash coffee slash I don't mind either.") == "Tea/coffee slash I don't mind either.")
  }

  @Test("Row 4': a preposition after the marker is prose unless it ends a path chain")
  func row4PrimePrepositions() {
    #expect(
      Self.off("I wrote the words forward slash in the instructions.")
        == "I wrote the words forward slash in the instructions.")
    #expect(Self.off("Go to settings slash general slash about.") == "Go to settings/general/about.")
    #expect(Self.off("Put it in docs slash next slash for the team.") == "Put it in docs/next slash for the team.")
  }

  @Test("Row 5: after \"to\" only a path chain converts")
  func row5To() {
    #expect(Self.off("I switched to slash compact after lunch.") == "I switched to slash compact after lunch.")
    #expect(Self.off("The reviewer wants us to slash unnecessary jargon.") == "The reviewer wants us to slash unnecessary jargon.")
    #expect(
      Self.off("The runner writes its output to slash tmp slash wispr before moving on.")
        == "The runner writes its output to /tmp/wispr before moving on.")
  }

  @Test("Rows B4 and B5: commands after a conjunction or a comma follow an earlier command")
  func rowsB4B5CommandLists() {
    #expect(
      Self.off("The two shortcuts are slash build and slash test; neither takes a filename.")
        == "The two shortcuts are /build and /test; neither takes a filename.")
    #expect(
      Self.off("The available commands are slash list, slash inspect, and slash resume.")
        == "The available commands are /list, /inspect, and /resume.")
    #expect(
      Self.off("They trim the packaging and slash shipping costs.")
        == "They trim the packaging and slash shipping costs.")
    // Documented miss: no earlier command, so the conjunction leaves the word alone.
    #expect(Self.off("Go ahead and slash exit now.") == "Go ahead and slash exit now.")
  }

  @Test("An earlier command informs the next marker only within its sentence")
  func earlierReadingStopsAtASentenceEnd() {
    // Same words as the B4 verb row, with a command in the sentence before: the verb survives.
    #expect(
      Self.off("Run slash help. They trim packaging and slash shipping costs.")
        == "Run /help. They trim packaging and slash shipping costs.")
    #expect(
      Self.off("Run slash help! Trim packaging and slash shipping costs.")
        == "Run /help! Trim packaging and slash shipping costs.")
    // A line break is a boundary too; a comma is not (B5).
    #expect(Self.off("Run slash help\nand slash budgets") == "Run /help\nand slash budgets")
    #expect(Self.off("Run slash help\r\nand slash budgets") == "Run /help\r\nand slash budgets")
    #expect(Self.off("slash list, sorry, slash inspect") == "/list, sorry, /inspect")
    // Two commands in two sentences still each read as a command on their own (B7).
    #expect(Self.off("slash clear. slash exit.") == "/clear. /exit.")
  }

  @Test("A chain spoken as \"forward slash\" is the same chain")
  func forwardSlashChain() {
    #expect(Self.off("output to forward slash tmp forward slash wispr") == "output to /tmp/wispr")
    #expect(Self.off("output to slash tmp forward slash wispr") == "output to /tmp/wispr")
    #expect(Self.off("output to forward slash tmp slash wispr") == "output to /tmp/wispr")
    // Row 5 without a chain still keeps the verb reading.
    #expect(Self.off("we need to forward slash costs") == "we need to forward slash costs")
  }

  @Test("Row B7: a clause boundary before the marker is a command; a comma before a chain is not")
  func rowB7Comma() {
    #expect(
      Self.off("Try slash preview, sorry, slash inspect; I always mix those two up.")
        == "Try /preview, sorry, /inspect; I always mix those two up.")
    #expect(
      Self.off("Um, the command was, I think, slash rewind, but check the help page.")
        == "Um, the command was, I think, /rewind, but check the help page.")
    // Documented miss: a two-item list with a recogniser comma reads as a command.
    #expect(Self.off("Bring apples, slash bananas.") == "Bring apples, /bananas.")
  }

  @Test("Row 6 and 7: prefix contexts space, content words glue")
  func rows6and7() {
    #expect(Self.off("After slash export finishes, check exports slash final.") == "After /export finishes, check exports/final.")
    #expect(Self.off("Then slash clear and then slash exit.") == "Then /clear and then /exit.")
    #expect(Self.off("Send it to the CEO slash founder.") == "Send it to the CEO/founder.")
    #expect(Self.off("Check the input slash output folder.") == "Check the input/output folder.")
    #expect(Self.off("Move it to src slash auth slash handler.") == "Move it to src/auth/handler.")
    // Documented misses: a bare-object imperative at utterance start, a reported instruction.
    #expect(Self.off("Slash prices now.") == "/prices now.")
    #expect(Self.off("The manager said slash prices, not staff.") == "The manager said /prices, not staff.")
  }

  @Test("Mixed roles in one utterance are decided per occurrence")
  func mixedRoles() {
    #expect(
      Self.off("We slash costs using slash audit, but the tool should never cancel anything.")
        == "We slash costs using /audit, but the tool should never cancel anything.")
  }

  @Test("Backslash still follows the setting")
  func backslashStaysGated() {
    #expect(Self.off("alpha back slash beta") == "alpha back slash beta")
    #expect(Self.off("alpha backslash beta") == "alpha backslash beta")
    #expect(Self.on("alpha backslash beta") == "alpha\\beta")
  }

  // MARK: - Fixtures

  @Test("External benchmark, core and robustness tracks, through the real normalizer")
  func benchmarkFixture() throws {
    let rows = try Self.loadRows("spoken-slash-core.jsonl")
    #expect(rows.count == 77, "fixture rows: \(rows.count)")
    var misses: [String] = []
    var pinnedMisses = 0
    for row in rows {
      let got = Self.off(row.input)
      if let actual = row.actual {
        pinnedMisses += 1
        #expect(got == actual, "\(row.id) documented miss moved: \(got.debugDescription)")
        #expect(got != row.expected, "\(row.id) documented miss now passes; retire its pin")
      } else if got != row.expected {
        misses.append("\(row.id): \(got.debugDescription)")
      }
    }
    #expect(pinnedMisses == 6)
    #expect(misses.isEmpty, "benchmark misses: \(misses)")
  }

  @Test("Review trap sentences through the real normalizer")
  func trapFixture() throws {
    let rows = try Self.loadRows("spoken-slash-traps.jsonl")
    #expect(rows.count == 49, "fixture rows: \(rows.count)")
    var misses: [String] = []
    for row in rows {
      // No trap carries a gated command word, so both switch positions must agree with it.
      if Self.off(row.input) != row.expected {
        misses.append("OFF \(row.id) \(row.input.debugDescription) -> \(Self.off(row.input).debugDescription)")
      }
      if Self.on(row.input) != row.expected {
        misses.append("ON \(row.id) \(row.input.debugDescription) -> \(Self.on(row.input).debugDescription)")
      }
    }
    #expect(misses.isEmpty, "trap misses: \(misses)")
  }

  /// Shapes the table tests above produce, plus the two the review named, re-normalised.
  static let idempotenceProbes: [Row] = [
    "Slash exit.", "slash clear. slash exit.", "Favorite Claude Code command is slash wfp.",
    "For the picnic tomorrow, please bring apples, slash bananas, slash strawberries.",
    "alpha slash to slash beta", "/exit .", "Use slash slash to show the punctuation menu.",
    "Go to settings slash general slash about.", "https slash slash example dot com",
    "h t t p colon slash slash w w w dot x", "example.com slash docs slash",
    "The available commands are slash list, slash inspect, and slash resume.",
    "Try slash preview, sorry, slash inspect; I always mix those two up.",
    "alpha new line slash beta", "backslash slash",
  ].enumerated().map { Row(id: "P\($0.offset)", input: $0.element, expected: "", documented_miss: nil, actual: nil) }

  /// The nine holdout rows this change moved (letter-by-letter spelled URLs whose single
  /// letters "a" and "i" now read as the article and the pronoun), pinned by identity with what
  /// each switch position writes. ON equals the regenerated baked row (the parity suite asserts
  /// that independently); OFF is the mirrored oracle run with its gated table emptied (the same
  /// rules the Swift OFF path applies), checked against the real engine by this test.
  static let movedHoldoutRows: [String: (off: String, on: String)] = [
      "from h t t p colon slash slash w w w dot h k d a i l y n e w s dot com dot h k slash n e w s d e t a i l slash i n d e x slash s e v e n s e v e n o o s i x c h a n g c o m m a s": (
        off: "from h t t p colon slash slash w w w dot h k d a i l y n e w s.com dot h k/n e w s d e t a i l slash i n d e x/s e v e n s e v e n 00 s i x c h a n g c o m m a s",
        on: "from h t t p://w w w dot h k d a i l y n e w s.com dot h k/n e w s d e t a i l slash i n d e x/s e v e n s e v e n 00 s i x c h a n g c o m m a s"),
      "from h t t p colon slash slash w w w dot s t l t o d a y dot com slash l i f e s t y l e s slash h e a l t h dash m e d dash f i t slash f i t n e s s slash t r a i l dash o f dash t h e dash w e e k dash b i t t e r s w e e t dash w o o d s dash a n d dash p h a n t o m dash f o r e s t slash a r t i c l e u n d e r s c o r e t e n f d a e i g h t e i g h t s e v e n dash f o r t y f o u r d e dash f i f t y f o u r f f o u r dash a o n e t h r e e f o u r dash o n i n e n i n e d f i v e b c t w e l v e c o n e a dot h t m l p h a n t o m forest": (
        off: "from h t t p colon slash slash w w w dot s t l t o d a y.com/l i f e s t y l e s/h e a l t h dash m e d dash f i t/f i t n e s s/t r a i l dash o f dash t h e dash w e e k dash b i t t e r s w e e t dash w 00 d s dash a n d dash p h a n t o m dash f o r e s t slash a r t i c l e u n d e r s c o r e t e n f d a e i g h t e i g h t s e v e n dash f o r t y f o u r d e dash f i f t y f o u r f f o u r dash a o n e t h r e e f o u r dash o n i n e n i n e d f i v e b c t w e l v e c o n e a dot h t m l p h a n t o m forest",
        on: "from h t t p://w w w dot s t l t o d a y.com/l i f e s t y l e s/h e a l t h dash m e d dash f i t/f i t n e s s/t r a i l dash o f dash t h e dash w e e k dash b i t t e r s w e e t dash w 00 d s dash a n d dash p h a n t o m dash f o r e s t slash a r t i c l e u n d e r s c o r e t e n f d a e i g h t e i g h t s e v e n dash f o r t y f o u r d e dash f i f t y f o u r f f o u r dash a o n e t h r e e f o u r dash o n i n e n i n e d f i v e b c t w e l v e c o n e a dot h t m l p h a n t o m forest"),
      "h t t p s colon slash slash a r c h i v e dot o r g slash s t r e a m slash a m e r i c a n s p e c i m e n o o a m e r r i c h hash p a g e slash n f i f t e e n slash m o d e slash t w o u p l a w s o n c o m m a alexander": (
        off: "h t t p s colon slash slash a r c h i v e dot o r g/s t r e a m slash a m e r i c a n s p e c i m e n 00 a m e r r i c h hash p a g e/n f i f t e e n/m o d e/t w o u p l a w s o n c o m m a alexander",
        on: "h t t p s://a r c h i v e dot o r g/s t r e a m slash a m e r i c a n s p e c i m e n 00 a m e r r i c h hash p a g e/n f i f t e e n/m o d e/t w o u p l a w s o n c o m m a alexander"),
      "h t t p colon slash slash c m f r dash p h i l dot o r g slash e n d i m p u n i t y i n p h slash t w e n t y t h i r t e e n slash e l e v e n slash i n f o g r a p h i c dash k i l l i n g dash o f dash j o u r n a l i s t s dash a n d dash m e d i a dash w o r k e r s dash i n dash t h e dash p h i l i p p i n e s slash": (
        off: "h t t p colon slash slash c m f r dash p h i l dot o r g/e n d i m p u n i t y i n p h/t w e n t y t h i r t e e n/e l e v e n slash i n f o g r a p h i c dash k i l l i n g dash o f dash j o u r n a l i s t s dash a n d dash m e d i a dash w o r k e r s dash i n dash t h e dash p h i l i p p i n e s slash",
        on: "h t t p://c m f r dash p h i l dot o r g/e n d i m p u n i t y i n p h/t w e n t y t h i r t e e n/e l e v e n slash i n f o g r a p h i c dash k i l l i n g dash o f dash j o u r n a l i s t s dash a n d dash m e d i a dash w o r k e r s dash i n dash t h e dash p h i l i p p i n e s slash"),
      "h t t p colon slash slash w w w dot c r u i s e c r i t i c dot com slash b l o g slash i n d e x dot p h p slash t w e n t y f i f t e e n slash o f o u r slash t h i r t e e n slash w h e r e dash i n dash t h e dash w o r l d dash i s dash c r u i s e dash c r i t i c dash f i f t y o n e slash t e n": (
        off: "h t t p colon slash slash w w w dot c r u i s e c r i t i c.com/b l o g slash i n d e x dot p h p/t w e n t y f i f t e e n/o f o u r/t h i r t e e n/w h e r e dash i n dash t h e dash w o r l d dash i s dash c r u i s e dash c r i t i c dash f i f t y o n e/t e n",
        on: "h t t p://w w w dot c r u i s e c r i t i c.com/b l o g slash i n d e x dot p h p/t w e n t y f i f t e e n/o f o u r/t h i r t e e n/w h e r e dash i n dash t h e dash w o r l d dash i s dash c r u i s e dash c r i t i c dash f i f t y o n e/t e n"),
      "h t t p colon slash slash c f p u b dot e p a dot g o v slash n c e a slash i r i s slash i n d e x dot c f m": (
        off: "h t t p colon slash slash c f p u b dot e p a dot g o v/n c e a slash i r i s slash i n d e x dot c f m",
        on: "h t t p://c f p u b dot e p a dot g o v/n c e a slash i r i s slash i n d e x dot c f m"),
      "h t t p colon slash slash w w w dot i i s g dot n l slash a r c h i v e s slash e n slash f i l e s slash i slash o n e o e i g h t e i g h t s i x o s i x t w o dot p h p b a r a h e n i": (
        off: "h t t p colon slash slash w w w dot i i s g dot n l slash a r c h i v e s/e n/f i l e s slash i slash o n e o e i g h t e i g h t s i x o s i x t w o dot p h p b a r a h e n i",
        on: "h t t p://w w w dot i i s g dot n l slash a r c h i v e s/e n/f i l e s slash i slash o n e o e i g h t e i g h t s i x o s i x t w o dot p h p b a r a h e n i"),
      "h t t p colon slash slash w w w dot f a s t c o c r e a t e dot com slash o n e s i x s e v e n n i n e n i n e o o slash a dash c r e a t i v e dash m o v e m e n t dash g r o w s dash i n dash b r o o k l y n dash m a s o n dash j a r dash b r i n g s dash t h e dash a r t dash b a c k dash t o dash m u s i c b r o w n": (
        off: "h t t p colon slash slash w w w dot f a s t c o c r e a t e.com/o n e s i x s e v e n n i n e n i n e 00 slash a dash c r e a t i v e dash m o v e m e n t dash g r o w s dash i n dash b r 00 k l y n dash m a s o n dash j a r dash b r i n g s dash t h e dash a r t dash b a c k dash t o dash m u s i c b r o w n",
        on: "h t t p://w w w dot f a s t c o c r e a t e.com/o n e s i x s e v e n n i n e n i n e 00 slash a dash c r e a t i v e dash m o v e m e n t dash g r o w s dash i n dash b r 00 k l y n dash m a s o n dash j a r dash b r i n g s dash t h e dash a r t dash b a c k dash t o dash m u s i c b r o w n"),
      "from h t t p colon slash slash b l o g s dot u b c dot c a slash d e a n slash t w e n t y e l e v e n slash o f i v e slash c a n a d i a n dash a c a d e m i c dash l i b r a r i e s dash u s e dash o f dash s o c i a l dash m e d i a dash t w e n t y e l e v e n dash u p d a t e slash h a m l i n": (
        off: "from h t t p colon slash slash b l o g s dot u b c dot c a slash d e a n/t w e n t y e l e v e n/o f i v e/c a n a d i a n dash a c a d e m i c dash l i b r a r i e s dash u s e dash o f dash s o c i a l dash m e d i a dash t w e n t y e l e v e n dash u p d a t e/h a m l i n",
        on: "from h t t p://b l o g s dot u b c dot c a slash d e a n/t w e n t y e l e v e n/o f i v e/c a n a d i a n dash a c a d e m i c dash l i b r a r i e s dash u s e dash o f dash s o c i a l dash m e d i a dash t w e n t y e l e v e n dash u p d a t e/h a m l i n"),
  ]

  @Test("The holdout rows the change moved are pinned by identity in both switch positions")
  func movedHoldoutRowsPinned() throws {
    let baked = Dictionary(
      try InverseTextNormalizerParityTests.loadRows("parity_holdout.jsonl").map { ($0.input, $0.expected) },
      uniquingKeysWith: { first, _ in first })
    for (input, pin) in Self.movedHoldoutRows {
      #expect(baked[input] == pin.on, "baked \(input.prefix(60).debugDescription)")
      #expect(Self.on(input) == pin.on, "ON \(input.prefix(60).debugDescription) -> \(Self.on(input).debugDescription)")
      #expect(Self.off(input) == pin.off, "OFF \(input.prefix(60).debugDescription) -> \(Self.off(input).debugDescription)")
    }
  }

  @Test("Every fixture output re-normalises to itself in both switch positions")
  func idempotence() throws {
    let rows = try Self.loadRows("spoken-slash-core.jsonl") + Self.loadRows("spoken-slash-traps.jsonl")
      + Self.idempotenceProbes
    for flag in [false, true] {
      var unstable: [String] = []
      for row in rows {
        let once = Self.itn.normalize(row.input, spokenPunctuation: flag)
        let twice = Self.itn.normalize(once, spokenPunctuation: flag)
        if once != twice { unstable.append("\(row.id): \(once.debugDescription) -> \(twice.debugDescription)") }
      }
      #expect(unstable.isEmpty, "non-idempotent with spokenPunctuation=\(flag): \(unstable)")
    }
  }
}
