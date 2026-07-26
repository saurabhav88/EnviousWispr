import Testing

@testable import EnviousWisprServices

// The caret-context read contract (#1785 Chunk 4).
//
// The live accessibility round-trips are exercised by Live UAT, following the
// same split this file's siblings use. What is pinned here is the RANGE
// PLANNING: every offset is UTF-16, every comparison is written to survive
// hostile input from a foreign process, and every failure returns nil so the
// caller keeps today's behaviour.
//
// Reading the WRONG window is worse than reading none, because it produces a
// confident repair against text the user never dictated into.
@Suite("PasteService.assembleCaretContext")
struct PasteCaretContextTests {

  /// Serves ranges out of a known document, and records every range asked for
  /// so a test can prove a read was NOT attempted.
  private final class Document {
    let utf16: [UInt16]
    private(set) var requestedRanges: [(location: Int, length: Int)] = []

    init(_ text: String) { utf16 = Array(text.utf16) }

    func read(_ location: Int, _ length: Int) -> String? {
      requestedRanges.append((location, length))
      guard location >= 0, length >= 0, location + length <= utf16.count else { return nil }
      return String(decoding: utf16[location..<(location + length)], as: UTF16.self)
    }
  }

  private func assemble(
    _ document: Document,
    selection: Int,
    length: Int = 0,
    window: Int = 20,
    characterCount: Int? = nil
  ) -> PasteService.CaretContext? {
    PasteService.assembleCaretContext(
      characterCount: characterCount ?? document.utf16.count,
      selectionLocation: selection,
      selectionLength: length,
      window: window,
      readRange: document.read)
  }

  // MARK: - Ordinary geometry

  @Test("a plain caret mid-field returns the text either side")
  func plainCaretMidField() throws {
    let document = Document("I went to the store today")
    let context = try #require(assemble(document, selection: 14))
    #expect(context.leftWindow == "I went to the ")
    #expect(context.rightWindow == "store today")
    #expect(context.selectionLocation == 14)
    #expect(context.selectionLength == 0)
  }

  @Test("a non-empty selection is excluded from BOTH windows")
  func selectionExcludedFromWindows() throws {
    // "I went to the [store] today" — a replacement is about to consume the
    // selection, so neither window may contain it.
    let document = Document("I went to the store today")
    let context = try #require(assemble(document, selection: 14, length: 5))
    #expect(context.leftWindow == "I went to the ")
    #expect(context.rightWindow == " today")
    #expect(context.leftWindow.contains("store") == false)
    #expect(context.rightWindow.contains("store") == false)
    #expect(context.selectionLength == 5)
  }

  @Test("a selection at field start yields an empty left window")
  func selectionAtFieldStart() throws {
    let document = Document("hello world")
    let context = try #require(assemble(document, selection: 0, length: 5))
    #expect(context.leftWindow == "")
    #expect(context.rightWindow == " world")
  }

  @Test("a caret at field end yields an empty right window")
  func caretAtFieldEnd() throws {
    let document = Document("hello world")
    let context = try #require(assemble(document, selection: 11))
    #expect(context.leftWindow == "hello world")
    #expect(context.rightWindow == "")
  }

  @Test("a full-field selection yields two empty windows")
  func fullFieldSelection() throws {
    let document = Document("hello world")
    let context = try #require(assemble(document, selection: 0, length: 11))
    #expect(context.leftWindow == "")
    #expect(context.rightWindow == "")
  }

  // MARK: - Clamping

  @Test("the left window clamps at field start rather than reading negative")
  func leftClampsAtStart() throws {
    let document = Document("hello world")
    let context = try #require(assemble(document, selection: 3, window: 20))
    #expect(context.leftWindow == "hel")
    for range in document.requestedRanges {
      #expect(range.location >= 0, "no negative location may reach the reader")
    }
  }

  @Test("the right window clamps at field end rather than reading past it")
  func rightClampsAtEnd() throws {
    let document = Document("hello world")
    let context = try #require(assemble(document, selection: 8, window: 20))
    #expect(context.rightWindow == "rld")
    for range in document.requestedRanges {
      #expect(
        range.location + range.length <= document.utf16.count,
        "no range may extend past the field")
    }
  }

  @Test("a window larger than the whole document succeeds with what exists")
  func windowLargerThanDocument() throws {
    let document = Document("hi")
    let context = try #require(assemble(document, selection: 1, window: 5000))
    #expect(context.leftWindow == "h")
    #expect(context.rightWindow == "i")
  }

  @Test("an empty document yields two empty windows")
  func emptyDocument() throws {
    let document = Document("")
    let context = try #require(assemble(document, selection: 0))
    #expect(context.leftWindow == "")
    #expect(context.rightWindow == "")
    #expect(document.requestedRanges.isEmpty, "an empty document needs no reads at all")
  }

  // MARK: - Refusals

  @Test("a zero or negative window is refused", arguments: [0, -1, -20])
  func nonPositiveWindowRefused(_ window: Int) {
    let document = Document("hello world")
    #expect(assemble(document, selection: 3, window: window) == nil)
  }

  @Test("a negative character count is refused")
  func negativeCharacterCountRefused() {
    let document = Document("hello")
    #expect(assemble(document, selection: 0, characterCount: -1) == nil)
  }

  @Test("a negative selection location is refused")
  func negativeSelectionLocationRefused() {
    let document = Document("hello")
    #expect(assemble(document, selection: -1) == nil)
  }

  @Test("a negative selection length is refused")
  func negativeSelectionLengthRefused() {
    let document = Document("hello")
    #expect(assemble(document, selection: 0, length: -3) == nil)
  }

  @Test("a selection starting beyond the field is refused")
  func selectionBeyondFieldRefused() {
    let document = Document("hello")
    #expect(assemble(document, selection: 6) == nil)
  }

  @Test("a selection longer than the remaining field is refused")
  func selectionLongerThanRemainderRefused() {
    let document = Document("hello")
    #expect(assemble(document, selection: 3, length: 5) == nil)
  }

  @Test("extreme integers cannot overflow the range arithmetic")
  func extremeIntegersRefused() {
    let document = Document("hello")
    // `location + length <= count` would WRAP here and wrongly pass. The
    // subtraction form refuses.
    #expect(assemble(document, selection: 3, length: Int.max) == nil)
    #expect(assemble(document, selection: Int.max, length: 1) == nil)
    #expect(
      PasteService.assembleCaretContext(
        characterCount: Int.max, selectionLocation: Int.max, selectionLength: Int.max,
        window: Int.max, readRange: { _, _ in nil }) == nil)
  }

  // MARK: - The reader is not called for an empty range

  @Test("an empty left range performs no read")
  func emptyLeftRangeSkipsRead() throws {
    let document = Document("hello world")
    _ = try #require(assemble(document, selection: 0))
    #expect(
      document.requestedRanges.contains(where: { $0.location == 0 && $0.length == 0 }) == false,
      "a zero-length span is derived as empty, never asked for")
  }

  @Test("an empty right range performs no read")
  func emptyRightRangeSkipsRead() throws {
    let document = Document("hello world")
    _ = try #require(assemble(document, selection: 11))
    #expect(
      document.requestedRanges.contains(where: { $0.length == 0 }) == false,
      "a zero-length span is derived as empty, never asked for")
  }

  @Test("a required non-empty read returning nil fails the whole context open")
  func failedReadFailsOpen() {
    // A partially-read context would produce a confident repair from half the
    // evidence, so the whole read is abandoned instead.
    #expect(
      PasteService.assembleCaretContext(
        characterCount: 20, selectionLocation: 10, selectionLength: 0, window: 5,
        readRange: { _, _ in nil }) == nil)
  }

  @Test("a left read returning the wrong UTF-16 length fails open", arguments: ["x", "abc"])
  func malformedLeftReadLengthFailsOpen(_ malformed: String) {
    // Asked for 2 units, handed back 1 or 3. The field changed under us, so the
    // text no longer matches the geometry — refuse rather than repair against it.
    #expect(
      PasteService.assembleCaretContext(
        characterCount: 2, selectionLocation: 2, selectionLength: 0, window: 2,
        readRange: { _, _ in malformed }) == nil)
  }

  @Test("a right read returning the wrong UTF-16 length fails open", arguments: ["x", "abc"])
  func malformedRightReadLengthFailsOpen(_ malformed: String) {
    #expect(
      PasteService.assembleCaretContext(
        characterCount: 2, selectionLocation: 0, selectionLength: 0, window: 2,
        readRange: { _, _ in malformed }) == nil)
  }

  @Test("a correctly sized read is still accepted")
  func correctlySizedReadAccepted() throws {
    // The length check must not reject valid reads.
    let context = try #require(
      PasteService.assembleCaretContext(
        characterCount: 2, selectionLocation: 1, selectionLength: 0, window: 1,
        readRange: { _, length in String(repeating: "a", count: length) }))
    #expect(context.leftWindow == "a")
    #expect(context.rightWindow == "a")
  }

  // MARK: - Whitespace exhaustion

  @Test("a whitespace-only window bounded away from field start is refused")
  func whitespaceExhaustionRefused() {
    // The nearest real character lies OUTSIDE the window, so we cannot tell a
    // continuation from a line start. Guessing would produce a wrong capital.
    let document = Document("some earlier text" + String(repeating: " ", count: 30) + "rest")
    #expect(assemble(document, selection: 47, window: 20) == nil)
  }

  @Test("a whitespace-only window that reaches field start is valid")
  func whitespaceReachingFieldStartIsValid() throws {
    // Offset zero is a positively known boundary, not an unknown one.
    let document = Document("     hello")
    let context = try #require(assemble(document, selection: 5, window: 20))
    #expect(context.leftWindow == "     ")
  }

  @Test("a newline inside the bounded window establishes a known boundary")
  func newlineInWindowIsValid() throws {
    let document = Document("first line.\n" + String(repeating: " ", count: 3) + "rest")
    let context = try #require(assemble(document, selection: 15, window: 20))
    #expect(context.leftWindow.contains("\n"))
  }

  // MARK: - UTF-16 geometry

  @Test("emoji offsets are UTF-16, never Character counts")
  func utf16GeometryWithEmoji() throws {
    // "🚀" is TWO UTF-16 units but one Character. Range arithmetic done in
    // Characters would land mid-surrogate and read the wrong text.
    let document = Document("a🚀b")
    #expect(document.utf16.count == 4)
    let context = try #require(assemble(document, selection: 3))
    #expect(context.leftWindow == "a🚀")
    #expect(context.rightWindow == "b")
  }

  @Test("the returned context preserves the exact selected location and length")
  func preservesExactSelection() throws {
    let document = Document("I went to the store today")
    let context = try #require(assemble(document, selection: 14, length: 5))
    #expect(context.selectionLocation == 14)
    #expect(context.selectionLength == 5)
  }

  // MARK: - Revalidating against the whole-field image (Codex review r2)

  /// The Tier 1 write holds the complete field microseconds before it writes, so
  /// it revalidates the candidate's evidence against that image rather than
  /// re-reading. Offsets alone are NOT the evidence: an editor or autoformatter
  /// can rewrite nearby characters without moving the selection at all.
  @Test("identical surroundings at the same offsets still match")
  func windowsMatchWhenNothingChanged() {
    let context = PasteService.CaretContext(
      leftWindow: "I went to the ", rightWindow: "", selectionLocation: 14, selectionLength: 0)
    #expect(
      PasteService.contextWindowsStillMatch(context, inFieldBefore: "I went to the "))
  }

  @Test("a rewritten neighbour at the same offsets does NOT match")
  func windowsRejectStalePunctuation() {
    // The reviewer's case: `, ` became `. `, every offset identical, but the
    // repair's whole decision — lowercase or keep the capital — inverts.
    let context = PasteService.CaretContext(
      leftWindow: "I went home, ", rightWindow: "", selectionLocation: 13, selectionLength: 0)
    #expect(
      PasteService.contextWindowsStillMatch(context, inFieldBefore: "I went home. ") == false)
  }

  @Test("text after the selection is compared too")
  func windowsCompareTheRightSide() {
    let context = PasteService.CaretContext(
      leftWindow: "the ", rightWindow: "yesterday", selectionLocation: 4, selectionLength: 0)
    #expect(PasteService.contextWindowsStillMatch(context, inFieldBefore: "the yesterday"))
    #expect(
      PasteService.contextWindowsStillMatch(context, inFieldBefore: "the tomorrow ") == false)
  }

  @Test("a field that shrank below the recorded selection fails closed")
  func windowsFailClosedOnAShrunkField() {
    let context = PasteService.CaretContext(
      leftWindow: "I went to the ", rightWindow: "", selectionLocation: 14, selectionLength: 0)
    #expect(PasteService.contextWindowsStillMatch(context, inFieldBefore: "I went") == false)
  }

  @Test("UTF-16 slicing survives an emoji straddling the window edge")
  func windowSlicingIsUTF16() {
    // "🚀" is two UTF-16 units and one Character; slicing in Characters would
    // land mid-surrogate and compare the wrong text.
    let context = PasteService.CaretContext(
      leftWindow: "a🚀", rightWindow: "b", selectionLocation: 3, selectionLength: 0)
    #expect(PasteService.contextWindowsStillMatch(context, inFieldBefore: "a🚀b"))
  }

  @Test("an out-of-range slice returns nil rather than trapping")
  func sliceRefusesImpossibleRanges() {
    #expect(PasteService.utf16Slice(of: "abc", from: 0, to: 3) == "abc")
    #expect(PasteService.utf16Slice(of: "abc", from: 2, to: 1) == nil)
    #expect(PasteService.utf16Slice(of: "abc", from: 0, to: 9) == nil)
    #expect(PasteService.utf16Slice(of: "abc", from: -1, to: 2) == nil)
  }
}
