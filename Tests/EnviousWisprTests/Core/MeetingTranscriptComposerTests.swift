import Foundation
import Testing

@testable import EnviousWisprCore

/// #3972: when these fail, an EnviousMeet transcript shows a word under the wrong person, in
/// the wrong order, twice (echo), or not at all.
@Suite("MeetingTranscriptComposer", .tags(.productOutcome))
struct MeetingTranscriptComposerTests {

  /// Builds a piece from words separated by single spaces, each with its own time.
  private func piece(_ words: [(String, Int?, Int?)], start: Int, end: Int) -> MeetingTrackPiece {
    var text = ""
    var timings: [ASRWordTiming] = []
    for (word, s, e) in words {
      if !text.isEmpty { text += " " }
      let lower = text.utf16.count
      text += word
      timings.append(
        ASRWordTiming(word: word, range: lower..<text.utf16.count, startMs: s, endMs: e))
    }
    return MeetingTrackPiece(text: text, startMs: start, endMs: end, words: timings)
  }

  private func slice(_ range: Range<Int>, of text: String) -> String {
    let lower = String.Index(utf16Offset: range.lowerBound, in: text)
    let upper = String.Index(utf16Offset: range.upperBound, in: text)
    return String(text[lower..<upper])
  }

  @Test("a call: the far side and the microphone voice interleave by time, the mic voice is You")
  func callInterleavesAndNamesYou() {
    let call = MeetingTrackInput(
      kind: .callSound,
      pieces: [
        piece(
          [("Can", 0, 200), ("you", 200, 400), ("hear", 400, 600), ("me", 600, 800)], start: 0,
          end: 900),
        piece(
          [("Great", 5000, 5400), ("lets", 5400, 5700), ("start", 5700, 6000)], start: 5000,
          end: 6100),
      ],
      speakerSegments: [SpeakerSegment(speakerId: "S1", startMs: 0, endMs: 6100, quality: 1)])
    let mic = MeetingTrackInput(
      kind: .microphone,
      pieces: [
        piece(
          [("Yes", 2000, 2300), ("loud", 2300, 2600), ("and", 2600, 2800), ("clear", 2800, 3100)],
          start: 2000, end: 3200)
      ],
      speakerSegments: [SpeakerSegment(speakerId: "S1", startMs: 2000, endMs: 3200, quality: 1)])

    let result = MeetingTranscriptComposer.compose(tracks: [call, mic])

    #expect(
      result.turns.map { slice($0.originalTextRange, of: result.text) } == [
        "Can you hear me", "Yes loud and clear", "Great lets start",
      ])
    #expect(result.turns.map(\.speakerId) == ["sys:S1", "mic:S1", "sys:S1"])
    #expect(result.speakerNames["mic:S1"] == "You")
    #expect(result.speakerNames["sys:S1"] == "Speaker 1")
    #expect(result.speakerCount == 2)
    #expect(Set(result.turns.map(\.id)).count == result.turns.count)
    #expect(result.echoTurnIDs.isEmpty)
  }

  @Test("in person: two voices on the microphone only are Speaker 1 and Speaker 2, never You")
  func inPersonTwoSpeakers() {
    let mic = MeetingTrackInput(
      kind: .microphone,
      pieces: [
        piece([("Morning", 0, 500), ("everyone", 500, 1000)], start: 0, end: 1100),
        piece([("Hi", 1500, 1800), ("there", 1800, 2100)], start: 1500, end: 2200),
      ],
      speakerSegments: [
        SpeakerSegment(speakerId: "S1", startMs: 0, endMs: 1100, quality: 1),
        SpeakerSegment(speakerId: "S2", startMs: 1400, endMs: 2200, quality: 1),
      ])
    let result = MeetingTranscriptComposer.compose(tracks: [mic])
    #expect(result.speakerNames["mic:S1"] == "Speaker 1")
    #expect(result.speakerNames["mic:S2"] == "Speaker 2")
    #expect(!result.speakerNames.values.contains("You"))
    #expect(result.speakerCount == 2)
  }

  @Test("echo: the repeated call sound is hidden and the user's own reply right after it stays visible")
  func echoHidesOnlyTheRepeat() {
    let call = MeetingTrackInput(
      kind: .callSound,
      pieces: [piece([("the", 1000, 1100), ("budget", 1100, 1500), ("is", 1500, 1600), ("approved", 1600, 2000)], start: 1000, end: 2100)],
      speakerSegments: [SpeakerSegment(speakerId: "S1", startMs: 1000, endMs: 2100, quality: 1)])
    let mic = MeetingTrackInput(
      kind: .microphone,
      pieces: [
        // The Mac speakers playing the call into the microphone, 150 ms late, then the user's
        // own reply 850 ms later (inside one speaker turn: no pause long enough to split).
        piece([("the", 1150, 1250), ("budget", 1250, 1650), ("is", 1650, 1750), ("approved", 1750, 2150), ("yeah", 3000, 3300)], start: 1150, end: 3400)
      ],
      speakerSegments: [SpeakerSegment(speakerId: "S1", startMs: 1100, endMs: 3400, quality: 1)])
    let result = MeetingTranscriptComposer.compose(tracks: [call, mic])
    let shown = MeetingTranscriptProjection.plainText(
      text: result.text, turns: result.turns, speakerNames: [:],
      echoTurnIDs: Set(result.echoTurnIDs), showEcho: false)
    #expect(shown == "the budget is approved\n\nyeah")
    let all = MeetingTranscriptProjection.plainText(
      text: result.text, turns: result.turns, speakerNames: [:],
      echoTurnIDs: Set(result.echoTurnIDs), showEcho: true)
    #expect(all == "the budget is approved\n\nthe budget is approved\n\nyeah")
  }

  /// The call says `call` (one word per 300 ms from 1000 ms); the microphone says `mic` (one
  /// word per 300 ms from `micStart`). Returns the visible text and the echo-shown text.
  private func echoCase(call: [String], mic: [String], micStart: Int = 1150) -> (visible: String, all: String) {
    func words(_ list: [String], from t0: Int) -> [(String, Int?, Int?)] {
      list.enumerated().map { ($0.element, t0 + $0.offset * 300, t0 + $0.offset * 300 + 250) }
    }
    let callPiece = piece(words(call, from: 1000), start: 1000, end: 1000 + call.count * 300)
    let micPiece = piece(words(mic, from: micStart), start: micStart, end: micStart + mic.count * 300)
    let result = MeetingTranscriptComposer.compose(tracks: [
      MeetingTrackInput(kind: .callSound, pieces: [callPiece], speakerSegments: []),
      MeetingTrackInput(kind: .microphone, pieces: [micPiece], speakerSegments: []),
    ])
    let echo = Set(result.echoTurnIDs)
    let visible = MeetingTranscriptProjection.plainText(
      text: result.text, turns: result.turns.filter { $0.speakerId.hasPrefix("mic") }, speakerNames: [:],
      echoTurnIDs: echo, showEcho: false)
    let all = MeetingTranscriptProjection.plainText(
      text: result.text, turns: result.turns.filter { $0.speakerId.hasPrefix("mic") }, speakerNames: [:],
      echoTurnIDs: echo, showEcho: true)
    return (visible, all)
  }

  @Test("one call word pairs with one microphone word: 'no no no no' is never hidden by one 'no'")
  func pairingIsOneToOne() {
    let r = echoCase(call: ["no"], mic: ["no", "no", "no", "no"])
    #expect(r.visible == "no no no no")
  }

  @Test("an exact three-word echo is hidden (R27 minimum), and the toggle shows it")
  func exactThreeWordEchoIsHidden() {
    let r = echoCase(call: ["see", "you", "tomorrow"], mic: ["see", "you", "tomorrow"])
    #expect(r.visible.isEmpty)
    #expect(r.all == "see you tomorrow")
  }

  @Test("an ASR variant inside an echo stays part of it; a two-word insertion of the user's own ends it")
  func unpairedRunsInsideEcho() {
    let variant = echoCase(
      call: ["the", "budget", "is", "approved"], mic: ["the", "budget", "uh", "is", "approved"])
    #expect(variant.visible.isEmpty)
    let insertion = echoCase(
      call: ["the", "budget", "is", "approved"],
      mic: ["the", "budget", "not", "yet", "is", "approved"])
    #expect(insertion.visible == "the budget not yet is approved")
  }

  @Test("a sentence sharing two words with the call stays one visible line")
  func sharedWordsDoNotFragment() {
    let r = echoCase(
      call: ["the", "budget", "is", "approved"], mic: ["so", "the", "budget", "looks", "fine"],
      micStart: 2500)
    #expect(r.visible == "so the budget looks fine")
  }

  @Test("words far apart in time never pair, even with equal text")
  func pairingNeedsTimeLocality() {
    let r = echoCase(call: ["see", "you", "tomorrow"], mic: ["see", "you", "tomorrow"], micStart: 30_000)
    #expect(r.visible == "see you tomorrow")
  }

  @Test("no speaker segments: every word is kept under the track's fallback speaker")
  func fallbackSpeakersKeepEveryWord() {
    let call = MeetingTrackInput(
      kind: .callSound,
      pieces: [piece([("Alpha", 0, 300), ("bravo", 300, 600)], start: 0, end: 700)],
      speakerSegments: [])
    let mic = MeetingTrackInput(
      kind: .microphone,
      pieces: [piece([("Charlie", 1000, 1300)], start: 1000, end: 1400)],
      speakerSegments: [])
    let result = MeetingTranscriptComposer.compose(tracks: [call, mic])
    #expect(
      result.turns.map(\.speakerId) == [
        MeetingTranscriptComposer.fallbackCallSpeakerID,
        MeetingTranscriptComposer.fallbackMicrophoneSpeakerID,
      ])
    #expect(result.speakerNames[MeetingTranscriptComposer.fallbackCallSpeakerID] == "Call")
    #expect(result.speakerNames[MeetingTranscriptComposer.fallbackMicrophoneSpeakerID] == "You")
    #expect(result.text.contains("Alpha bravo"))
    #expect(result.text.contains("Charlie"))
  }

  @Test("untimed words inside a piece get times between their neighbours, inside the piece")
  func untimedWordsAreInterpolated() {
    let p = piece(
      [("one", 0, 100), ("two", nil, nil), ("three", nil, nil), ("four", 900, 1000)], start: 0,
      end: 1000)
    let timed = MeetingTranscriptComposer.interpolatedTimes(for: p)
    #expect(timed.count == 4)
    #expect(timed.allSatisfy { $0.startMs != nil && $0.endMs != nil })
    let starts = timed.compactMap(\.startMs)
    #expect(starts == starts.sorted())
    #expect(timed[1].startMs! >= 100 && timed[2].endMs! <= 900)
  }

  @Test("an empty meeting composes to nothing and zero speakers")
  func emptyMeeting() {
    let result = MeetingTranscriptComposer.compose(tracks: [
      MeetingTrackInput(kind: .microphone, pieces: [], speakerSegments: [])
    ])
    #expect(result.text.isEmpty)
    #expect(result.turns.isEmpty)
    #expect(result.speakerCount == 0)
  }

  @Test("one speaker's two lines with the other track between them stay two lines in time order")
  func pauseSplitsInterleave() {
    let call = MeetingTrackInput(
      kind: .callSound,
      pieces: [piece([("first", 0, 300), ("line", 300, 600)], start: 0, end: 700),
               piece([("second", 4000, 4300), ("line", 4300, 4600)], start: 4000, end: 4700)],
      speakerSegments: [SpeakerSegment(speakerId: "S1", startMs: 0, endMs: 4700, quality: 1)])
    let mic = MeetingTrackInput(
      kind: .microphone,
      pieces: [piece([("between", 2000, 2400)], start: 2000, end: 2500)],
      speakerSegments: [SpeakerSegment(speakerId: "S1", startMs: 2000, endMs: 2500, quality: 1)])
    let result = MeetingTranscriptComposer.compose(tracks: [call, mic])
    #expect(result.turns.map { slice($0.originalTextRange, of: result.text) } == ["first line", "between", "second line"])
  }

  @Test("equal start times put the call sound first, every turn is a deliberate polish bypass")
  func equalStartsAndPolishFlag() {
    let call = MeetingTrackInput(
      kind: .callSound, pieces: [piece([("hello", 1000, 1300)], start: 1000, end: 1400)],
      speakerSegments: [])
    let mic = MeetingTrackInput(
      kind: .microphone, pieces: [piece([("hi", 1000, 1200)], start: 1000, end: 1300)],
      speakerSegments: [])
    let result = MeetingTranscriptComposer.compose(tracks: [mic, call])
    #expect(result.turns.first?.speakerId == MeetingTranscriptComposer.fallbackCallSpeakerID)
    #expect(result.turns.allSatisfy { $0.wasPolished })
  }

  /// Reference answer for small inputs: the textbook full-table longest common subsequence
  /// length under the same pairing condition. Independent of the composer's sparse search.
  private func referencePairCount(
    _ a: [(token: String, time: Int)], _ b: [(token: String, time: Int)], lag: Int
  ) -> Int {
    var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
    for i in stride(from: a.count - 1, through: 0, by: -1) {
      for j in stride(from: b.count - 1, through: 0, by: -1) {
        let pairs = !a[i].token.isEmpty && a[i].token == b[j].token && abs(a[i].time - b[j].time) <= lag
        table[i][j] = pairs ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
      }
    }
    return table[0][0]
  }

  @Test("the sparse pairing finds as many pairs as the full-table answer on 300 random cases")
  func sparsePairingMatchesReference() {
    var rng = SystemRandomNumberGenerator()
    let vocabulary = ["no", "yes", "the", "budget", "ok", ""]
    for _ in 0..<300 {
      func words(_ n: Int) -> [(token: String, time: Int)] {
        var t = Int.random(in: 0...2000, using: &rng)
        return (0..<n).map { _ in
          t += Int.random(in: 100...900, using: &rng)
          return (vocabulary.randomElement(using: &rng)!, t)
        }
      }
      let a = words(Int.random(in: 0...25, using: &rng))
      let b = words(Int.random(in: 0...25, using: &rng))
      let lag = Int.random(in: 0...3000, using: &rng)
      let paired = MeetingTranscriptComposer.pairedPositions(a, b, maxLagMs: lag)
      #expect(paired.filter { $0 }.count == referencePairCount(a, b, lag: lag), "a=\(a) b=\(b) lag=\(lag)")
    }
  }

  @Test("a 27,000-word lecture heard on both tracks as one unbroken turn is hidden as echo")
  func longContinuousEchoStaysBounded() {
    // One word every 300 ms for 8,100 s, split into 45 pieces with no pause anywhere; the
    // microphone hears every call word 150 ms later. A full table here would be 5.8 GB.
    let count = 27_000
    let perPiece = 600
    let vocabulary = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel"]
    func track(_ kind: MeetingTrackKind, offset: Int) -> MeetingTrackInput {
      let pieces = stride(from: 0, to: count, by: perPiece).map { first in
        let range = first..<min(first + perPiece, count)
        let words = range.map { k in (vocabulary[k % vocabulary.count], k * 300 + offset, k * 300 + offset + 250) }
        return piece(words, start: range.lowerBound * 300 + offset, end: range.upperBound * 300 + offset)
      }
      return MeetingTrackInput(kind: kind, pieces: pieces, speakerSegments: [])
    }
    let clock = ContinuousClock()
    let started = clock.now
    let result = MeetingTranscriptComposer.compose(tracks: [
      track(.callSound, offset: 0), track(.microphone, offset: 150),
    ])
    let elapsed = clock.now - started
    print("longContinuousEchoStaysBounded: compose took \(elapsed)")
    let visible = MeetingTranscriptProjection.plainText(
      text: result.text, turns: result.turns.filter { $0.speakerId.hasPrefix("mic") },
      speakerNames: [:], echoTurnIDs: Set(result.echoTurnIDs), showEcho: false)
    #expect(visible.isEmpty)
    #expect(!result.echoTurnIDs.isEmpty)
  }
}
