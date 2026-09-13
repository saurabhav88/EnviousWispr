import Foundation
import Testing

@testable import EnviousWisprCore

/// #2851 chunk 1's executable premise check (plan §3d step 1): replay the aligner over a REAL
/// stored row (the founder's 48-minute interview, 372 turns, whose turns were cleaned by the
/// old per-turn pass) and print agreement and fallback counts. The old per-turn text is a
/// comparison BASELINE for text agreement, never an ownership oracle. Gated on the row being
/// present on this Mac; CI has no such file and skips.
@Suite("TurnTextAligner replay on a stored row", .tags(.productOutcome))
struct TurnTextAlignerReplayTests {

  static let rowPath: String? = {
    let dir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/EnviousWispr/transcripts")
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
      return nil
    }
    // The largest labeled row: the 48-minute interview when it is present.
    var best: (path: String, turns: Int)?
    for file in files where file.hasSuffix(".json") {
      let path = dir.appendingPathComponent(file).path
      guard let data = FileManager.default.contents(atPath: path),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let turns = json["turns"] as? [[String: Any]], turns.count >= 100
      else { continue }
      if best == nil || turns.count > best!.turns { best = (path, turns.count) }
    }
    return best?.path
  }()

  @Test(
    "replay: whole-document alignment over the stored 48-minute row",
    .enabled(if: TurnTextAlignerReplayTests.rowPath != nil))
  func replayStoredRow() throws {
    let path = try #require(Self.rowPath)
    let data = try #require(FileManager.default.contents(atPath: path))
    let row = try JSONDecoder().decode(Transcript.self, from: data)
    let turns = try #require(row.turns)
    let cleaned = try #require(row.polishedText ?? row.processedText)

    let passage = TurnTextAligner.Passage(
      placement: .placed(0..<row.text.utf16.count), cleaned: cleaned, wasPolished: true)
    let started = Date()
    let outcome = TurnTextAligner.align(
      rawText: row.text, passages: [passage], turns: turns, language: row.language)
    let ms = Int(Date().timeIntervalSince(started) * 1000)

    #expect(outcome.texts.count == turns.count)
    var aligned = 0
    var byReason: [TurnTextAligner.Fallback: Int] = [:]
    var agree = 0
    var compared = 0
    var disagreements: [(String, String, String)] = []
    for text in outcome.texts {
      if let reason = outcome.fallbacks[text.turnID] {
        byReason[reason, default: 0] += 1
        continue
      }
      aligned += 1
      guard let mine = text.processedText,
        let old = turns.first(where: { $0.id == text.turnID })?.processedText
      else { continue }
      compared += 1
      let a = WordDiff.tokenize(mine).map(\.key)
      let b = WordDiff.tokenize(old).map(\.key)
      if a == b {
        agree += 1
      } else if disagreements.count < 8 {
        disagreements.append((text.turnID, mine, old))
      }
    }
    print(
      "[TurnAlign replay] turns=\(turns.count) aligned=\(aligned) uncut_boundary=\(byReason[.boundary] ?? 0) uncut_unplaced=\(byReason[.unplaced] ?? 0) uncut_unreached=\(byReason[.unreached] ?? 0) uncut_emptied=\(byReason[.emptied] ?? 0) ms=\(ms)"
    )
    print(
      "[TurnAlign replay] text agreement with the old per-turn cleanup (same word keys): \(agree)/\(compared)"
    )
    for (id, mine, old) in disagreements {
      print(
        "[TurnAlign replay] differs \(id)\n  aligned: \(mine.prefix(160))\n  old:     \(old.prefix(160))"
      )
    }
    #expect(aligned > 0, "the replay aligned nothing; the premise is not established")
  }
}
