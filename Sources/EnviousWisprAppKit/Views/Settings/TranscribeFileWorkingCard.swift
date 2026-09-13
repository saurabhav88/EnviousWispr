import Foundation
import SwiftUI

// #2817 — the Working step is ONE card and nothing else (founder, 2026-09-13: hide the work).
// While a file runs the user sees which step is happening, a bar where there is an honest
// number, a rough time left once a few sections have landed, the brand lips moving, and Stop.
// No live document, no queue, no text that changes on screen. The transcript appears once, at
// Done.

/// What the card says, derived from the coordinator's state on every render.
///
/// A pure value so the mapping is testable without a coordinator. `nil` means no run is
/// showing (the six non-running states), which the wizard never renders on Working anyway:
/// `stop()` moves the step to Done in the same synchronous call that sets `.stopped`.
struct WorkingStepModel: Equatable {
  enum Step: Equatable {
    case preparing
    case transcribing
    case findingSpeakers
    case cleaning(done: Int, total: Int)
  }

  let step: Step
  /// "Preparing", "Transcribing", "Finding who said what", "Cleaning section 3 of 14".
  let title: String
  /// 0...1 for the bar, or `nil` when there is no honest number: the track is drawn alone,
  /// with no fill, no percentage and no shimmer, because a bar sitting at 0% for thirty
  /// seconds is what read as "stuck" (finding 1).
  let fraction: Double?

  /// The coordinator names these phases while `state` is `.transcribing`; each is set-up
  /// work, not transcription (`FileImportCoordinator` sets them before the engine warms, before
  /// a re-polish, and while the split runs).
  static let preparingPhases: Set<String> = [
    "Getting the engine ready", "Preparing cleanup", "Dividing it up to clean",
  ]

  /// The phase the coordinator names while the speaker step is awaited before cleanup
  /// (#2817 pipeline half). Read alongside `speakerStepState` so the card reads the same on
  /// the build that still starts the speaker task beside the split.
  static let speakerPhase = "Finding who said what"

  /// Precedence: cleaning (a count exists) > finding who said what (the speaker pass is
  /// running and nothing is being cleaned) > a preparing phase > transcribing. The engine name
  /// is not on the card: the pinned footer and the Done chip already carry it.
  static func make(
    state: FileImportCoordinator.State, phase: String,
    speakerStepState: FileImportCoordinator.SpeakerStepState
  ) -> WorkingStepModel? {
    switch state {
    case .transcribing:
      if speakerStepState == .inProgress || phase == speakerPhase {
        return WorkingStepModel(step: .findingSpeakers, title: speakerPhase, fraction: nil)
      }
      if preparingPhases.contains(phase) {
        return WorkingStepModel(step: .preparing, title: "Preparing", fraction: nil)
      }
      return WorkingStepModel(step: .transcribing, title: "Transcribing", fraction: nil)
    case .polishing(let done, let total):
      guard total > 0 else {
        return WorkingStepModel(step: .preparing, title: "Preparing", fraction: nil)
      }
      let completed = min(max(done, 0), total)
      // The CURRENT section, `min(done + 1, total)`: the same arithmetic as the coordinator's
      // `cleaningLabel`, so "section 14 of 14" is the last one being cleaned, never a 15th.
      return WorkingStepModel(
        step: .cleaning(done: completed, total: total),
        title: "Cleaning section \(min(completed + 1, total)) of \(total)",
        fraction: Double(completed) / Double(total))
    case .idle, .reading, .ready, .finished, .rejected, .stopped:
      return nil
    }
  }
}

/// A rough time left, from the sections THIS view has watched land on THIS run.
///
/// The first count seen is a baseline, not a measurement: a view created mid-run (the user
/// opened the wizard at section 9) would otherwise credit nine sections to one instant. Three
/// TIMED sections must land before a number is shown, and the per-section time is the MEDIAN so
/// one slow section (a polish timeout at 15 s beside 12 s neighbours) does not swing it. There
/// is no pre-run fallback: `estimateText` estimates the whole run, not what is left, and a
/// wrong "left" is worse than none.
struct SectionPace: Equatable {
  private var baseline: Int?
  private var landings: [(count: Int, at: Date)] = []

  static let sectionsNeeded = 3

  /// Records the count as of `now`. A count below the last one seen (a re-polish restarted
  /// the numbering) resets the history; the caller also resets on a generation change.
  mutating func observe(sectionsDone: Int, at now: Date) {
    guard let baseline else {
      self.baseline = sectionsDone
      return
    }
    let last = landings.last?.count ?? baseline
    if sectionsDone < last {
      self = SectionPace()
      self.baseline = sectionsDone
      return
    }
    guard sectionsDone > last else { return }
    landings.append((count: sectionsDone, at: now))
  }

  /// Seconds per section, or `nil` until enough have landed. The first landing only starts
  /// the clock (the baseline has no time of its own), so `sectionsNeeded` counts sections
  /// with a MEASURED interval behind them.
  func secondsPerSection() -> Double? {
    guard let first = landings.first, let last = landings.last,
      last.count - first.count >= Self.sectionsNeeded
    else { return nil }
    // Each landing may carry more than one section (two parts finishing between two
    // renders), so the rate is elapsed / sections for each interval, then the median.
    var rates: [Double] = []
    var previous = first
    for landing in landings.dropFirst() {
      let sections = landing.count - previous.count
      let seconds = landing.at.timeIntervalSince(previous.at)
      if sections > 0, seconds > 0 { rates.append(seconds / Double(sections)) }
      previous = landing
    }
    guard !rates.isEmpty else { return nil }
    let sorted = rates.sorted()
    let mid = sorted.count / 2
    return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
  }

  /// "about 3 minutes left" / "about a minute left" / "under a minute left", or `nil`.
  func remainingText(sectionsDone: Int, sectionsTotal: Int) -> String? {
    guard let perSection = secondsPerSection(), sectionsTotal > sectionsDone else { return nil }
    let seconds = Double(sectionsTotal - sectionsDone) * perSection
    let minutes = Int((seconds / 60).rounded())
    switch minutes {
    case ..<1: return "under a minute left"
    case 1: return "about a minute left"
    default: return "about \(minutes) minutes left"
    }
  }

  static func == (lhs: SectionPace, rhs: SectionPace) -> Bool {
    lhs.baseline == rhs.baseline
      && lhs.landings.map(\.count) == rhs.landings.map(\.count)
      && lhs.landings.map(\.at) == rhs.landings.map(\.at)
  }
}

/// The brand lips moving while a run is active (finding 3: "no visual cue it's working vs
/// possibly stuck"; the founder's own words were "EW lips move all wavy like representing the
/// polishing"). Reuses `RainbowLipsIcon`, driven by a synthetic level rather than a microphone.
///
/// Reduce Motion is read exactly as `RainbowLipsIcon` reads it, through the overlay's override
/// seam, so a test can pin `showsPulse` without setting a get-only environment value. The
/// still lips are drawn at the pulse's own mid-level so they are no smaller than the moving
/// ones on average.
struct WorkingPulseMark: View {
  let size: CGFloat

  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.overlayReduceMotionOverride) private var reduceMotionOverride
  private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

  static let restingLevel: Float = 0.35
  /// One breath every 1.4 s between the resting level and 0.7.
  static func level(at time: TimeInterval) -> Float {
    restingLevel + 0.35 * Float(0.5 + 0.5 * sin(time * 2 * .pi / 1.4))
  }

  static func showsPulse(reduceMotion: Bool) -> Bool {
    OverlayMotion.showsAmbientLoop(reduceMotion: reduceMotion)
  }

  var body: some View {
    if Self.showsPulse(reduceMotion: reduceMotion) {
      TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
        RainbowLipsIcon(
          size: size, audioLevel: Self.level(at: timeline.date.timeIntervalSinceReferenceDate))
      }
    } else {
      RainbowLipsIcon(size: size, audioLevel: Self.restingLevel)
    }
  }
}

/// The card itself: mark · title and time left · bar · Stop.
///
/// The Stop button is the wizard's own quiet button (`SettingsActionButton`, `.quiet`,
/// rounded rect), the same treatment every other button on these six steps carries, and it
/// stays a real button for VoiceOver; only the status half is read as one element.
struct TranscribeFileWorkingCard: View {
  let model: WorkingStepModel
  let remainingText: String?
  let onStop: () -> Void

  var body: some View {
    HStack(spacing: 14) {
      status
      SettingsActionButton(
        title: "Stop", isEnabled: true, emphasis: .quiet, shape: .roundedRect,
        size: .medium, systemImage: nil, action: onStop)
    }
  }

  /// Mark, title, time left and the bar, read to a screen reader as one sentence: the title,
  /// then the percent only when the fraction is known, then the time left only when known.
  private var status: some View {
    HStack(spacing: 14) {
      WorkingPulseMark(size: 28)
      VStack(alignment: .leading, spacing: 2) {
        Text(model.title)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(Color.stTextBody)
        if let remainingText {
          Text(remainingText)
            .font(.stHelper)
            .foregroundStyle(Color.stTextSecondary)
        }
      }
      .fixedSize(horizontal: true, vertical: false)
      Spacer(minLength: 12)
      bar
        .frame(maxWidth: 220)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityText)
  }

  /// The one overall bar (finding 3: a per-section bar that resets reads as a loop). With no
  /// honest number the track is drawn alone.
  private var bar: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(Color.stAccentLight.opacity(0.6))
        if let fraction = model.fraction {
          Capsule()
            .fill(
              LinearGradient(
                colors: [Color.stAccent, Color.stAccentSolid],
                startPoint: .leading, endPoint: .trailing)
            )
            .frame(width: max(6, geo.size.width * fraction))
        }
      }
    }
    .frame(height: 9)
  }

  private var accessibilityText: String {
    var parts = [model.title]
    if let fraction = model.fraction { parts.append("\(Int(fraction * 100)) percent") }
    if let remainingText { parts.append(remainingText) }
    return parts.joined(separator: ", ")
  }
}
