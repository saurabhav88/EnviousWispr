import EnviousWisprCore
import Foundation
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// #2817 — the Working step's one card, and the Marked up colours both renderers share.
///
/// **When this fails, the user sees the wrong step name while their file runs (a bar "stuck"
/// on Preparing through the whole cleanup), a time-left figure invented from a count the
/// screen never timed, a removed word that is not red, or a pulse that keeps moving with
/// Reduce Motion on.** Product coverage.
@Suite(.tags(.productOutcome))
struct TranscribeFileWorkingCardTests {

  // MARK: - The step mapping

  private func make(
    _ state: FileImportCoordinator.State, phase: String = "",
    speakers: FileImportCoordinator.SpeakerStepState = .notStarted
  ) -> WorkingStepModel? {
    WorkingStepModel.make(state: state, phase: phase, speakerStepState: speakers)
  }

  @Test("the set-up phases read Preparing, the engine's own work reads Transcribing")
  func transcribingPhases() {
    for phase in ["Getting the engine ready", "Preparing cleanup", "Dividing it up to clean"] {
      let model = make(.transcribing(fileName: "a.m4a"), phase: phase)
      #expect(model?.step == .preparing, "\(phase)")
      #expect(model?.title == "Preparing")
      #expect(model?.fraction == nil)
    }
    let model = make(.transcribing(fileName: "a.m4a"), phase: "Writing down what was said")
    #expect(model?.step == .transcribing)
    #expect(model?.title == "Transcribing")
    #expect(model?.fraction == nil)
  }

  @Test("the speaker step wins over a preparing phase while transcribing, by state or by phase")
  func findingSpeakers() {
    let byState = make(
      .transcribing(fileName: "a.m4a"), phase: "Dividing it up to clean", speakers: .inProgress)
    #expect(byState?.step == .findingSpeakers)
    #expect(byState?.title == "Finding who said what")
    let byPhase = make(.transcribing(fileName: "a.m4a"), phase: "Finding who said what")
    #expect(byPhase?.step == .findingSpeakers)
    #expect(byPhase?.fraction == nil)
  }

  @Test("cleaning names the CURRENT section and measures the completed ones")
  func cleaning() {
    let first = make(.polishing(done: 0, total: 14), speakers: .inProgress)
    #expect(first?.step == .cleaning(done: 0, total: 14), "polishing wins over the speaker task")
    #expect(first?.title == "Cleaning section 1 of 14")
    #expect(first?.fraction == 0)
    let mid = make(.polishing(done: 8, total: 14))
    #expect(mid?.title == "Cleaning section 9 of 14")
    #expect(mid?.fraction == 8.0 / 14.0)
    let last = make(.polishing(done: 14, total: 14))
    #expect(last?.title == "Cleaning section 14 of 14", "never a 15th")
    #expect(last?.fraction == 1)
    #expect(make(.polishing(done: 0, total: 0))?.step == .preparing, "no count yet")
    #expect(make(.polishing(done: 20, total: 14))?.fraction == 1, "clamped")
  }

  @Test("the six non-running states show no card")
  func nonRunningStates() {
    let states: [FileImportCoordinator.State] = [
      .idle, .reading(fileName: "a"), .ready(fileName: "a", seconds: 1), .finished,
      .rejected(.cannotRead), .stopped,
    ]
    for state in states {
      #expect(make(state, phase: "Cleaning it up", speakers: .inProgress) == nil, "\(state)")
    }
  }

  // MARK: - Time left

  private func pace(_ counts: [(Int, TimeInterval)]) -> SectionPace {
    var pace = SectionPace()
    let start = Date(timeIntervalSinceReferenceDate: 1_000)
    for (count, seconds) in counts {
      pace.observe(sectionsDone: count, at: start.addingTimeInterval(seconds))
    }
    return pace
  }

  @Test("no figure until three TIMED sections have landed; the first sight is only a baseline")
  func paceNeedsThreeTimedSections() {
    // Opened at section 9: the nine already done are not credited to one instant.
    #expect(pace([(9, 0)]).secondsPerSection() == nil)
    #expect(
      pace([(9, 0), (10, 12)]).secondsPerSection() == nil, "one landing only starts the clock")
    #expect(pace([(9, 0), (10, 12), (11, 24), (12, 36)]).secondsPerSection() == nil, "two timed")
    let enough = pace([(9, 0), (10, 12), (11, 24), (12, 36), (13, 48)])
    #expect(enough.secondsPerSection() == 12, "three timed sections at 12 s each")
    #expect(enough.remainingText(sectionsDone: 13, sectionsTotal: 28) == "about 3 minutes left")
  }

  @Test("the per-section time is the MEAN: a slow section's time is real waiting and counts")
  func paceIsTheMean() {
    // The baseline at 0 has no time of its own, so the rates are 12, 12 and 60.
    let withOutlier = pace([(0, 0), (1, 12), (2, 24), (3, 36), (4, 96)])
    #expect(withOutlier.secondsPerSection() == 28, "(12 + 12 + 60) / 3, not the median 12")
  }

  @Test("a landing that carries two sections counts both")
  func paceSplitsMultiSectionLandings() {
    let pace = pace([(0, 0), (1, 12), (3, 36), (4, 48)])
    #expect(pace.secondsPerSection() == 12)
  }

  @Test("batched sections keep their weight in the mean")
  func paceWeightsBatchedSections() {
    // Three 12 s sections landed as one batch, then one 60 s section: 96 s over four
    // sections is 24, not the mean of two batch votes (36).
    let p = pace([(0, 0), (1, 12), (4, 48), (5, 108)])
    #expect(p.secondsPerSection() == 24)
    #expect(p.remainingText(sectionsDone: 5, sectionsTotal: 20) == "about 6 minutes left")
  }

  @Test("on a skewed document the mean, not the median, is what is left (#2817)")
  func paceMeanNotMedianOnSkew() {
    // Three fast sections then one long one: the long ones carry the time. The mean
    // (1.87 s) projects about six minutes for the 196 left; the median (0.3 s) said one.
    let p = pace([(0, 0), (1, 0.3), (2, 0.6), (3, 0.9), (4, 5.9)])
    #expect(p.remainingText(sectionsDone: 4, sectionsTotal: 200) == "about 6 minutes left")
  }

  /// The 200 `LLM Polish completed` stamps of the founder's 48-minute two-voice run on
  /// 2026-09-13 (20:24:46 to 20:27:08, `app.log`, 1 s resolution), as seconds from the
  /// first. The run's per-call durations (median 0.27 s, mean 0.72 s) come from the same
  /// log lines; they cannot be recovered from these whole-second offsets.
  private static let arianaLandings: [Int] = [
    0, 0, 1, 1, 2, 2, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 8, 9, 10, 10, 10, 10, 11, 11, 12, 12, 13,
    13, 16, 16, 16, 17, 18, 19, 22, 23, 24, 24, 31, 31, 35, 35, 35, 36, 36, 37, 39, 39, 43, 44,
    44, 44, 45, 45, 45, 46, 46, 46, 48, 48, 48, 49, 49, 49, 50, 51, 53, 53, 54, 54, 55, 55, 56,
    57, 57, 61, 61, 61, 61, 62, 62, 65, 66, 66, 66, 68, 68, 69, 70, 70, 70, 74, 75, 75, 76, 76,
    76, 77, 77, 77, 77, 78, 78, 79, 79, 79, 80, 80, 83, 83, 85, 85, 87, 87, 87, 87, 88, 88, 89,
    89, 90, 90, 91, 92, 93, 94, 94, 95, 96, 96, 102, 102, 102, 102, 103, 103, 103, 104, 104,
    104, 108, 108, 109, 109, 109, 110, 110, 111, 112, 112, 112, 113, 113, 114, 114, 116, 116,
    116, 117, 117, 119, 119, 120, 121, 124, 124, 124, 125, 125, 125, 127, 128, 128, 129, 129,
    130, 132, 132, 133, 133, 134, 134, 134, 135, 135, 135, 136, 138, 138, 138, 139, 139, 139,
    140, 140, 140, 140, 141, 141, 142
  ]

  @Test("replayed over a real 200-turn run, the figure tracks what was left (#2817)")
  func paceArianaReplay() {
    let start = Date(timeIntervalSinceReferenceDate: 1_000)
    let total = Self.arianaLandings.count
    func replay(until elapsed: Int) -> (done: Int, text: String?) {
      var p = SectionPace()
      var done = 0
      for (i, offset) in Self.arianaLandings.enumerated() where offset <= elapsed {
        done = i + 1
        p.observe(sectionsDone: done, at: start.addingTimeInterval(Double(offset)))
      }
      return (done, p.remainingText(sectionsDone: done, sectionsTotal: total))
    }
    // 82 s were actually left at 60 s. On this whole-second fixture the old median also
    // printed two minutes here (its zero-length intervals were dropped, which pushed it
    // up); the rows that separate mean from median are the synthetic ones above and 120 s.
    let at60 = replay(until: 60)
    #expect(at60.done == 75)
    #expect(at60.text == "about 2 minutes left")
    // 52 s left at 90 s.
    let at90 = replay(until: 90)
    #expect(at90.done == 122)
    #expect(at90.text == "about a minute left")
    // 22 s left at 120 s; the median printed "about a minute left" here.
    #expect(replay(until: 120).text == "under a minute left")
  }

  @Test("the wording: under a minute, about a minute, about N minutes")
  func paceWording() {
    let p = pace([(0, 0), (1, 12), (2, 24), (3, 36), (4, 48)])
    #expect(p.remainingText(sectionsDone: 4, sectionsTotal: 6) == "under a minute left")
    #expect(p.remainingText(sectionsDone: 4, sectionsTotal: 9) == "about a minute left")
    #expect(p.remainingText(sectionsDone: 4, sectionsTotal: 14) == "about 2 minutes left")
    #expect(p.remainingText(sectionsDone: 4, sectionsTotal: 4) == nil, "nothing left")
  }

  @Test("a count going backwards (a re-polish restarted the numbering) discards the history")
  func paceResetsWhenCountDrops() {
    var p = pace([(0, 0), (1, 12), (2, 24), (3, 36), (4, 48)])
    #expect(p.secondsPerSection() != nil)
    p.observe(sectionsDone: 0, at: Date(timeIntervalSinceReferenceDate: 2_000))
    #expect(p.secondsPerSection() == nil)
    #expect(
      p
        == {
          var fresh = SectionPace()
          fresh.observe(sectionsDone: 0, at: Date(timeIntervalSinceReferenceDate: 2_000))
          return fresh
        }())
  }

  // MARK: - The pulse

  @Test("Reduce Motion parks the lips; otherwise they move")
  func pulseHonoursReduceMotion() {
    #expect(WorkingPulseMark.showsPulse(reduceMotion: true) == false)
    #expect(WorkingPulseMark.showsPulse(reduceMotion: false) == true)
    // The still lips sit at the pulse's own floor, never below it.
    let floor = WorkingPulseMark.restingLevel
    for t in stride(from: 0.0, through: 3.0, by: 0.05) {
      #expect(WorkingPulseMark.level(at: t) >= floor - 0.0001)
      #expect(WorkingPulseMark.level(at: t) <= floor + 0.35 + 0.0001)
    }
  }

  // MARK: - The mark-up colours, one table for both renderers

  @Test(
    "removed is red and struck; changed and added carry the green tint and weight; same is plain")
  func markedUpTextUsesThePalette() {
    let segments: [WordDiff.Segment] = [
      .init(kind: .same, text: "keep", trailing: " "),
      .init(kind: .removed, text: "um", trailing: " "),
      .init(kind: .changed, text: "better", trailing: " "),
      .init(kind: .added, text: "new", trailing: ""),
    ]
    let text = TranscribeFileView.markedUpText(segments)
    struct Marks {
      let fg: Color?
      let bg: Color?
      let struck: Bool
      let bold: Bool
      let ownFont: Bool
    }
    func marks(_ kind: WordDiff.Kind) -> Marks? {
      guard let segment = segments.first(where: { $0.kind == kind }) else { return nil }
      for run in text.runs where String(text[run.range].characters) == segment.text {
        return Marks(
          fg: run.foregroundColor, bg: run.backgroundColor,
          struck: run.strikethroughStyle != nil,
          bold: run.inlinePresentationIntent == .stronglyEmphasized,
          ownFont: run.font != nil)
      }
      return nil
    }
    #expect(marks(.removed)?.fg == MarkUpPalette.removed)
    #expect(marks(.removed)?.fg == Color.stError, "the founder's red")
    // Two-way control on the oracle: distinct dynamic tokens must compare unequal, or the
    // equalities above would pass against any colour.
    #expect(Color.stError != Color.stTextSecondary)
    #expect(marks(.removed)?.fg != Color.stTextSecondary, "the old grey")
    #expect(marks(.removed)?.struck == true)
    #expect(marks(.removed)?.bg == nil)
    for kind in [WordDiff.Kind.changed, .added] {
      #expect(marks(kind)?.bg == MarkUpPalette.changedBackground, "\(kind)")
      #expect(marks(kind)?.fg == MarkUpPalette.changedText, "\(kind)")
      #expect(marks(kind)?.struck == false, "\(kind)")
      #expect(marks(kind)?.bold == true, "\(kind)")
    }
    // No run carries its own font: a run-level `Font` replaced the container's size, so the
    // edited words alone rendered at 13 pt inside 14 pt text (cloud review, PR #2897).
    for kind in [WordDiff.Kind.same, .removed, .changed, .added] {
      #expect(marks(kind)?.ownFont == false, "\(kind)")
    }
    #expect(marks(.same)?.bg == nil)
    #expect(marks(.same)?.struck == false)
  }
}
