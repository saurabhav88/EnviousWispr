import ApplicationServices
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// #2381 — how one Accessibility answer becomes what the user is told.
///
/// When this fails the user presses the shortcut and the panel says the wrong thing: it claims a
/// selection that is not there, silently does nothing where it should name a reason, or offers a
/// string the word library will refuse to store. The panel opening on a stated reason instead of a
/// silent no-op is the whole failure contract of this feature.
///
/// **No `AXUIElement` is fabricated anywhere here**, deliberately. `PasteService` keeps live AX
/// round trips out of unit tests and asserts on pure decisions, and a hand-built element would test
/// our idea of Accessibility rather than Accessibility. The error values are the REAL ones —
/// `AXError` cases, not integers copied from a header — so a renamed case fails to compile rather
/// than passing against the wrong branch.
@Suite("SelectionReader — #2381 reading the user's selection", .tags(.productOutcome))
struct SelectionReaderTests {

  // MARK: - Before any read is attempted

  @Test("Without Accessibility the reason is the one the user can act on")
  func untrustedIsNamed() {
    #expect(
      SelectionReader.refusalBeforeReading(isTrusted: false, frontmostPID: 501)
        == .accessibilityNotTrusted)
  }

  @Test("Trust is checked before the frontmost app, because it is the one the user can fix")
  func untrustedOutranksAMissingFrontmostApp() {
    // Both wrong at once. Reporting "no frontmost application" to someone who simply has not
    // granted permission sends them looking at the wrong thing.
    #expect(
      SelectionReader.refusalBeforeReading(isTrusted: false, frontmostPID: nil)
        == .accessibilityNotTrusted)
  }

  @Test("No frontmost application is its own reason")
  func noFrontmostApplicationIsNamed() {
    #expect(
      SelectionReader.refusalBeforeReading(isTrusted: true, frontmostPID: nil)
        == .noFrontmostApplication)
  }

  @Test("A non-positive pid is refused rather than passed to Accessibility")
  func aNonPositivePIDIsRefused() {
    for pid: pid_t in [0, -1] {
      #expect(
        SelectionReader.refusalBeforeReading(isTrusted: true, frontmostPID: pid)
          == .noFrontmostApplication,
        "pid \(pid) must not reach Accessibility")
    }
  }

  @Test("Trusted with a live application goes ahead")
  func trustedAndFrontmostProceeds() {
    #expect(SelectionReader.refusalBeforeReading(isTrusted: true, frontmostPID: 501) == nil)
  }

  // MARK: - What Accessibility answered

  @Test("A selection comes back as text")
  func aSelectionIsReturned() {
    #expect(SelectionReader.resolve(error: .success, value: "codecs") == .text("codecs"))
  }

  @Test("A selection is trimmed, because a drag routinely picks up the surrounding space")
  func aSelectionIsTrimmed() {
    #expect(SelectionReader.resolve(error: .success, value: "  codecs \n") == .text("codecs"))
  }

  @Test("Whitespace only is nothing selected, not a selection of spaces")
  func whitespaceOnlyIsNoSelection() {
    for value in ["", " ", "\n", "\t  \n"] {
      #expect(SelectionReader.resolve(error: .success, value: value) == .noSelection)
    }
  }

  @Test("A successful read with no string is nothing selected")
  func successWithNoStringIsNoSelection() {
    // The attribute answered; it just had nothing in it. Distinct from `noValue`, which did not.
    #expect(SelectionReader.resolve(error: .success, value: nil) == .noSelection)
  }

  @Test("An element that does not expose selected text says so")
  func unsupportedIsNamed() {
    #expect(
      SelectionReader.resolve(error: .attributeUnsupported, value: nil)
        == .refused(.selectionUnsupported))
  }

  @Test("The terminal case is kept apart from the unsupported one")
  func noValueIsItsOwnRefusal() {
    // Measured in Ghostty with text visibly highlighted: the attribute IS advertised in the
    // element's attribute names and still answers `noValue` with a zero-length range. Collapsing
    // this into `selectionUnsupported` would hide a whole class of app that reports a selection it
    // will not hand over — which is why terminals are out of scope rather than merely unlucky.
    #expect(
      SelectionReader.resolve(error: .noValue, value: nil) == .refused(.selectionUnavailable))
  }

  @Test("Any other Accessibility error is unreadable rather than silently nothing")
  func otherErrorsAreUnreadable() {
    for error: AXError in [.invalidUIElement, .cannotComplete, .failure, .notImplemented] {
      #expect(
        SelectionReader.resolve(error: error, value: nil) == .refused(.unreadable),
        "\(error) must not read as an empty selection")
    }
  }

  @Test("An error wins over a value, so a stale string cannot be offered as a selection")
  func anErrorIsNotOverriddenByAValue() {
    #expect(
      SelectionReader.resolve(error: .cannotComplete, value: "codecs") == .refused(.unreadable))
  }

  // MARK: - Too long to be a word

  @Test("A selection longer than the store will accept is refused, not truncated")
  func anOverlongSelectionIsRefused() {
    // Truncating would silently save a different word than the user selected. Refusing says so.
    let tooLong = String(repeating: "a", count: SelectionReader.maximumSelectionScalars + 1)

    #expect(
      SelectionReader.resolve(error: .success, value: tooLong) == .refused(.selectionTooLong))
  }

  @Test("A selection exactly at the store's ceiling is accepted")
  func aSelectionAtTheCeilingIsAccepted() {
    let atLimit = String(repeating: "a", count: SelectionReader.maximumSelectionScalars)

    #expect(SelectionReader.resolve(error: .success, value: atLimit) == .text(atLimit))
  }

  @Test("The ceiling is the store's own, not a number invented here")
  func theCeilingIsTheStoresOwn() {
    // Pinning the SOURCE, not the value: a selection the reader accepts and the store refuses
    // would open a confident panel over a word that cannot be saved.
    #expect(
      SelectionReader.maximumSelectionScalars
        == CustomWordsImportLimits.maximumStoredValueScalars)
  }

  @Test("The ceiling counts scalars, which is neither characters nor bytes")
  func lengthIsMeasuredInScalars() {
    // One family emoji is a SINGLE Character, five scalars, and twenty-five UTF-8 bytes, so the
    // three counts disagree by a lot. Counting characters would let a selection through that the
    // store then refuses; counting bytes would refuse selections a user can legitimately save.
    let family = "👨‍👩‍👧"
    #expect(family.count == 1)
    #expect(family.unicodeScalars.count == 5)

    let underCeiling = String(repeating: family, count: SelectionReader.maximumSelectionScalars / 5)
    #expect(underCeiling.unicodeScalars.count <= SelectionReader.maximumSelectionScalars)
    #expect(SelectionReader.resolve(error: .success, value: underCeiling) == .text(underCeiling))

    let overCeiling = underCeiling + family
    #expect(overCeiling.unicodeScalars.count > SelectionReader.maximumSelectionScalars)
    #expect(
      SelectionReader.resolve(error: .success, value: overCeiling) == .refused(.selectionTooLong),
      "the ceiling counted characters rather than scalars")
  }

  // MARK: - The closed set

  @Test("Every refusal has a distinct telemetry name")
  func refusalNamesAreUnique() {
    // The raw values are BOTH the copy key and the telemetry `refuse_reason`. Two reasons sharing
    // a name makes a dashboard disagree with what the user was told, silently.
    let names = SelectionReader.Refusal.allCases.map(\.rawValue)

    #expect(Set(names).count == names.count)
    #expect(names.allSatisfy { !$0.isEmpty })
  }
}
