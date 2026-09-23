import Foundation

/// What a key paste was OBSERVED to do to the focused field (#3106, step 1: observation only).
///
/// **An observation of field state, never proof that the payload landed.** `changed` means the field
/// is not what it was; `unchanged` means it is byte-identical; `unknown` means we could not tell.
/// Nothing may act on it in step 1: no clipboard, overlay or destination write depends on it.
package enum PasteLandingObserved: Sendable, Equatable {
  case changed(Reason)
  case unchanged(Reason)
  case unknown(Reason)

  /// The closed reason vocabulary, one per row of the plan's verdict table (§3.2). The raw values
  /// are the log and telemetry strings.
  package enum Reason: String, Sendable, CaseIterable {
    case appTerminated = "app_terminated"
    case appSwitched = "app_switched"
    case prepareBudget = "prepare_budget"
    case beforeUnreadable = "before_unreadable"
    case noObserver = "no_observer"
    case textDiffers = "text_differs"
    case notifiedValue = "notified_value"
    case notifiedFocus = "notified_focus"
    case elementDestroyed = "element_destroyed"
    case selectionUnavailable = "selection_unavailable"
    case identicalSelection = "identical_selection"
    case fieldIdentical = "field_identical"
    case noFocus = "no_focus"
    case afterUnreadable = "after_unreadable"
  }

  /// `changed`, `unchanged` or `unknown`: the `observed` field of the log line and the event.
  package var observed: String {
    switch self {
    case .changed: "changed"
    case .unchanged: "unchanged"
    case .unknown: "unknown"
    }
  }

  package var reason: Reason {
    switch self {
    case .changed(let reason), .unchanged(let reason), .unknown(let reason): reason
    }
  }
}

/// Everything the verdict is decided from, gathered by the check's lifecycle. Immutable: the
/// classifier reads nothing live.
package struct PasteLandingFacts: Sendable, Equatable {

  /// The focused field immediately before our write.
  package enum Before: Sendable, Equatable {
    /// A readable field: its whole text, and what was selected in it.
    case field(text: String, selection: Selection)
    /// The application answered that nothing is focused.
    case noFocus
    /// The focus query failed, the field is secure, its text could not be read, or it is over the
    /// read limit. Distinct from `noFocus`: a failed question is not the answer "nothing".
    case unreadable
  }

  /// The selection in the before-image.
  package enum Selection: Sendable, Equatable {
    /// The selected text, possibly empty (a caret).
    case text(String)
    /// The host would not say what is selected.
    case unavailable
  }

  /// The focused field at resolution.
  package enum After: Sendable, Equatable {
    /// The same element as before is still focused. `text` is nil when it could not be read.
    case sameElement(text: String?)
    /// A different element is focused.
    case otherElement
    /// The application answered that nothing is focused.
    case noFocus
    /// The focus query failed.
    case queryFailed
  }

  package let targetTerminated: Bool
  /// The target is still running, and the frontmost process at resolution is not the one that was
  /// frontmost before the write.
  package let frontmostChanged: Bool
  /// The one cumulative preparation budget ran out at any depth.
  package let prepareBudgetExhausted: Bool
  package let before: Before
  /// Every notification the check required was registered.
  package let observerComplete: Bool
  /// Which notifications arrived during the watch.
  package let notifications: Set<PastedRegionAXNotification>
  package let after: After
  /// What we pasted, compared with the before-image's selection.
  package let payload: String

  package init(
    targetTerminated: Bool = false,
    frontmostChanged: Bool = false,
    prepareBudgetExhausted: Bool = false,
    before: Before,
    observerComplete: Bool = true,
    notifications: Set<PastedRegionAXNotification> = [],
    after: After,
    payload: String
  ) {
    self.targetTerminated = targetTerminated
    self.frontmostChanged = frontmostChanged
    self.prepareBudgetExhausted = prepareBudgetExhausted
    self.before = before
    self.observerComplete = observerComplete
    self.notifications = notifications
    self.after = after
    self.payload = payload
  }
}

package enum PasteLandingCheck {

  /// The verdict table, first match wins (plan §3.2). Rows are evaluated in the order listed there.
  ///
  /// Text is compared as UTF-16 code units, never with `String ==`: Swift equates canonically
  /// equivalent strings (a precomposed "é" and "e" plus a combining accent), which would call a
  /// field "identical" after a paste changed its bytes.
  package static func classify(_ facts: PasteLandingFacts) -> PasteLandingObserved {
    // Rows 1, 2, 3a: the observation itself is void.
    if facts.targetTerminated { return .unknown(.appTerminated) }
    if facts.frontmostChanged { return .unknown(.appSwitched) }
    if facts.prepareBudgetExhausted { return .unknown(.prepareBudget) }

    // Row 3: without a readable before-image nothing can be compared, so neither `changed` nor
    // `unchanged` may be claimed.
    let beforeText: String?
    let selection: PasteLandingFacts.Selection?
    switch facts.before {
    case .unreadable: return .unknown(.beforeUnreadable)
    case .field(let text, let sel):
      beforeText = text
      selection = sel
    case .noFocus:
      beforeText = nil
      selection = nil
    }

    // Row 4.
    guard facts.observerComplete else { return .unknown(.noObserver) }

    // Row 5: the same element, readable at the end, and different.
    if let beforeText, case .sameElement(let afterText?) = facts.after,
      !identical(afterText, beforeText)
    {
      return .changed(.textDiffers)
    }
    // Row 6: the field said its value changed.
    if facts.notifications.contains(.valueChanged) { return .changed(.notifiedValue) }
    // Rows 7b, 7c: focus and lifetime, not value.
    if facts.notifications.contains(.focusedElementChanged) { return .unknown(.notifiedFocus) }
    if facts.notifications.contains(.elementDestroyed) { return .unknown(.elementDestroyed) }

    // Rows 7, 7a, 8: the identical-field path. The selection guards apply only here.
    if let beforeText, let selection, case .sameElement(let afterText?) = facts.after,
      identical(afterText, beforeText)
    {
      switch selection {
      case .unavailable: return .unknown(.selectionUnavailable)
      case .text(let selected) where identical(selected, facts.payload):
        // Pasting over a selection that already holds the payload leaves the field identical
        // whether or not the paste arrived.
        return .unknown(.identicalSelection)
      case .text: return .unchanged(.fieldIdentical)
      }
    }

    // Row 9: nothing focused before, nothing at the end, and no focus notification (row 7b).
    if case .noFocus = facts.before, case .noFocus = facts.after {
      return .unchanged(.noFocus)
    }

    // Row 11: final text unreadable, focus moved, or anything else.
    return .unknown(.afterUnreadable)
  }

  /// Byte identity in UTF-16 code units.
  private static func identical(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf16.elementsEqual(rhs.utf16)
  }
}
