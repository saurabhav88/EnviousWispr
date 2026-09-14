import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #2817 items 6 and 7: on Done the document owns the scroll, and the view switch sits on
/// its own row above it at the regular control size.
///
/// The founder, on the Ariana Grande run (2026-09-13): "Copy everything, Save as and Share
/// are hidden at the bottom of the transcript, so unless you scroll all the way down you
/// can't see it. We need to make the transcript its own box separate from the action
/// buttons at the bottom." The wizard's page scrolled as one piece, so a 200-turn document
/// put the action row pages away.
///
/// **What these checks are, and what they are NOT.** They scan the SOURCE of
/// `TranscribeFileView.swift` for the shape the layout depends on: two `ScrollView`
/// constructions, one for the five page steps and one holding `doneDocument` inside
/// `doneLayout`, and the segmented picker living in `documentControls` rather than among the
/// header chips. They render nothing, so they cannot see whether the action row is on screen
/// at 750 px; that is the Live UAT row (scroll the 48-minute document to its end and confirm
/// the four buttons never moved). What they DO catch is the cheap regression: someone wraps
/// the whole Done step in the page scroll again, or drops the picker back into the chip run,
/// and every behavioural test still passes because every control still works.
///
/// The same source-scan shape as `TranscribeFileButtonTreatmentTests`, for the same reason
/// that file gives: the suite has no layout instrument for placement.
@Suite("Transcribe a File Done layout (#2817 items 6 and 7)", .tags(.driftGuard))
struct TranscribeFileDoneLayoutTests {
  /// Derived from this file rather than the working directory: a relative path would scan
  /// whichever checkout happens to be current, and this repo routinely has four open.
  static var viewSource: String? {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Views
      .deletingLastPathComponent()  // EnviousWisprTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // repo root
      .appendingPathComponent("Sources/EnviousWisprAppKit/Views/Settings/TranscribeFileView.swift")
    return try? String(contentsOf: url, encoding: .utf8)
  }

  /// The text of one `private var <name>: some View {` body, from its declaration to the
  /// next member declaration at the same indentation. `nil` when the member is gone, which
  /// each row reports as a failure rather than a vacuous pass.
  static func member(_ name: String, in source: String) -> String? {
    guard let start = source.range(of: "private var \(name): some View {") else { return nil }
    let rest = source[start.upperBound...]
    // The next declaration at two-space indentation ends the member. Doc comments and
    // attributes on the following member begin with the same indent, so any of these closes it.
    let terminators = [
      "\n  private var ", "\n  private func ", "\n  @ViewBuilder\n", "\n  /// ", "\n  // MARK: ",
    ]
    let end =
      terminators
      .compactMap { rest.range(of: $0)?.lowerBound }
      .min() ?? rest.endIndex
    return String(rest[..<end])
  }

  @Test("the scanner can see its subject")
  func theScannerCanSeeItsSubject() {
    let source = Self.viewSource
    #expect(source != nil, "TranscribeFileView.swift is unreadable, so the rows below are vacuous")
    #expect(
      source.flatMap { Self.member("doneLayout", in: $0) } != nil,
      "`doneLayout` is gone, so the checks below no longer mean anything")
  }

  /// One page scroll for the five steps, one document scroll on Done, and nothing else.
  @Test("the wizard has exactly two ScrollViews, and Done's holds the document")
  func twoScrollViewsAndDoneHoldsTheDocument() {
    guard let source = Self.viewSource else { return }
    let constructions = source.components(separatedBy: "ScrollView {").count - 1
    #expect(constructions == 2, "expected 2 `ScrollView {` constructions, found \(constructions)")

    guard let stepPage = Self.member("stepPage", in: source),
      let doneLayout = Self.member("doneLayout", in: source)
    else {
      Issue.record("`stepPage` or `doneLayout` is gone")
      return
    }
    #expect(stepPage.contains("ScrollView {"), "the five page steps lost their scroll")
    guard let scroll = doneLayout.range(of: "ScrollView {"),
      let actions = doneLayout.range(of: "doneActions")
    else {
      Issue.record("Done's ScrollView or its action row is gone")
      return
    }
    let inside = doneLayout[scroll.upperBound..<actions.lowerBound]
    #expect(inside.contains("doneDocument"), "Done's ScrollView must hold the document")
    #expect(
      actions.lowerBound > scroll.upperBound && !inside.contains("doneActions"),
      "the action row must follow the document scroll as a sibling, never sit inside it")
    // The header appears twice on purpose: fixed above the scroll when the window is tall,
    // inside it when the window is short. Both spellings must be guarded by the same rule.
    #expect(
      doneLayout.contains("if headerFixed {\n          doneFixedTop")
        && inside.contains("if !headerFixed {\n              doneFixedTop"),
      "the header must be fixed OR scroll with the document, decided by `doneHeaderIsFixed`")
  }

  /// The threshold is a pure rule: a short window scrolls the header with the document so
  /// the action row can never be pushed off the bottom (Codex, review round 1).
  @Test(
    "the header is fixed only when the layout has room for it",
    arguments: [
      (CGFloat(300), false),  // the 400-point window floor, less the step bar and footer
      (CGFloat(599), false),
      (CGFloat(600), true),
      (CGFloat(650), true),  // a 750-point window, the size the evidence screenshots use
    ])
  func headerIsFixedOnlyWithRoom(height: CGFloat, fixed: Bool) {
    #expect(TranscribeFileView.doneHeaderIsFixed(availableHeight: height) == fixed)
    #expect(TranscribeFileView.doneFixedHeaderMinimumHeight == 600)
  }

  /// `body` routes Done to its own layout; the page scroll never draws it.
  @Test("body sends Done to doneLayout and every other step to the page scroll")
  func bodyRoutesDoneToItsOwnLayout() {
    guard let source = Self.viewSource else { return }
    #expect(
      source.contains(
        "if coordinator.step == .done {\n        doneLayout\n      } else {\n        stepPage\n      }"
      ),
      "the step routing in `body` changed shape")
    guard let stepPage = Self.member("stepPage", in: source) else { return }
    #expect(
      stepPage.contains("case .done: EmptyView()"),
      "the page scroll must not draw Done; it belongs to `doneLayout`")
  }

  /// The segmented control is in `documentControls`, regular size, and not among the chips.
  @Test("the view switch is on its own row at regular size, not in the chip run")
  func viewSwitchIsOnItsOwnRow() {
    guard let source = Self.viewSource else { return }
    let pickers = source.components(separatedBy: ".pickerStyle(.segmented)").count - 1
    #expect(pickers == 1, "expected one segmented picker, found \(pickers)")

    guard let controls = Self.member("documentControls", in: source),
      let metadata = Self.member("doneMetadata", in: source)
    else {
      Issue.record("`documentControls` or `doneMetadata` is gone")
      return
    }
    #expect(controls.contains("Picker(\n          \"View\""), "the picker left `documentControls`")
    #expect(controls.contains(".controlSize(.regular)"), "the picker is not at the regular size")
    #expect(!controls.contains(".fixedSize()"), "the picker takes its natural width on its own row")
    #expect(!metadata.contains("Picker("), "the picker is back among the header chips")
    #expect(!metadata.contains("Toggle("), "the Times toggle is back among the header chips")

    guard let top = Self.member("doneFixedTop", in: source) else { return }
    #expect(
      top.hasSuffix("documentControls\n  }\n") || top.contains("documentControls\n  }"),
      "`documentControls` must be the last thing above the document")
  }
}
