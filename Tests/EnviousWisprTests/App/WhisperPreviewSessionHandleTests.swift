import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation
import Testing

@testable import EnviousWisprLivePreview
@testable import EnviousWisprWhisperPreviewAdapter

/// #2108 — what the preview session handle delivers, and how big it can get.
@Suite struct WhisperPreviewSessionHandleTests {


  /// Wait for the publisher task to deliver, on a bounded real-time poll.
  ///
  /// `Task.yield()` alone is not enough: the publisher consumes an `AsyncStream`
  /// on its own task, and yielding from the test does not guarantee it is
  /// scheduled. An earlier version of these tests yielded 2,000 times and
  /// delivered nothing — and the empty-hypothesis test PASSED anyway, because
  /// "no empty string arrived" is trivially true when nothing arrives at all.
  private func waitForDelivery(_ box: Box, count: Int = 1) async {
    for _ in 0..<600 where box.delivered.count < count {
      // deadline-fallback: bounded poll around a cross-task delivery that has no
      // synchronous signal to wait on.
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  final class Box: @unchecked Sendable {
    var delivered: [String] = []
  }

  private func word(_ canonical: String, alias: String) -> CustomWord {
    CustomWord(canonical: canonical, aliases: [alias])
  }

  /// The bound must survive CORRECTION, not just precede it.
  ///
  /// A custom word whose canonical is longer than the alias it replaces EXPANDS
  /// the text, so a tail already at the limit can cross it on the way out. The
  /// Apple producer applies the bound on both sides; the first version of this
  /// engine ported only the inner half, and cloud review caught it.
  @Test("a custom word that expands the text cannot push it past the bound")
  func correctionCannotExceedTheBound() async {
    let alias = "qtx"
    let canonical = String(repeating: "Qualtrics", count: 12)  // 108 chars for 3
    let lookups = WordCorrector.buildLookups(words: [word(canonical, alias: alias)])

    let box = Box()
    let handle = WhisperPreviewSessionHandle(
      lookups: lookups, onText: { box.delivered.append($0) })

    // Just over the limit, so the INNER bound trims to exactly the cap, with a
    // modest number of expanding aliases scattered through filler. An earlier
    // version packed the whole 2,000 characters with aliases; correction over
    // 500 matches did not finish inside the poll budget, which looked like a
    // delivery failure and was really the fixture being unreasonable.
    var text = ""
    while text.count < LivePreviewTextBound.maxCharacters + 100 {
      text += "\(alias) filler filler filler filler filler filler filler "
    }
    handle.enqueue(text)

    await waitForDelivery(box)
    await handle.end()

    #expect(box.delivered.first != nil, "control: something must have been delivered")
    if let text = box.delivered.first {
      // Control: correction genuinely expanded it, so the assertion below is
      // about the bound rather than about a string that was always short.
      #expect(text.contains("Qualtrics"), "control: the custom word must have been applied")
      #expect(
        text.count <= LivePreviewTextBound.maxCharacters,
        "correction expanded the text past the producer bound: \(text.count) chars")
    }
  }

  /// Empty hypotheses must not reach the display: blanking the pill mid-sentence
  /// reads to a user as the app losing what they just said.
  @Test("an empty hypothesis is not delivered")
  func emptyHypothesisIsNotDelivered() async {
    let box = Box()
    let handle = WhisperPreviewSessionHandle(
      lookups: nil, onText: { box.delivered.append($0) })

    handle.enqueue("")
    handle.enqueue("real words")
    await waitForDelivery(box)
    await handle.end()

    // CONTROL FIRST. Without it this test passes when nothing is delivered at
    // all, which is exactly how it passed before the delivery wait was fixed.
    #expect(
      box.delivered.contains("real words"),
      "control: a real hypothesis must arrive, or the assertion below is vacuous")
    #expect(!box.delivered.contains(""), "an empty string must never reach the display")
  }

  /// `end()` is idempotent AND awaitable: a second caller waits for the same
  /// teardown rather than returning early. An early return would let the
  /// recognizer open a new decode loop over the shared WhisperKit instance while
  /// the old session's non-cancellable transcribe was still running — the
  /// decoder-state corruption `WhisperKitStreamingSession.cancel()` documents.
  @Test("end is safe and complete when called twice, from two callers")
  func endIsIdempotentAndAwaitable() async {
    let box = Box()
    let handle = WhisperPreviewSessionHandle(
      lookups: nil, onText: { box.delivered.append($0) })

    async let first: Void = handle.end()
    async let second: Void = handle.end()
    _ = await (first, second)

    // Both returned; nothing hung and nothing crashed. A post-end enqueue must
    // also not deliver, since the stream is finished.
    handle.enqueue("after the end")
    // deadline-fallback: give any (incorrect) delivery a real chance to land
    // before asserting it did not.
    try? await Task.sleep(for: .milliseconds(50))
    #expect(!box.delivered.contains("after the end"))
  }
}
