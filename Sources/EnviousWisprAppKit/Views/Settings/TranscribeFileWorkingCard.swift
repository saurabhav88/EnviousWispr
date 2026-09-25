import Foundation
import SwiftUI

// #2817 — the Working step is ONE card and nothing else (founder, 2026-09-13: hide the work).
// While a file runs the user sees which step is happening, a bar where there is an honest
// number, a rough time left once a few sections have landed, the brand lips moving, and Stop.
// No live document, no queue, no text that changes on screen. The transcript appears once, at
// Done.

/// What the card says, derived from the coordinator's state on every render: three rows, one per
/// step the founder named (#2918, 2026-09-13: "each step should have its own progress bar"),
/// each with its own bar and state. A finished step keeps a full bar and a check; the current
/// step moves; a step not yet reached shows its empty track. Set-up work sits on the row it
/// precedes ("Getting the engine ready" on Transcribing; "Preparing cleanup" and "Dividing it
/// up to clean" on Cleaning), indeterminate, titled by the coordinator's phase.
///
/// A pure value so the mapping is testable without a coordinator. `nil` means no run is
/// showing (the six non-running states), which the wizard never renders on Working anyway:
/// `stop()` moves the step to Done in the same synchronous call that sets `.stopped`.
struct WorkingStepModel: Equatable {
  enum Kind: CaseIterable, Equatable {
    case transcribing, findingSpeakers, cleaning
  }
  enum RowState: Equatable { case pending, active, done }

  struct Row: Equatable {
    let kind: Kind
    /// "Transcribing", "Transcribing 12 of 100 minutes", "Getting the engine ready",
    /// "Finding who said what", "Cleaning section 3 of 14", "Preparing cleanup".
    let title: String
    let state: RowState
    /// 0...1 for the bar. `nil` on an active row means no honest number exists: the track
    /// carries the indeterminate sweep and the title carries the elapsed seconds (finding 1
    /// of #2897 was a bar sitting at 0% for thirty seconds; the sweep is motion without a
    /// false number). A done row is drawn full whatever its fraction.
    let fraction: Double?
  }

  let rows: [Row]
  /// The current step, or nil when the run has no active row (never, while running).
  var active: Row? { rows.first { $0.state == .active } }
  /// The old one-line title, kept for the accessibility sentence and the tests: the active
  /// row's title.
  var title: String { active?.title ?? "" }

  /// The coordinator names these phases while `state` is `.transcribing`; each is set-up
  /// work, not transcription. The first precedes transcribing, the other two precede cleaning.
  /// These are the producer's English tokens and decide which row is active; the card shows
  /// `displayPhase(_:)` of them, never the token, so translation cannot move a branch (#3142).
  static let enginePhase = "Getting the engine ready"
  static let cleanupPreparingPhases: Set<String> = ["Preparing cleanup", "Dividing it up to clean"]
  static let preparingPhases: Set<String> = cleanupPreparingPhases.union([enginePhase])

  /// The phase the coordinator names while the speaker step is awaited before cleanup
  /// (#2817 pipeline half). Read alongside `speakerStepState` so the card reads the same on
  /// the build that still starts the speaker task beside the split.
  static let speakerPhase = "Finding who said what"

  /// "Transcribing 12 of 100 minutes" once a fraction exists, else the bare word. Minutes
  /// are floored so the reached count never reads ahead of the total.
  static func transcribingTitle(fraction: Double?, fileSeconds: Double) -> String {
    guard let fraction, fileSeconds > 0 else { return transcribingWord }
    // The same whole minutes the summary's Length shows; under a minute there is no count.
    let total = FileImportCoordinator.wholeMinutes(fileSeconds)
    guard total > 0 else { return transcribingWord }
    let reached = min(total, Int(fraction * fileSeconds / 60))
    return String(
      localized: "Transcribing \(String(reached)) of \(String(total)) minutes",
      comment:
        "Transcribe a File, Working step: progress. The first %@ is minutes done, the second the file's length in minutes."
    )
  }

  static var transcribingWord: String {
    String(
      localized: "Transcribing",
      comment:
        "Transcribe a File, Working step: the transcribing row, before its minutes are known.")
  }

  /// Precedence: cleaning (a count exists) > cleanup-preparing phases > finding who said what
  /// (the speaker pass is running and nothing is being cleaned) > the engine phase >
  /// transcribing. The engine name is not on the card: the pinned footer and the Done chip
  /// already carry it.
  static func make(
    state: FileImportCoordinator.State, phase: String,
    speakerStepState: FileImportCoordinator.SpeakerStepState,
    transcribingFraction: Double? = nil, fileSeconds: Double = 0
  ) -> WorkingStepModel? {
    func rows(activeKind: Kind, title: String, fraction: Double?) -> WorkingStepModel {
      let order = Kind.allCases
      let activeIndex = order.firstIndex(of: activeKind)!
      return WorkingStepModel(rows: order.enumerated().map { index, kind in
        if index < activeIndex {
          return Row(kind: kind, title: Self.doneTitle(kind), state: .done, fraction: 1)
        }
        if index == activeIndex {
          return Row(kind: kind, title: title, state: .active, fraction: fraction)
        }
        return Row(kind: kind, title: Self.doneTitle(kind), state: .pending, fraction: nil)
      })
    }
    switch state {
    case .transcribing:
      if cleanupPreparingPhases.contains(phase) {
        return rows(activeKind: .cleaning, title: displayPhase(phase), fraction: nil)
      }
      if speakerStepState == .inProgress || phase == speakerPhase {
        return rows(activeKind: .findingSpeakers, title: displayPhase(speakerPhase), fraction: nil)
      }
      if phase == enginePhase {
        return rows(activeKind: .transcribing, title: displayPhase(enginePhase), fraction: nil)
      }
      let fraction = transcribingFraction.map { min(max($0, 0), 1) }
      return rows(
        activeKind: .transcribing,
        title: transcribingTitle(fraction: fraction, fileSeconds: fileSeconds),
        fraction: fraction)
    case .polishing(let done, let total):
      guard total > 0 else {
        return rows(activeKind: .cleaning, title: displayPhase("Preparing cleanup"), fraction: nil)
      }
      let completed = min(max(done, 0), total)
      // The CURRENT section, `min(done + 1, total)`, so "section 14 of 14" is the last one
      // being cleaned, never a 15th.
      return rows(
        activeKind: .cleaning,
        title: String(
          localized: "Cleaning section \(String(min(completed + 1, total))) of \(String(total))",
          comment:
            "Transcribe a File, Working step: cleanup progress. The first %@ is the section being cleaned, the second the number of sections."
        ),
        fraction: Double(completed) / Double(total))
    case .idle, .reading, .ready, .finished, .rejected, .stopped:
      return nil
    }
  }

  /// What the card shows for a phase token the coordinator names. Only the tokens the card
  /// displays are here; an unknown token reads as itself (English), never as blank.
  static func displayPhase(_ phase: String) -> String {
    switch phase {
    case enginePhase:
      return String(
        localized: "Getting the engine ready",
        comment: "Transcribe a File, Working step: set-up before transcription starts.")
    case speakerPhase:
      return String(
        localized: "Finding who said what",
        comment: "Transcribe a File, Working step: the pass that labels speakers.")
    case "Preparing cleanup":
      return String(
        localized: "Preparing cleanup",
        comment: "Transcribe a File, Working step: set-up before AI cleanup of the transcript.")
    case "Dividing it up to clean":
      return String(
        localized: "Dividing it up to clean",
        comment:
          "Transcribe a File, Working step: splitting the transcript into sections for cleanup.")
    default:
      return phase
    }
  }

  /// The resting title of a row that is done or not yet reached.
  static func doneTitle(_ kind: Kind) -> String {
    switch kind {
    case .transcribing: return transcribingWord
    case .findingSpeakers: return displayPhase(speakerPhase)
    case .cleaning:
      return String(
        localized: "Cleaning",
        comment:
          "Transcribe a File, Working step: the cleanup row's name when it is done or not yet reached."
      )
    }
  }
}

/// The one spelling of an estimate, before the run ("Ready in about 3 minutes") and during it
/// ("about 3 minutes left"): rounded to the nearest minute, "under a minute" below 30 s.
///
/// The estimate is TYPED and each place it appears has its own whole sentence (#3142): the
/// phrase takes a different case in other languages ("in about a minute" versus "about a
/// minute left"), so it is never spliced into a sentence.
enum ImportEstimateWording {
  enum Estimate: Equatable {
    case underAMinute
    case aboutAMinute
    case aboutMinutes(Int)
  }

  static func estimate(seconds: Double) -> Estimate {
    let minutes = Int((seconds / 60).rounded())
    switch minutes {
    case ..<1: return .underAMinute
    case 1: return .aboutAMinute
    default: return .aboutMinutes(minutes)
    }
  }

  /// The phrase on its own, as the Working page's Estimate row shows it.
  static func text(seconds: Double) -> String {
    switch estimate(seconds: seconds) {
    case .underAMinute:
      return String(
        localized: "under a minute",
        comment: "Transcribe a File: an estimate shown on its own, in lowercase.")
    case .aboutAMinute:
      return String(
        localized: "about a minute",
        comment: "Transcribe a File: an estimate shown on its own, in lowercase.")
    case .aboutMinutes(let minutes):
      return String(
        localized: "about \(String(minutes)) minutes",
        comment:
          "Transcribe a File: an estimate shown on its own, in lowercase. %@ is minutes, never 1.")
    }
  }

  /// "Ready in about 3 minutes", under the chosen file.
  static func readyIn(seconds: Double) -> String {
    switch estimate(seconds: seconds) {
    case .underAMinute:
      return String(
        localized: "Ready in under a minute",
        comment: "Transcribe a File: how long the transcript will take.")
    case .aboutAMinute:
      return String(
        localized: "Ready in about a minute",
        comment: "Transcribe a File: how long the transcript will take.")
    case .aboutMinutes(let minutes):
      return String(
        localized: "Ready in about \(String(minutes)) minutes",
        comment: "Transcribe a File: how long the transcript will take. %@ is minutes, never 1.")
    }
  }

  /// "about 3 minutes left", under the active Working row.
  static func left(seconds: Double) -> String {
    switch estimate(seconds: seconds) {
    case .underAMinute:
      return String(
        localized: "under a minute left",
        comment: "Transcribe a File, Working step: time left, in lowercase.")
    case .aboutAMinute:
      return String(
        localized: "about a minute left",
        comment: "Transcribe a File, Working step: time left, in lowercase.")
    case .aboutMinutes(let minutes):
      return String(
        localized: "about \(String(minutes)) minutes left",
        comment:
          "Transcribe a File, Working step: time left, in lowercase. %@ is minutes, never 1.")
    }
  }

  /// The Review step's warning that dictation stops for the length of the run.
  static func dictationPauses(seconds: Double) -> String {
    switch estimate(seconds: seconds) {
    case .underAMinute:
      return String(
        localized:
          "Dictation pauses while this runs. Your keybind will not record until the transcript is finished, in under a minute.",
        comment: "Transcribe a File, Review step: warning before starting.")
    case .aboutAMinute:
      return String(
        localized:
          "Dictation pauses while this runs. Your keybind will not record until the transcript is finished, in about a minute.",
        comment: "Transcribe a File, Review step: warning before starting.")
    case .aboutMinutes(let minutes):
      return String(
        localized:
          "Dictation pauses while this runs. Your keybind will not record until the transcript is finished, in about \(String(minutes)) minutes.",
        comment:
          "Transcribe a File, Review step: warning before starting. %@ is minutes, never 1.")
    }
  }
}

/// A rough time left, from the sections THIS view has watched land on THIS run.
///
/// The first count seen is a baseline, not a measurement: a view created mid-run (the user
/// opened the wizard at section 9) would otherwise credit nine sections to one instant. Three
/// TIMED sections must land before a number is shown, and the per-section time is the MEAN
/// (elapsed since the first landing ÷ sections landed since). Not the median: on a document
/// made of speaker turns the per-section time is skewed, not noisy (a 48-minute two-voice
/// file polished with a median section of 0.27 s and a mean of 0.72 s), and remaining ×
/// median read "about a minute left" while two minutes remained (#2817, measured 2026-09-13).
/// A slow section's time is real waiting and counts in full. There is no pre-run fallback:
/// `estimateText` estimates the whole run, not what is left, and a wrong "left" is worse
/// than none.
struct SectionPace: Equatable {
  private var baseline: Int?
  private var landings: [(count: Int, at: Date)] = []
  /// Landings (not units) needed before a figure is shown. Sections land one at a time, so
  /// the count difference below is the count that matters there; the transcribing step
  /// lands 30-second windows in audio seconds (#2918), where one landing would clear the
  /// count difference at once, so that step asks for three landings.
  let minimumLandings: Int

  init(minimumLandings: Int = 1) { self.minimumLandings = minimumLandings }

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
      self = SectionPace(minimumLandings: minimumLandings)
      self.baseline = sectionsDone
      return
    }
    guard sectionsDone > last else { return }
    landings.append((count: sectionsDone, at: now))
  }

  /// Seconds per section, or `nil` until enough have landed. The first landing only starts
  /// the clock (the baseline has no time of its own), so `sectionsNeeded` counts sections
  /// with a MEASURED interval behind them. A landing may carry more than one section (two
  /// parts finishing between two renders); elapsed ÷ sections weights each by its share.
  func secondsPerSection() -> Double? {
    guard let first = landings.first, let last = landings.last,
      last.count - first.count >= Self.sectionsNeeded,
      landings.count >= minimumLandings
    else { return nil }
    let seconds = last.at.timeIntervalSince(first.at)
    guard seconds > 0 else { return nil }
    return seconds / Double(last.count - first.count)
  }

  /// "about 3 minutes left" / "about a minute left" / "under a minute left", or `nil`.
  func remainingText(sectionsDone: Int, sectionsTotal: Int) -> String? {
    guard let perSection = secondsPerSection(), sectionsTotal > sectionsDone else { return nil }
    let seconds = Double(sectionsTotal - sectionsDone) * perSection
    return ImportEstimateWording.left(seconds: seconds)
  }

  static func == (lhs: SectionPace, rhs: SectionPace) -> Bool {
    lhs.minimumLandings == rhs.minimumLandings && lhs.baseline == rhs.baseline
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

/// The card itself: mark · three step rows (title, detail, bar) · Stop.
///
/// The Stop button is the wizard's own quiet button (`SettingsActionButton`, `.quiet`,
/// rounded rect), the same treatment every other button on these six steps carries, and it
/// stays a real button for VoiceOver; each row is read as one element.
struct TranscribeFileWorkingCard: View {
  let model: WorkingStepModel
  /// "about 3 minutes left" for the active row when a pace exists, else nil.
  let remainingText: String?
  /// When the active step started (the coordinator's `stepStartedAt`); the elapsed seconds
  /// shown on an active row that has no fraction ("Finding who said what · 36 s").
  let stepStartedAt: Date
  let onStop: () -> Void

  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.overlayReduceMotionOverride) private var reduceMotionOverride
  private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      WorkingPulseMark(size: 28)
        .padding(.top, 2)
      VStack(alignment: .leading, spacing: 10) {
        ForEach(model.rows, id: \.kind) { row in
          StepRow(
            row: row,
            detail: row.state == .active ? remainingText : nil,
            stepStartedAt: stepStartedAt,
            showsSweep: WorkingPulseMark.showsPulse(reduceMotion: reduceMotion))
        }
      }
      SettingsActionButton(
        title: "Stop", isEnabled: true, emphasis: .quiet, shape: .roundedRect,
        size: .medium, systemImage: nil, action: onStop)
    }
  }

  /// "Finding who said what · 36 s": the elapsed seconds an active row with no honest
  /// fraction shows beside its title, so a 36-second wait reads as work, not a hang.
  static func elapsedText(since start: Date, now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(start)))
    return String(
      localized: "\(String(seconds)) s",
      comment: "Transcribe a File, Working step: seconds spent on a step. s abbreviates seconds.")
  }

  /// One row: title (plus elapsed seconds while indeterminate), the time left, the bar.
  struct StepRow: View {
    let row: WorkingStepModel.Row
    let detail: String?
    let stepStartedAt: Date
    let showsSweep: Bool

    private var indeterminate: Bool { row.state == .active && row.fraction == nil }

    var body: some View {
      TimelineView(.periodic(from: stepStartedAt, by: 1)) { timeline in
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
              Text(row.title)
                .font(.system(size: 14, weight: row.state == .active ? .semibold : .regular))
                .foregroundStyle(row.state == .pending ? Color.stTextSecondary : Color.stTextBody)
              if indeterminate {
                Text("· \(TranscribeFileWorkingCard.elapsedText(since: stepStartedAt, now: timeline.date))")
                  .font(.stHelper)
                  .foregroundStyle(Color.stTextSecondary)
              }
              if row.state == .done {
                Image(systemName: "checkmark.circle.fill")
                  .font(.system(size: 12))
                  .foregroundStyle(Color.stSuccess)
              }
            }
            if let detail {
              Text(detail)
                .font(.stHelper)
                .foregroundStyle(Color.stTextSecondary)
            }
          }
          .fixedSize(horizontal: true, vertical: false)
          Spacer(minLength: 12)
          StepBar(fraction: row.state == .done ? 1 : row.fraction, sweeping: indeterminate && showsSweep)
            .frame(maxWidth: 220)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(now: timeline.date))
      }
    }

    func accessibilityText(now: Date) -> String {
      var parts = [row.title]
      switch row.state {
      case .done:
        parts.append(
          String(
            localized: "done", comment: "VoiceOver, Transcribe a File: a Working row is finished."))
      case .pending:
        parts.append(
          String(
            localized: "not started",
            comment: "VoiceOver, Transcribe a File: a Working row has not started."))
      case .active:
        if let fraction = row.fraction {
          parts.append(
            String(
              localized: "\(Int(fraction * 100)) percent",
              comment: "VoiceOver, Transcribe a File: a Working row's progress. %lld is 0 to 100."))
        } else {
          parts.append(
            String(
              localized:
                "in progress, \(TranscribeFileWorkingCard.elapsedText(since: stepStartedAt, now: now))",
              comment:
                "VoiceOver, Transcribe a File: a Working row with no progress bar. %@ is the time spent, such as 36 s."
            ))
        }
        if let detail { parts.append(detail) }
      }
      return parts.joined(separator: ", ")
    }
  }

  /// A row's bar: the fill for a fraction, a full fill for a done row, an empty track for a
  /// pending one, and for an active row with no honest number a sweep, a third of the track
  /// gliding across once every 1.4 s (the pulse mark's own period). Under Reduce Motion the
  /// track is drawn alone and the elapsed seconds beside the title carry the "still working".
  struct StepBar: View {
    let fraction: Double?
    let sweeping: Bool

    /// Where the sweep's leading edge sits, 0...1, for a time: one pass per 1.4 s, then wrap.
    static func sweepOffset(at time: TimeInterval) -> Double {
      let phase = (time / 1.4).truncatingRemainder(dividingBy: 1)
      return phase < 0 ? phase + 1 : phase
    }

    var body: some View {
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          Capsule().fill(Color.stAccentLight.opacity(0.6))
          if let fraction {
            Capsule()
              .fill(
                LinearGradient(
                  colors: [Color.stAccent, Color.stAccentSolid],
                  startPoint: .leading, endPoint: .trailing)
              )
              .frame(width: max(6, geo.size.width * min(max(fraction, 0), 1)))
          } else if sweeping {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
              let width = geo.size.width / 3
              let travel = geo.size.width + width
              let x = Self.sweepOffset(at: timeline.date.timeIntervalSinceReferenceDate) * travel - width
              Capsule()
                .fill(
                  LinearGradient(
                    colors: [Color.stAccent.opacity(0), Color.stAccent, Color.stAccent.opacity(0)],
                    startPoint: .leading, endPoint: .trailing)
                )
                .frame(width: width)
                .offset(x: x)
            }
            .clipShape(Capsule())
          }
        }
      }
      .frame(height: 9)
    }
  }
}
