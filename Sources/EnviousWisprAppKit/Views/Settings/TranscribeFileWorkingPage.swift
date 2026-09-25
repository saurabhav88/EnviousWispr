import EnviousWisprCore
import Foundation
import SwiftUI

// #2918 (founder, 2026-09-13 23:16): "We have so much dead space now once the actual file
// processing starts. Let's use all that dead space." The Working step is a full page: the step
// list with its bars at the top, a summary of the file under it, then the live counts as the
// run learns them. No transcript words while it runs (#2817's "hide the work" stands): the
// page shows what the run knows about itself.

/// Everything on the Working page below the step list, as a pure value: the file summary
/// (fixed for the run) and the live counts (each one a value the coordinator already
/// holds, or the progress plumbing adds). Every number is either known or absent, never
/// invented: a count the run has not reached yet is `nil` and the row shows a dash.
struct WorkingPageModel: Equatable {
  struct Summary: Equatable {
    let fileName: String
    /// "48 min" / "1 hr 12 min", the coordinator's own duration text.
    let length: String
    /// "Fast" / "All Languages".
    let engine: String
    /// The polisher's display name, or "None".
    let polisher: String
    /// The pre-run line, "about 3 minutes".
    let estimate: String
  }

  struct Count: Equatable, Identifiable {
    enum Kind: Equatable { case transcribed, speakers, sections, words }
    let kind: Kind
    let label: String
    /// "12 of 100 min", "2", "8 of 14", "1,204", or nil before the run knows.
    let value: String?
    var id: Kind { kind }
  }

  let summary: Summary
  let counts: [Count]

  /// The engine's name on Transcribe a File. Exhaustive, so a new engine must be named here.
  static func engineName(_ backend: ASRBackendType) -> String {
    switch backend {
    case .parakeet:
      return String(
        localized: "Fast", comment: "Transcribe a File: the Parakeet transcription engine's name.")
    case .whisperKit:
      return String(
        localized: "All Languages",
        comment: "Transcribe a File: the WhisperKit transcription engine's name.")
    }
  }

  /// The counts, top to bottom, in the order the run produces them.
  ///
  /// - `transcribedSeconds` / `fileSeconds`: minutes reached over the file's length, from the
  ///   transcribing fraction while the engine runs; the whole length once the transcript is in.
  /// - `speakersFound`: the coordinator's post-assembly count (`speakersFoundForDisplay`:
  ///   labeled gives the count, a single voice is 1, a failed or downgraded step is unknown).
  /// - `sectionsDone` / `sectionsTotal`: the cleaning counter.
  /// - `words`: the raw transcript's word count once it is in hand.
  static func make(
    fileName: String, fileSeconds: Double, engine: ASRBackendType, polisher: LLMProvider,
    estimate: String, transcribingFraction: Double?, transcriptLanded: Bool,
    speakersFound: Int?, sectionsDone: Int?, sectionsTotal: Int?, words: Int?
  ) -> WorkingPageModel {
    // The same whole minutes the Length row shows (`durationText`), so "1 of 1 min" sits
    // under "1 min" for a 90-second file. Under a minute the count is the length itself
    // once the transcript is in, and nothing before.
    let totalMinutes = FileImportCoordinator.wholeMinutes(fileSeconds)
    let transcribed: String?
    if transcriptLanded {
      transcribed =
        totalMinutes > 0
        ? minutesOf(totalMinutes, totalMinutes) : FileImportCoordinator.durationText(fileSeconds)
    } else if let fraction = transcribingFraction, totalMinutes > 0 {
      let reached = min(totalMinutes, Int(min(max(fraction, 0), 1) * fileSeconds / 60))
      transcribed = minutesOf(reached, totalMinutes)
    } else {
      transcribed = nil
    }
    let speakerValue = speakersFound.map { "\($0)" }
    let sections: String?
    if let sectionsTotal, sectionsTotal > 0 {
      sections = String(
        localized:
          "\(String(min(max(sectionsDone ?? 0, 0), sectionsTotal))) of \(String(sectionsTotal))",
        comment:
          "Transcribe a File, Working page: sections cleaned. The first %@ is done, the second the total."
      )
    } else {
      sections = nil
    }
    let wordsValue = words.map { $0.formatted(.number.grouping(.automatic)) }
    return WorkingPageModel(
      summary: Summary(
        fileName: fileName, length: FileImportCoordinator.durationText(fileSeconds),
        engine: engineName(engine),
        polisher: polisher.displayName,
        estimate: estimate),
      counts: [
        Count(
          kind: .transcribed,
          label: String(
            localized: "Transcribed",
            comment: "Transcribe a File, Working page: a live count's label."), value: transcribed),
        Count(
          kind: .speakers,
          label: String(
            localized: "Speakers found",
            comment: "Transcribe a File, Working page: a live count's label."), value: speakerValue),
        Count(
          kind: .sections,
          label: String(
            localized: "Sections cleaned",
            comment: "Transcribe a File, Working page: a live count's label."), value: sections),
        Count(
          kind: .words,
          label: String(
            localized: "Words so far",
            comment: "Transcribe a File, Working page: a live count's label."), value: wordsValue),
      ])
  }

  /// "12 of 100 min": minutes transcribed over the file's whole minutes.
  static func minutesOf(_ reached: Int, _ total: Int) -> String {
    String(
      localized: "\(String(reached)) of \(String(total)) min",
      comment:
        "Transcribe a File, Working page: minutes transcribed. The first %@ is done, the second the total; min abbreviates minutes."
    )
  }
}

/// The page body under the step card: the file summary and the live counts, two quiet
/// sections in the wizard's own `BrandedSection` treatment. Nothing here animates; the
/// numbers change when the run learns them.
struct TranscribeFileWorkingPage: View {
  let model: WorkingPageModel

  var body: some View {
    VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
      BrandedSection {
        VStack(alignment: .leading, spacing: 8) {
          sectionTitle(
            String(
              localized: "This file",
              comment:
                "Transcribe a File, Working page: heading of the file summary, shown in capitals."))
          row(
            String(
              localized: "File",
              comment: "Transcribe a File, Working page: a row label in the file summary."),
            model.summary.fileName)
          row(
            String(
              localized: "Length",
              comment: "Transcribe a File, Working page: a row label in the file summary."),
            model.summary.length)
          row(
            String(
              localized: "Transcription",
              comment:
                "Transcribe a File, Working page: a row label in the file summary. The transcription engine."
            ), model.summary.engine)
          row(
            String(
              localized: "transcribeFile.summary.polish", defaultValue: "Polish",
              comment:
                "Transcribe a File, Working page: a row label in the file summary: the AI cleanup engine. Polish means cleanup, never the Polish language."
            ), model.summary.polisher)
          row(
            String(
              localized: "Estimate",
              comment:
                "Transcribe a File, Working page: a row label in the file summary. How long the run should take."
            ), model.summary.estimate)
        }
        .padding(.horizontal, SettingsLayout.rowPaddingH)
        .padding(.vertical, SettingsLayout.rowPaddingV)
      }
      BrandedSection {
        VStack(alignment: .leading, spacing: 8) {
          sectionTitle(
            String(
              localized: "So far",
              comment:
                "Transcribe a File, Working page: heading of the live counts, shown in capitals."))
          ForEach(model.counts) { count in
            row(count.label, count.value ?? "–")
              .accessibilityElement(children: .ignore)
              .accessibilityLabel(
                count.value.map {
                  String(
                    localized: "\(count.label), \($0)",
                    comment:
                      "VoiceOver, Transcribe a File: a live count. The first %@ is its label, the second its value."
                  )
                }
                  ?? String(
                    localized: "\(count.label), not yet known",
                    comment:
                      "VoiceOver, Transcribe a File: a live count with no value yet. %@ is its label."
                  ))
          }
        }
        .padding(.horizontal, SettingsLayout.rowPaddingH)
        .padding(.vertical, SettingsLayout.rowPaddingV)
      }
    }
  }

  private func sectionTitle(_ text: String) -> some View {
    Text(text.uppercased())
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(Color.stTextSecondary)
      .tracking(0.6)
  }

  private func row(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(label)
        .font(.system(size: 13))
        .foregroundStyle(Color.stTextSecondary)
        .frame(width: 130, alignment: .leading)
      Text(value)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Color.stTextBody)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 0)
    }
  }
}
