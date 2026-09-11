import EnviousWisprCore
import Testing

@testable import EnviousWisprAppKit

/// #2772 finding 12 — the Done screen names the RECORDING, not the file on disk.
///
/// Founder: the title should read "Marketing sync . 4 September 2026", not
/// "import-demo.m4a". A file name is what the filesystem calls a recording; this screen is
/// about the meeting the person just transcribed.
///
/// Product coverage: what fails here is the heading on the screen that hands over the words.
/// `@MainActor` because `TranscribeFileView` is, so its statics are too. Without it the
/// suite compiled and then CRASHED inside the function on Swift 6's runtime executor
/// check — reported as "Crash: xctest at closure #1", which reads like a defect in the
/// string handling and is not one. Every other suite here that touches a view is
/// `@MainActor` for the same reason.
@MainActor
@Suite("Transcribe a File done header (#2772)", .tags(.productOutcome))
struct TranscribeFileDoneHeaderTests {

  @Test(
    "a file name becomes a readable title",
    arguments: [
      ("import-demo.m4a", "Import demo"),
      ("1-emma-chamberlain-like-literally.mp4", "Emma chamberlain like literally"),
      ("marketing_sync.wav", "Marketing sync"),
      ("Board Meeting.mov", "Board Meeting"),
    ])
  func areadableTitle(_ fileName: String, _ expected: String) {
    #expect(TranscribeFileView.readableTitle(fromFileName: fileName) == expected)
  }

  /// **Never blank, whatever the name looks like.** An unnamed document is worse than an ugly
  /// one: the heading is how a person tells two transcripts apart. Every one of these strips
  /// to nothing under the ordinary rules, so each must fall back to the raw name.
  @Test(
    "a name that strips to nothing keeps the raw name",
    arguments: ["1.m4a", "---.wav", ".m4a", "2026.mp3"])
  func neverBlank(_ fileName: String) {
    let title = TranscribeFileView.readableTitle(fromFileName: fileName)
    #expect(!title.isEmpty, "\(fileName) produced an empty title")
  }

  /// The rule is "drop a SHORT leading ordering number", not "drop every leading number".
  ///
  /// The first version dropped every consecutive leading numeric token, so a recording dated
  /// in its own name lost the date and "1984-book-club" lost the book. Found by Codex.
  @Test("meaningful numbers survive, ordering prefixes do not")
  func meaningfulNumbersSurvive() {
    #expect(
      TranscribeFileView.readableTitle(fromFileName: "q3-2026-review.m4a") == "Q3 2026 review")
    #expect(TranscribeFileView.readableTitle(fromFileName: "1-standup.m4a") == "Standup")
    #expect(
      TranscribeFileView.readableTitle(fromFileName: "2026-09-10-board-meeting.m4a")
        == "2026 09 10 board meeting",
      "a date in the name is part of the name")
    #expect(
      TranscribeFileView.readableTitle(fromFileName: "1984-book-club.wav") == "1984 book club",
      "a four-digit leading number is not an ordering prefix")
  }

  /// House rule: no em or en dash in any user-facing string.
  @Test("no title carries an em or en dash")
  func noDashes() {
    for name in ["import-demo.m4a", "a—b.wav", "a–b.wav"] {
      let title = TranscribeFileView.readableTitle(fromFileName: name)
      #expect(!title.contains("\u{2014}") && !title.contains("\u{2013}"), "dash in \(title)")
    }
  }

  /// The marks themselves (#2773): a removed word is struck through, which reads without
  /// colour; an altered or added word carries a background AND weight. A version that used
  /// colour alone would pass a "looks different" check and fail a colour-blind reader.
  @Test("removed words are struck through; altered and added words are highlighted and heavier")
  func markedUpTreatments() {
    let text = TranscribeFileView.markedUpText([
      .init(kind: .same, text: "the", trailing: " "),
      .init(kind: .removed, text: "um", trailing: " "),
      .init(kind: .changed, text: "gonna", trailing: " "),
      .init(kind: .added, text: "morning.", trailing: ""),
    ])
    var runs: [(String, Bool, Bool)] = []
    for run in text.runs {
      let word = String(text[run.range].characters)
      guard !word.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
      runs.append((word, run.strikethroughStyle != nil, run.backgroundColor != nil))
    }
    #expect(runs.map(\.0) == ["the", "um", "gonna", "morning."])
    #expect(runs.map(\.1) == [false, true, false, false], "strikethrough marks exactly the removed word")
    #expect(runs.map(\.2) == [false, false, true, true], "the highlight marks exactly the altered and added words")
    // And the weight, which is what makes the highlight readable without its colour.
    let weighted = text.runs
      .filter { !String(text[$0.range].characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .map { $0.swiftUI.font != nil }
    #expect(weighted == [false, false, true, true])
    // What a screen reader gets, since the marks say nothing aloud.
    #expect(
      TranscribeFileView.markedUpAccessibilityText([
        .init(kind: .same, text: "the", trailing: " "),
        .init(kind: .removed, text: "um", trailing: " "),
      ]) == "the Removed: um. ")
  }
}
