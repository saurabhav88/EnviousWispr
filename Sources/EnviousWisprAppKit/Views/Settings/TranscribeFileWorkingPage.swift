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

  static let engineNames: [ASRBackendType: String] = [.parakeet: "Fast", .whisperKit: "All Languages"]

  /// The counts, top to bottom, in the order the run produces them.
  ///
  /// - `transcribedSeconds` / `fileSeconds`: minutes reached over the file's length, from the
  ///   transcribing fraction while the engine runs; the whole length once the transcript is in.
  /// - `speakersFound`: the coordinator's post-assembly count (`speakersFoundForDisplay`:
  ///   labeled gives the count, a single voice is 1, a failed or downgraded step is unknown).
  /// - `sectionsDone` / `sectionsTotal`: the cleaning counter.
  /// - `words`: the raw transcript's word count once it is in hand.
  static func make(
    fileName: String, fileSeconds: Double, engine: ASRBackendType, polisher: LLMProvider?,
    estimate: String, transcribingFraction: Double?, transcriptLanded: Bool,
    speakersFound: Int?, sectionsDone: Int?, sectionsTotal: Int?, words: Int?
  ) -> WorkingPageModel {
    let totalMinutes = max(1, Int((fileSeconds / 60).rounded()))
    let transcribed: String?
    if transcriptLanded {
      transcribed = "\(totalMinutes) of \(totalMinutes) min"
    } else if let fraction = transcribingFraction, fileSeconds > 0 {
      let reached = min(totalMinutes, Int(min(max(fraction, 0), 1) * fileSeconds / 60))
      transcribed = "\(reached) of \(totalMinutes) min"
    } else {
      transcribed = nil
    }
    let speakerValue = speakersFound.map { "\($0)" }
    let sections: String?
    if let sectionsTotal, sectionsTotal > 0 {
      sections = "\(min(max(sectionsDone ?? 0, 0), sectionsTotal)) of \(sectionsTotal)"
    } else {
      sections = nil
    }
    let wordsValue = words.map { $0.formatted(.number.grouping(.automatic)) }
    return WorkingPageModel(
      summary: Summary(
        fileName: fileName, length: FileImportCoordinator.durationText(fileSeconds),
        engine: engineNames[engine] ?? engine.rawValue,
        polisher: (polisher ?? LLMProvider.none).displayName,
        estimate: estimate),
      counts: [
        Count(kind: .transcribed, label: "Transcribed", value: transcribed),
        Count(kind: .speakers, label: "Speakers found", value: speakerValue),
        Count(kind: .sections, label: "Sections cleaned", value: sections),
        Count(kind: .words, label: "Words so far", value: wordsValue),
      ])
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
          sectionTitle("This file")
          row("File", model.summary.fileName)
          row("Length", model.summary.length)
          row("Transcription", model.summary.engine)
          row("Polish", model.summary.polisher)
          row("Estimate", model.summary.estimate)
        }
        .padding(.horizontal, SettingsLayout.rowPaddingH)
        .padding(.vertical, SettingsLayout.rowPaddingV)
      }
      BrandedSection {
        VStack(alignment: .leading, spacing: 8) {
          sectionTitle("So far")
          ForEach(model.counts) { count in
            row(count.label, count.value ?? "–")
              .accessibilityElement(children: .ignore)
              .accessibilityLabel(count.value.map { "\(count.label), \($0)" } ?? "\(count.label), not yet known")
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
