import EnviousWisprServices
import Foundation

/// The new Setup's visit and screen telemetry (#4528 chunk F2a, plan §3.8, M67). Observation only:
/// it never changes the flow, a download, readiness or a setting, and it owns no task or timer.
///
/// A step change is not a screen being shown (hidden steps, DEBUG positioning, restore and readiness
/// moves all change the step), so the only producer of `onboarding.screen_viewed` is
/// `screenPresented(_:resumed:)`, which Setup's screens call when a screen is actually on screen
/// (chunk D). Rows: one for the FIRST presentation of each step in a visit (refocus, repeated
/// notifications and revisits add none), so there are at most `maxScreenRowsPerVisit` and Back and
/// forward navigation can never use up the allowance before later screens are first seen; nothing
/// unless the visit in flight belongs to the new Setup. Revisits still move the position.
@MainActor
final class OnboardingTelemetryObserver {
  struct Inputs {
    /// The in-flight visit's start (`OnboardingProgress.sessionStart`), nil when none.
    var visitStart: () -> Date?
    /// Whether the in-flight visit is the new Setup's (never the old onboarding's).
    var visitOwned: () -> Bool
    /// Keeps the shared visit box's position current for an abandon row.
    var updatePosition: (OnboardingStep) -> Void
    var emitScreenViewed: (String, OnboardingTelemetry.Entry, Double) -> Void
    var now: () -> Date
  }

  /// Plan §3.8: the accepted ceiling, one per Setup screen (`done` is never presented).
  static let maxScreenRowsPerVisit = 14

  private let inputs: Inputs
  private var visit: Date?
  private var lastPresented: OnboardingStep?
  private var seenThisVisit: Set<OnboardingStep> = []
  var rowsThisVisit: Int { seenThisVisit.count }

  init(inputs: Inputs) {
    self.inputs = inputs
  }

  /// A Setup screen is now on screen. `resumed` is the coordinator's `resumedFromCheckpoint`.
  func screenPresented(_ step: OnboardingStep, resumed: Bool) {
    guard inputs.visitOwned(), let start = inputs.visitStart() else { return }
    if start != visit {
      // A new visit: counters start over (a reset of a live visit keeps its start, so it does not).
      visit = start
      lastPresented = nil
      seenThisVisit = []
    }
    guard step != lastPresented else { return }
    inputs.updatePosition(step)
    let entry = Self.entry(to: step, from: lastPresented, resumed: resumed)
    lastPresented = step
    // First view of this screen in this visit only (the set is bounded by the 14 screens).
    guard seenThisVisit.insert(step).inserted, seenThisVisit.count <= Self.maxScreenRowsPerVisit
    else { return }
    inputs.emitScreenViewed(step.rawValue, entry, max(0, inputs.now().timeIntervalSince(start)))
  }

  /// `resume` for the first screen of a restored visit; `back` for an earlier screen in Setup's
  /// order; otherwise `forward`.
  static func entry(
    to step: OnboardingStep, from previous: OnboardingStep?, resumed: Bool
  ) -> OnboardingTelemetry.Entry {
    guard let previous else { return resumed ? .resume : .forward }
    let order = OnboardingStep.allCases
    guard let to = order.firstIndex(of: step), let from = order.firstIndex(of: previous) else {
      return .forward
    }
    return to < from ? .back : .forward
  }
}

extension OnboardingTelemetryObserver.Inputs {
  /// Production inputs over the shared visit box and F1's capture path (consent unchanged).
  @MainActor
  static func live(
    progress: OnboardingProgress, visitOwned: @escaping () -> Bool
  ) -> Self {
    Self(
      visitStart: { progress.isInFlight ? progress.sessionStart : nil },
      visitOwned: visitOwned,
      updatePosition: { progress.update(screen: "setup", step: $0.rawValue) },
      emitScreenViewed: { step, entry, elapsed in
        TelemetryService.shared.onboardingScreenViewed(
          step: step, entry: entry, elapsedSeconds: elapsed)
      },
      now: { Date() })
  }
}
