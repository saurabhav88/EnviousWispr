import EnviousWisprServices
import Foundation
import Testing

/// The paste landing verdict table (#3106 step 1, plan §3.2), row by row and at its borders.
///
/// When one of these fails, step 2 would read the wrong row: it would tell a user their paste
/// changed nothing when it did (and they paste twice), or stay silent on a paste that went nowhere.
/// Every expectation is written out literally from the plan's table, never computed.
@Suite("Paste landing check: the verdict table (#3106)", .tags(.productOutcome))
struct PasteLandingClassifyTests {

  private static let payload = "send the draft to Maya"
  private static let caret = PasteLandingFacts.Selection.text("")

  /// A readable field holding `text`, caret only.
  private static func field(
    _ text: String = "Hello", selection: PasteLandingFacts.Selection = caret
  )
    -> PasteLandingFacts.Before
  { .field(text: text, selection: selection) }

  private static func verdict(
    targetTerminated: Bool = false,
    frontmostChanged: Bool = false,
    prepareBudgetExhausted: Bool = false,
    before: PasteLandingFacts.Before = field(),
    observerComplete: Bool = true,
    notifications: Set<PastedRegionAXNotification> = [],
    after: PasteLandingFacts.After = .sameElement(text: "Hello"),
    payload: String = payload
  ) -> PasteLandingObserved {
    PasteLandingCheck.classify(
      PasteLandingFacts(
        targetTerminated: targetTerminated, frontmostChanged: frontmostChanged,
        prepareBudgetExhausted: prepareBudgetExhausted, before: before,
        observerComplete: observerComplete, notifications: notifications, after: after,
        payload: payload))
  }

  // MARK: Rows, in the table's order

  @Test("Row 1: the target quit, even with another app frontmost and the text changed")
  func row1AppTerminated() {
    #expect(
      Self.verdict(
        targetTerminated: true, frontmostChanged: true, after: .sameElement(text: "Hello there"))
        == .unknown(.appTerminated))
  }

  @Test("Row 2: another process came to the front")
  func row2AppSwitched() {
    #expect(
      Self.verdict(frontmostChanged: true, after: .sameElement(text: "Hello there"))
        == .unknown(.appSwitched))
  }

  @Test("Row 3a: the preparation budget ran out, even before an unreadable before-image")
  func row3aPrepareBudget() {
    #expect(
      Self.verdict(prepareBudgetExhausted: true, before: .unreadable) == .unknown(.prepareBudget))
  }

  @Test("Row 3: an unreadable before-image can claim neither changed nor unchanged")
  func row3BeforeUnreadable() {
    #expect(
      Self.verdict(before: .unreadable, notifications: [.valueChanged])
        == .unknown(.beforeUnreadable))
    #expect(
      Self.verdict(before: .unreadable, after: .sameElement(text: "Hello"))
        == .unknown(.beforeUnreadable))
    #expect(Self.verdict(before: .unreadable, after: .noFocus) == .unknown(.beforeUnreadable))
  }

  @Test("Row 4: a partial registration, even when the text visibly differs")
  func row4NoObserver() {
    #expect(
      Self.verdict(observerComplete: false, after: .sameElement(text: "Hello there"))
        == .unknown(.noObserver))
  }

  @Test("Row 5: same element, readable, different")
  func row5TextDiffers() {
    #expect(Self.verdict(after: .sameElement(text: "Hello there")) == .changed(.textDiffers))
  }

  @Test("Row 6: a value notification with an identical final text")
  func row6NotifiedValue() {
    #expect(
      Self.verdict(notifications: [.valueChanged], after: .sameElement(text: "Hello"))
        == .changed(.notifiedValue))
  }

  @Test("Row 7b: a focus notification cannot claim changed")
  func row7bNotifiedFocus() {
    #expect(
      Self.verdict(notifications: [.focusedElementChanged], after: .otherElement)
        == .unknown(.notifiedFocus))
  }

  @Test("Row 7c: a destroyed element cannot claim changed")
  func row7cElementDestroyed() {
    #expect(
      Self.verdict(notifications: [.elementDestroyed], after: .queryFailed)
        == .unknown(.elementDestroyed))
  }

  @Test("Row 7: selection unavailable on an otherwise identical field")
  func row7SelectionUnavailable() {
    #expect(
      Self.verdict(before: Self.field(selection: .unavailable), after: .sameElement(text: "Hello"))
        == .unknown(.selectionUnavailable))
  }

  @Test("Row 7a: the selection already held the payload, field identical")
  func row7aIdenticalSelection() {
    #expect(
      Self.verdict(
        before: Self.field(Self.payload, selection: .text(Self.payload)),
        after: .sameElement(text: Self.payload))
        == .unknown(.identicalSelection))
  }

  @Test("Row 8: same element, readable, byte-identical")
  func row8FieldIdentical() {
    #expect(Self.verdict(after: .sameElement(text: "Hello")) == .unchanged(.fieldIdentical))
    #expect(
      Self.verdict(
        before: Self.field("Hello", selection: .text("ell")), after: .sameElement(text: "Hello"))
        == .unchanged(.fieldIdentical), "a selection that is not the payload does not guard")
    #expect(
      Self.verdict(before: Self.field(""), after: .sameElement(text: ""))
        == .unchanged(.fieldIdentical),
      "an empty field that stayed empty")
  }

  @Test("Row 9: nothing focused before, nothing at the end, no focus notification")
  func row9NoFocus() {
    #expect(Self.verdict(before: .noFocus, after: .noFocus) == .unchanged(.noFocus))
  }

  @Test("Row 11: final text unreadable, focus moved, or the query failed")
  func row11AfterUnreadable() {
    #expect(Self.verdict(after: .sameElement(text: nil)) == .unknown(.afterUnreadable))
    #expect(Self.verdict(after: .otherElement) == .unknown(.afterUnreadable))
    #expect(Self.verdict(after: .queryFailed) == .unknown(.afterUnreadable))
    #expect(Self.verdict(after: .noFocus) == .unknown(.afterUnreadable), "field before, none after")
    #expect(
      Self.verdict(before: .noFocus, after: .queryFailed) == .unknown(.afterUnreadable),
      "a failed question is not the answer nothing")
    #expect(Self.verdict(before: .noFocus, after: .otherElement) == .unknown(.afterUnreadable))
  }

  // MARK: Neighbours and precedence (plan §11)

  @Test("Identical selection plus a value notification: the notification wins (row 6)")
  func valueNotificationOutranksIdenticalSelection() {
    #expect(
      Self.verdict(
        before: Self.field(Self.payload, selection: .text(Self.payload)),
        notifications: [.valueChanged], after: .sameElement(text: Self.payload))
        == .changed(.notifiedValue))
  }

  @Test("Unavailable selection plus a different final text: the difference wins (row 5)")
  func textDifferenceOutranksUnavailableSelection() {
    #expect(
      Self.verdict(
        before: Self.field(selection: .unavailable), after: .sameElement(text: "Hello there"))
        == .changed(.textDiffers))
  }

  @Test("No element before plus a focus notification: row 7b, not row 9")
  func noFocusWithFocusNotification() {
    #expect(
      Self.verdict(before: .noFocus, notifications: [.focusedElementChanged], after: .noFocus)
        == .unknown(.notifiedFocus))
  }

  @Test("A readable text difference outranks a focus notification (row 5 before 7b)")
  func textDifferenceOutranksFocusNotification() {
    #expect(
      Self.verdict(
        notifications: [.focusedElementChanged], after: .sameElement(text: "Hello there"))
        == .changed(.textDiffers))
  }

  @Test("A late change caught only by the final read flips to text_differs")
  func lateChangeCaughtByFinalRead() {
    #expect(
      Self.verdict(notifications: [], after: .sameElement(text: "Hello!")) == .changed(.textDiffers)
    )
  }

  @Test("Canonically equivalent but different UTF-16 is a change, not identical")
  func canonicalEquivalenceIsNotIdentity() {
    let precomposed = "caf\u{00E9}"  // é as one code unit
    let decomposed = "cafe\u{0301}"  // e plus a combining acute: equal as Swift Strings
    #expect(precomposed == decomposed, "the premise: Swift String equality would call these equal")
    #expect(
      Self.verdict(before: Self.field(precomposed), after: .sameElement(text: decomposed))
        == .changed(.textDiffers))
    #expect(
      Self.verdict(
        before: Self.field(precomposed, selection: .text(decomposed)),
        after: .sameElement(text: precomposed), payload: precomposed)
        == .unchanged(.fieldIdentical), "a selection equal only canonically does not guard")
  }

  // MARK: The vocabulary

  @Test("The reason strings are exactly the plan's, and each verdict names its kind")
  func vocabulary() {
    #expect(
      Set(PasteLandingObserved.Reason.allCases.map(\.rawValue)) == [
        "app_terminated", "app_switched", "prepare_budget", "before_unreadable", "no_observer",
        "text_differs", "notified_value", "notified_focus", "element_destroyed",
        "selection_unavailable", "identical_selection", "field_identical", "no_focus",
        "after_unreadable",
      ])
    #expect(PasteLandingObserved.changed(.textDiffers).observed == "changed")
    #expect(PasteLandingObserved.unchanged(.noFocus).observed == "unchanged")
    #expect(PasteLandingObserved.unknown(.noObserver).observed == "unknown")
    #expect(PasteLandingObserved.unknown(.noObserver).reason == .noObserver)
  }
}
