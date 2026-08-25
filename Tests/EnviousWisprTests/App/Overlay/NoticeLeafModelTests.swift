import AppKit
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// Every notice leaf renders the MODEL it is handed (#2376 Phase 4, C3).
///
/// **The axis-differential proof, and it is red before this chunk and green
/// after.** Render one kind twice through the ROOT with models differing in
/// exactly ONE field, and require the measured size to move on the axis that
/// field controls. That answers two questions at once, and the second is the one
/// a simpler proof misses: did the value reach the render at all, and did it
/// reach the RIGHT SLOT. A longer sentence on a single-line row changes WIDTH; a
/// secondary line on a two-line stack changes HEIGHT; a longer button label
/// changes WIDTH by the button's own delta.
///
/// Against the base revision `.recovery` and `.accessibilityToast` measure
/// IDENTICALLY under every model, because they took no model at all — they read
/// `DictationNarrator` themselves and hardcoded both button strings. So these
/// rows fail before the change, which is the parent-commit-equivalent control
/// this repo licenses inline, with no mutant run.
///
/// **Product Outcome.** When one of these fails the user is shown a pill whose
/// words are not the words the app decided to say.
@MainActor
@Suite(.tags(.productOutcome))
struct NoticeLeafModelTests {

  init() { _ = NSApplication.shared }

  private static func size(_ model: NoticeModel) -> CGSize {
    RenderedPillHarness.rootSize(
      for: PillDefinition(
        id: RenderedPillHarness.id(), content: .notice(model),
        expiry: .untilReplaced, requestedWidth: .measured))
  }

  /// The base model per kind, deliberately minimal so each row below changes one
  /// thing and nothing else.
  private static func base(_ kind: NoticeModel.Kind) -> NoticeModel {
    switch kind {
    case .recovery:
      return NoticeModel(
        kind: .recovery, text: "Recovering", accessibilityLabel: "Recovering",
        action: NoticeAction(label: "Discard", action: .discardRecovery))
    case .accessibilityToast:
      return NoticeModel(
        kind: .accessibilityToast, text: "Needs access",
        action: NoticeAction(label: "Grant", action: .grantAccessibility))
    default:
      return NoticeModel(kind: kind, text: "Notice")
    }
  }

  private static func with(
    _ base: NoticeModel, text: String? = nil, secondary: String?? = nil,
    action: NoticeAction?? = nil
  ) -> NoticeModel {
    NoticeModel(
      kind: base.kind, text: text ?? base.text,
      secondaryText: secondary ?? base.secondaryText,
      accessibilityLabel: base.accessibilityLabel, severity: base.severity,
      isMultiline: base.isMultiline, action: action ?? base.action)
  }

  nonisolated static let allKinds: [NoticeModel.Kind] = [
    .processing, .warmingUp, .ready, .notification, .importStatus, .recovery,
    .accessibilityToast,
  ]

  // MARK: - The text reaches the render, on the width axis

  @Test(
    "a longer sentence makes its pill wider, whichever leaf draws it",
    arguments: NoticeLeafModelTests.allKinds)
  func textReachesTheRender(kind: NoticeModel.Kind) throws {
    let short = Self.base(kind)
    let long = Self.with(short, text: String(repeating: "wider ", count: 8))

    let a = Self.size(short)
    let b = Self.size(long)
    try #require(a.width > 0 && b.width > 0, "\(kind) measured nothing: \(a) / \(b)")
    #expect(
      b.width > a.width,
      """
      \(kind) measured \(a.width)pt for a short sentence and \(b.width)pt for a long \
      one. The leaf is not rendering the model's text — it is drawing something it \
      chose itself, so a copy change made in the catalog never reaches the screen.
      """)
  }

  // MARK: - The secondary line reaches the render, on the HEIGHT axis

  /// The three kinds whose leaves draw a second line. The others have no slot for
  /// one, and asserting they grow would be asserting a defect.
  @Test(
    "a secondary line makes its pill taller",
    arguments: [NoticeModel.Kind.warmingUp, .ready, .recovery])
  func secondaryTextReachesTheRender(kind: NoticeModel.Kind) throws {
    let without = Self.with(Self.base(kind), secondary: .some(nil))
    let with = Self.with(Self.base(kind), secondary: "and a second line")

    let a = Self.size(without)
    let b = Self.size(with)
    try #require(a.height > 0 && b.height > 0, "\(kind) measured nothing")
    #expect(
      b.height > a.height,
      """
      \(kind) measured \(a.height)pt without a secondary line and \(b.height)pt with \
      one. The model's secondaryText is being ignored, which is how the recovery pill \
      came to carry its own copy of a sentence the catalog already owns.
      """)
  }

  // MARK: - The button's label reaches the render

  @Test(
    "a longer button label makes its pill wider",
    arguments: [NoticeModel.Kind.recovery, .accessibilityToast])
  func actionLabelReachesTheRender(kind: NoticeModel.Kind) throws {
    let short = Self.base(kind)
    let long = Self.with(
      short,
      action: .some(
        NoticeAction(
          label: "Discard this recovering recording now",
          action: short.action!.action)))

    let a = Self.size(short)
    let b = Self.size(long)
    #expect(
      b.width > a.width,
      """
      \(kind) measured \(a.width)pt with a short button label and \(b.width)pt with a \
      long one. The leaf is drawing a hardcoded label, so the catalog's is dead.
      """)
  }

  /// The paired negative: with no action the button is not drawn at all, so the
  /// pill is narrower. Without this, the row above could pass on a leaf that
  /// always draws a button and merely happens to read the label.
  @Test(
    "a notice with no action draws no button",
    arguments: [NoticeModel.Kind.recovery, .accessibilityToast])
  func noActionDrawsNoButton(kind: NoticeModel.Kind) throws {
    let withButton = Self.size(Self.base(kind))
    let without = Self.size(Self.with(Self.base(kind), action: .some(nil)))
    #expect(
      without.width < withButton.width,
      """
      \(kind) measured \(without.width)pt with no action and \(withButton.width)pt \
      with one. A button is being drawn for a notice that carries no action, which \
      means its label came from somewhere other than the model.
      """)
  }

  // MARK: - The catalog's closed set

  /// **The guard that lets the root dispatch with no `??` fallback.**
  ///
  /// `NoticeModel.action` is optional because most notices carry no button, but
  /// `.recovery` and `.accessibilityToast` structurally require one — their whole
  /// purpose is the affordance. The root refuses to substitute a literal when it
  /// is missing, which is only safe because this sweeps the catalog's own closed
  /// set of requests and fails if a row ever loses its action.
  @Test(
    "every request that draws an action pill carries its action",
    arguments: [
      PillCatalogRequest.recoveringLastRecording, .accessibilityToast,
    ])
  func noticeActionsAreCarriedByEveryKindThatDrawsAButton(request: PillCatalogRequest) throws {
    let definition = try #require(
      PillCatalog.entry(for: request, id: RenderedPillHarness.id()).definition)
    guard case .notice(let notice) = definition.content else {
      Issue.record("\(request) is not a notice")
      return
    }
    let action = try #require(
      notice.action,
      """
      \(request) carries no action. `OverlayRootView.dispatch` has no fallback to a \
      literal by design, so this pill would render without its button and the user \
      would have no way to act on it.
      """)
    #expect(!action.label.isEmpty, "\(request)'s button has no label")
    #expect(!action.spokenLabel.isEmpty, "\(request)'s button says nothing to VoiceOver")
  }

  /// And the recovery pill's spoken label is deliberately NOT its printed one.
  /// `DictationNarratorTests` pins the title and the element label as different
  /// strings; this pins that the BUTTON has its own too, which is the value that
  /// used to be a bare literal inside the view with no field behind it.
  @Test("the recovery pill's button says more to VoiceOver than it prints")
  func recoveryButtonHasItsOwnSpokenLabel() throws {
    let definition = try #require(
      PillCatalog.entry(for: .recoveringLastRecording, id: RenderedPillHarness.id())
        .definition)
    guard case .notice(let notice) = definition.content else {
      Issue.record("recovery is not a notice")
      return
    }
    let action = try #require(notice.action)
    #expect(
      action.spokenLabel != action.label,
      """
      the recovery button prints \(action.label) and speaks the same, so a VoiceOver \
      user hears a bare verb with nothing naming what it acts on.
      """)
  }

  /// The pill's own element label is likewise distinct from its title, and the
  /// catalog is where that distinction now lives rather than inside the view.
  @Test("the recovery pill's element label is not its title")
  func recoveryElementLabelIsNotTheTitle() throws {
    let definition = try #require(
      PillCatalog.entry(for: .recoveringLastRecording, id: RenderedPillHarness.id())
        .definition)
    guard case .notice(let notice) = definition.content else {
      Issue.record("recovery is not a notice")
      return
    }
    let spoken = try #require(notice.accessibilityLabel)
    #expect(
      spoken != notice.text,
      "the spoken label equals the title, so VoiceOver reads the title's ellipsis aloud")
    #expect(spoken == DictationNarrator.recoveryAccessibilityLabel)
    #expect(notice.text == DictationNarrator.recoveryTitle)
  }
}
