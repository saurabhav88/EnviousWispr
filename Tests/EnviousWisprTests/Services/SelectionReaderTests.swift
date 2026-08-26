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
      SelectionReader.refusalBeforeReading(
        isTrusted: false, frontmost: .init(pid: 501, isOurs: false), ownPID: 999)
        == .accessibilityNotTrusted)
  }

  @Test("Trust is checked before the frontmost app, because it is the one the user can fix")
  func untrustedOutranksAMissingFrontmostApp() {
    // Both wrong at once. Reporting "no frontmost application" to someone who simply has not
    // granted permission sends them looking at the wrong thing.
    #expect(
      SelectionReader.refusalBeforeReading(
        isTrusted: false, frontmost: .init(pid: nil, isOurs: false), ownPID: 999)
        == .accessibilityNotTrusted)
  }

  @Test("No frontmost application is its own reason")
  func noFrontmostApplicationIsNamed() {
    #expect(
      SelectionReader.refusalBeforeReading(
        isTrusted: true, frontmost: .init(pid: nil, isOurs: false), ownPID: 999)
        == .noFrontmostApplication)
  }

  @Test("A non-positive pid is refused rather than passed to Accessibility")
  func aNonPositivePIDIsRefused() {
    for pid: pid_t in [0, -1] {
      #expect(
        SelectionReader.refusalBeforeReading(
          isTrusted: true, frontmost: .init(pid: pid, isOurs: false), ownPID: 999)
          == .noFrontmostApplication,
        "pid \(pid) must not reach Accessibility")
    }
  }

  /// **The shortcut is GLOBAL and our own Settings window has text fields (#2413).** Pressed while
  /// editing a custom word, the frontmost application is US, and without this the reader hands back
  /// the half-typed edit as a word to add.
  ///
  /// **No ordering discipline can replace this guard.** Both this file and `QuickAddCoordinator`
  /// carry comments saying to read BEFORE activating ourselves — correct, and what makes the
  /// ordinary case work. It cannot help when the user is already inside our app when they press the
  /// shortcut: there is no "before" in which another application is frontmost.
  @Test("Our own application is refused rather than read")
  func ourOwnApplicationIsRefused() {
    #expect(
      SelectionReader.refusalBeforeReading(
        isTrusted: true, frontmost: .init(pid: 4242, isOurs: false), ownPID: 4242)
        == .ownApplication)
  }

  /// **A SECOND EnviousWispr passes a pid check, and that is the ordinary state of this machine** —
  /// an installed build beside a dev build. Different pid, our text, straight through.
  ///
  /// **Driven by the REAL identifiers, not by an injected verdict.** The first version of this row
  /// handed the guard a hardcoded `true` for the ownership question, which asserts that the guard
  /// ACTS on the answer and says nothing about how the answer is COMPUTED — and the computation was
  /// wrong in exactly this case, because a dev build's `Bundle.main.bundleIdentifier` does not equal
  /// a release build's. A fixture that hands over the conclusion cannot observe the step that
  /// produces it, so the row runs `AppBundleIdentity.isOurs` over the real pair instead.
  @Test(
    "Another EnviousWispr is refused too, whichever build is asking",
    arguments: [
      (AppBundleIdentity.production, AppBundleIdentity.development),
      (AppBundleIdentity.development, AppBundleIdentity.production),
      (AppBundleIdentity.production, AppBundleIdentity.production),
    ])
  func aSecondInstanceIsAlsoRefused(frontmost: String, own: String) {
    #expect(
      SelectionReader.refusalBeforeReading(
        isTrusted: true,
        frontmost: .init(pid: 7777, isOurs: AppBundleIdentity.isOurs(frontmost)),
        ownPID: 4242)
        == .ownApplication,
      "a \(own) build must refuse a frontmost \(frontmost) build; a pid-only guard reads its text")
  }

  /// The family is CLOSED, and a row per member so adding one without deciding is visible.
  @Test("Only our own identifiers are the app; everything else is somebody's document")
  func theIdentityFamilyIsExactlyOurTwoBuilds() {
    #expect(AppBundleIdentity.isOurs(AppBundleIdentity.production))
    #expect(AppBundleIdentity.isOurs(AppBundleIdentity.development))
    #expect(AppBundleIdentity.all.count == 2)
    // Paired rejections, or a predicate that says yes to everything looks identical to this one.
    #expect(!AppBundleIdentity.isOurs(nil))
    #expect(!AppBundleIdentity.isOurs(""))
    #expect(!AppBundleIdentity.isOurs("com.apple.TextEdit"))
    // Our OWN neighbours, which are the near misses a prefix check would swallow.
    #expect(!AppBundleIdentity.isOurs("com.enviouswispr.asrservice"))
    #expect(!AppBundleIdentity.isOurs("com.enviouswispr.app.dev.extra"))
    #expect(!AppBundleIdentity.isOurs("com.enviouswispr"))
  }

  /// The pair, without which the row above passes for a guard that refuses everything.
  @Test("Another application at the same trust level still goes ahead")
  func anotherApplicationIsStillRead() {
    #expect(
      SelectionReader.refusalBeforeReading(
        isTrusted: true, frontmost: .init(pid: 4243, isOurs: false), ownPID: 4242) == nil)
  }

  /// **Trust outranks it, for the same reason it outranks a missing frontmost app.** Someone who
  /// has not granted permission must be told THAT, not that their selection was ours.
  @Test("Untrusted outranks reading our own app")
  func untrustedOutranksOurOwnSelection() {
    #expect(
      SelectionReader.refusalBeforeReading(
        isTrusted: false, frontmost: .init(pid: 4242, isOurs: true), ownPID: 4242)
        == .accessibilityNotTrusted)
  }

  @Test("Trusted with a live application goes ahead")
  func trustedAndFrontmostProceeds() {
    #expect(
      SelectionReader.refusalBeforeReading(
        isTrusted: true, frontmost: .init(pid: 501, isOurs: false), ownPID: 999) == nil)
  }

  // MARK: - What Accessibility answered

  @Test("A selection comes back as text")
  func aSelectionIsReturned() {
    #expect(
      SelectionReader.resolve(error: .success, value: "codecs" as CFString) == .text("codecs"))
  }

  @Test("A selection is trimmed, because a drag routinely picks up the surrounding space")
  func aSelectionIsTrimmed() {
    #expect(
      SelectionReader.resolve(error: .success, value: "  codecs \n" as CFString) == .text("codecs"))
  }

  @Test("Whitespace only is nothing selected, not a selection of spaces")
  func whitespaceOnlyIsNoSelection() {
    for value in ["", " ", "\n", "\t  \n"] {
      #expect(SelectionReader.resolve(error: .success, value: value as CFString) == .noSelection)
    }
  }

  @Test("A lot of whitespace is still nothing selected, not a selection that is too long")
  func longWhitespaceIsNoSelectionNotTooLong() {
    // Measuring before trimming reported this as `selectionTooLong`, which tells the user their
    // selection was too big when they had not selected anything at all.
    let padding = String(repeating: " ", count: SelectionReader.maximumSelectionScalars * 2)

    #expect(SelectionReader.resolve(error: .success, value: padding as CFString) == .noSelection)
  }

  @Test("A short word dragged with a lot of surrounding space is accepted, not refused for length")
  func aPaddedShortSelectionIsAccepted() {
    // The ceiling bounds what gets STORED, and what gets stored is the trimmed string. Measuring
    // the untrimmed one refuses a word that would have fitted easily.
    let padding = String(repeating: " ", count: SelectionReader.maximumSelectionScalars)
    let padded = padding + "codecs" + padding

    #expect(padded.unicodeScalars.count > SelectionReader.maximumSelectionScalars)
    #expect(SelectionReader.resolve(error: .success, value: padded as CFString) == .text("codecs"))
  }

  @Test("A successful read with no value at all is nothing selected")
  func successWithNoStringIsNoSelection() {
    // The attribute answered; it just had nothing in it. Distinct from `noValue`, which did not.
    #expect(SelectionReader.resolve(error: .success, value: nil) == .noSelection)
  }

  @Test("An attribute that answers with something other than text is unreadable, not empty")
  func aNonStringAnswerIsUnreadable() {
    // `as? String` alone would turn every one of these into nil, and nil reads as "nothing
    // selected" — a broken element reported to the user as an empty selection.
    let notStrings: [CFTypeRef] = [
      NSNumber(value: 42), kCFBooleanTrue, [1, 2, 3] as CFArray, Data() as CFData,
    ]
    for value in notStrings {
      #expect(
        SelectionReader.resolve(error: .success, value: value) == .refused(.unreadable),
        "a \(CFCopyTypeIDDescription(CFGetTypeID(value)) as String? ?? "?") answer must not read as an empty selection"
      )
    }

    // The paired ACCEPTED case, in the same test rather than a duplicate of `aSelectionIsReturned`:
    // a type check that refused everything would satisfy the loop above and look clean.
    #expect(
      SelectionReader.resolve(error: .success, value: "codecs" as CFString) == .text("codecs"),
      "the type check must not be refusing every answer")
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
      SelectionReader.resolve(error: .cannotComplete, value: "codecs" as CFString)
        == .refused(.unreadable))
  }

  // MARK: - Too long to be a word

  @Test("A selection longer than the store will accept is refused, not truncated")
  func anOverlongSelectionIsRefused() {
    // Truncating would silently save a different word than the user selected. Refusing says so.
    let tooLong = String(repeating: "a", count: SelectionReader.maximumSelectionScalars + 1)

    #expect(
      SelectionReader.resolve(error: .success, value: tooLong as CFString)
        == .refused(.selectionTooLong))
  }

  @Test("A selection exactly at the store's ceiling is accepted")
  func aSelectionAtTheCeilingIsAccepted() {
    let atLimit = String(repeating: "a", count: SelectionReader.maximumSelectionScalars)

    #expect(SelectionReader.resolve(error: .success, value: atLimit as CFString) == .text(atLimit))
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
    #expect(
      SelectionReader.resolve(error: .success, value: underCeiling as CFString)
        == .text(underCeiling))

    let overCeiling = underCeiling + family
    #expect(overCeiling.unicodeScalars.count > SelectionReader.maximumSelectionScalars)
    #expect(
      SelectionReader.resolve(error: .success, value: overCeiling as CFString)
        == .refused(.selectionTooLong),
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
  // MARK: - One owner for what a selection IS (#2381 review r1)

  @Test("Whitespace-only text is nothing selected, whichever door handed it over")
  func classifyTreatsWhitespaceAsNoSelection() {
    // Door B reached the coordinator with raw pasteboard text and none of this applied, so a
    // whitespace-only Service selection opened a panel on an empty string with no stated reason.
    #expect(SelectionReader.classify("   ") == .noSelection)
    #expect(SelectionReader.classify("\n\t ") == .noSelection)
    #expect(SelectionReader.classify("") == .noSelection)
  }

  @Test("The store's ceiling applies to handed text too, and it is measured after trimming")
  func classifyAppliesTheCeiling() {
    let atCeiling = String(repeating: "a", count: SelectionReader.maximumSelectionScalars)
    let overCeiling = atCeiling + "a"

    #expect(SelectionReader.classify(atCeiling) == .text(atCeiling))
    #expect(SelectionReader.classify(overCeiling) == .refused(.selectionTooLong))
    // Padded but short: trimming first is what stops surrounding space refusing a real word.
    #expect(SelectionReader.classify("   codecs   ") == .text("codecs"))
  }

  @Test("No reader outcome is a coordinator-owned refusal — those members have other producers")
  func noReadOutcomeIsCoordinatorOwned() {
    // `Refusal` is the panel's one reason line AND the telemetry refuse_reason, so it holds cases
    // the reader cannot produce. Asserting the boundary is what keeps that from decaying into "the
    // reader might return anything in here".
    //
    // TWO members now, and the second is why this asserts a SET rather than a name. `nothingSelected`
    // is minted by the coordinator from `.noSelection`, exactly as `wordsUnavailable` is minted from
    // a failed refresh — and it exists because mapping `.noSelection` onto `selectionUnavailable`
    // handed the commonest refusal a sentence blaming the frontmost app for withholding a selection.
    let coordinatorOwned: [SelectionReader.Refusal] = [.wordsUnavailable, .nothingSelected]
    var seen: [SelectionReader.Result] = [
      SelectionReader.classify(""),
      SelectionReader.classify("codecs"),
      SelectionReader.classify(String(repeating: "a", count: 9999)),
      SelectionReader.resolve(error: .attributeUnsupported, value: nil),
      SelectionReader.resolve(error: .noValue, value: nil),
      SelectionReader.resolve(error: .cannotComplete, value: nil),
      SelectionReader.resolve(error: .success, value: nil),
      SelectionReader.resolve(error: .success, value: NSNumber(value: 7)),
      SelectionReader.resolve(error: .success, value: "codecs" as CFString),
    ]
    for refusal in [
      SelectionReader.refusalBeforeReading(
        isTrusted: false, frontmost: .init(pid: 1, isOurs: false), ownPID: 999),
      SelectionReader.refusalBeforeReading(
        isTrusted: true, frontmost: .init(pid: nil, isOurs: false), ownPID: 999),
      SelectionReader.refusalBeforeReading(
        isTrusted: true, frontmost: .init(pid: 0, isOurs: false), ownPID: 999),
    ] {
      if let refusal { seen.append(.refused(refusal)) }
    }

    for owned in coordinatorOwned {
      #expect(!seen.contains(.refused(owned)), "the reader minted \(owned), which it does not own")
    }
    // Paired positive: a sweep that produced no refusals at all would pass every line above.
    #expect(seen.contains { if case .refused = $0 { true } else { false } })
  }


  /// **A failed query is not an empty one, and they need different sentences.**
  ///
  /// `focusedElementQuery` collapsed both to nil, which was tolerable while every read was
  /// unbounded and a timeout was rare. #2412's 0.25s menu cap makes the timeout branch the likely
  /// one, so the panel was routinely telling users to click into the text when nothing they clicked
  /// could help. Cloud review, PR #2427.
  @Test("A timed-out or failed focus query is unreadable, not an unfocused app")
  func aFailedFocusQueryIsNotAnEmptyOne() {
    #expect(SelectionReader.refusalForFocusedElement(.none) == .noFocusedElement)
    #expect(SelectionReader.refusalForFocusedElement(.queryFailed(.cannotComplete)) == .unreadable)
    // The timeout arrives as its own error code and must not be special-cased into the empty case.
    #expect(
      SelectionReader.refusalForFocusedElement(.queryFailed(.actionUnsupported)) == .unreadable,
      "every query failure is unreadable; only a SUCCESSFUL empty query is noFocusedElement")
    // The two must stay DISTINCT refusals; the wording each maps to is the copy table's suite,
    // in another module. What matters here is that nothing collapses them back together.
    #expect(
      SelectionReader.refusalForFocusedElement(.none)
        != SelectionReader.refusalForFocusedElement(.queryFailed(.cannotComplete)))
  }
}
