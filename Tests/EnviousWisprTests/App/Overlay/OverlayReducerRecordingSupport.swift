import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprPipeline

extension OverlayReducer {

  /// Start a recording the way `OverlayDirector` does: PREPARE, route, COMMIT
  /// (#2375 Phase 3, chunk C3a).
  ///
  /// **Not a shortcut around the two-stage boundary — it IS the boundary.** A
  /// bare `reduce(.pipeline(.recording(_:)))` can morph a live recording and can
  /// no longer start one, because starting one needs a resolved design and a
  /// reducer holding only an intent has not resolved anything. This helper is the
  /// smallest honest way for a reducer test to obtain a recording occupant.
  ///
  /// **It resolves nothing.** The design is a parameter, so this helper is not a
  /// second authority on which pill the user gets: it never reads capability,
  /// never reads selections, and has no opinion. That decision belongs to the
  /// director, and `OverlayDirectorTests` is where it is asserted.
  ///
  /// **Effects are re-attached to the returned plan, deliberately.** They travel
  /// on the PREPARE token now, because the director must route them BEFORE it
  /// reads capability — so `commitRecording` returns a plan with none. Handing
  /// back the set the director would have routed keeps existing assertions about
  /// `plan.effects` reading the same OBSERVABLE fact rather than an artefact of
  /// where the value is carried.
  ///
  /// Lives in the test target rather than behind `#if DEBUG` in `Sources`: a
  /// DEBUG-only seam would take every test that uses it out of the Release lane,
  /// and a whole subsystem silently absent from Release is how a green Release
  /// count comes to mean less than it looks like.
  @discardableResult
  mutating func startRecordingForTests(
    audioLevel: Float,
    design: RecordingPillDesign = .classic,
    routeEffects: ([PillEffect]) -> Void = { _ in }
  ) -> OverlayPlan {
    switch prepareRecording(audioLevel: audioLevel) {
    case .morphed(let plan), .refused(let plan):
      return plan

    case .prepared(let token):
      routeEffects(token.effects)
      let entry = PillCatalog.entry(
        for: .recording(audioLevel: token.audioLevel, design: design), id: token.id)
      guard let definition = entry.definition else {
        Issue.record("the catalog's recording arm resolved to no definition")
        return .noChange
      }
      guard let plan = commitRecording(token, definition: definition) else {
        // Discarded. A test that wants this outcome should drive prepare and
        // commit itself so it can assert on the discard rather than infer it.
        return .noChange
      }
      return OverlayPlan(
        presentation: plan.presentation, didChange: plan.didChange,
        expiryCommand: plan.expiryCommand, deliverAction: plan.deliverAction,
        effects: token.effects, announcement: plan.announcement)
    }
  }
}
