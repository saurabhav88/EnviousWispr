import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore
@testable import EnviousWisprLivePreview

/// #3973 plan §3.5, §7: what History says about a meeting's live words. When these fail, a
/// meeting says "No words yet." beside a reason there will be none, repeats one reason twice,
/// says the recording stopped when only live words did, or names a remedy that does not exist.
@MainActor
@Suite("Meeting live words presentation (#3973)", .tags(.productOutcome), .timeLimit(.minutes(1)))
struct MeetingLiveWordsPresentationTests {
  typealias P = MeetingsPresentation
  typealias Status = MeetingLiveWords.Status

  static let intro = "Live words, as people speak. The full transcript comes after the meeting."
  static let removal = "Live words stopped while the Universal engine is being removed."
  static let skipped = "Some live words were skipped. The full transcript comes after the meeting."
  static let echo = "Echo is hidden when the meeting ends."

  static func live(
    _ mic: Status?, _ call: Status?, dropped: Set<MeetingTrackKind> = [],
    lines: [LiveWordsAssembler.Line] = []
  ) -> MeetingLiveWords.Transcript {
    var tracks: [MeetingTrackKind: MeetingLiveWords.TrackState] = [:]
    if let mic {
      tracks[.microphone] = .init(status: mic, droppedAudio: dropped.contains(.microphone))
    }
    if let call {
      tracks[.callSound] = .init(status: call, droppedAudio: dropped.contains(.callSound))
    }
    return .init(meetingID: UUID(), lines: lines, tracks: tracks)
  }

  static let line = LiveWordsAssembler.Line(
    id: "m-1", track: .microphone, kind: .confirmed, startMs: 0, endMs: 900, text: "Hello there.")

  @Test("every track status says the approved sentence, or nothing while words can come")
  func everyStatus() {
    let cases: [(Status, String?)] = [
      (.starting, nil),
      (.running, nil),
      (.off(.notCaptured), nil),
      (
        .off(.universalNotDownloaded),
        "Live words need the Universal engine. Download it in Dictation Settings, Live Preview."
      ),
      (
        .off(.appleLanguageAndUniversalMissing(languageName: "German")),
        "Live words need Apple's German language or the Universal engine. Download either in Dictation Settings, Live Preview."
      ),
      (
        .off(.previousStillClosing),
        "Live words are off for this meeting while the last one finishes closing."
      ),
      (.off(.couldNotStart), "Live words are not available for this meeting."),
      (.off(.unavailable), "Live words are not available for this meeting."),
      (.off(.modelBeingRemoved), Self.removal),
      (.stopped(.engineFailed), "Live words stopped for You. The recording continues."),
      (.stopped(.restartTimedOut), "Live words stopped for You. The recording continues."),
      (.stopped(.restartFailed), "Live words stopped for You. The recording continues."),
      (.stopped(.modelRemoved), Self.removal),
    ]
    for (status, expected) in cases {
      #expect(P.trackLine(.microphone, status) == expected, "\(status)")
    }
    #expect(
      P.trackLine(.callSound, .stopped(.engineFailed))
        == "Live words stopped for Call. The recording continues.")
  }

  @Test("the status lines across mixed tracks, dropped audio and echo, each said once")
  func statusMatrix() {
    // Both running, no call sound recorded: only what live words are.
    #expect(
      P.liveStatusLines(Self.live(.running, .running), callSoundRecorded: false) == [Self.intro])
    // One captured track: the other says nothing.
    #expect(
      P.liveStatusLines(Self.live(.running, .off(.notCaptured)), callSoundRecorded: false)
        == [Self.intro])
    // The same reason on both tracks is said once.
    #expect(
      P.liveStatusLines(
        Self.live(.stopped(.modelRemoved), .stopped(.modelRemoved)), callSoundRecorded: true)
        == [Self.intro, Self.removal, Self.echo])
    #expect(
      P.liveStatusLines(
        Self.live(.off(.universalNotDownloaded), .off(.universalNotDownloaded)),
        callSoundRecorded: true)
        == [
          Self.intro,
          "Live words need the Universal engine. Download it in Dictation Settings, Live Preview.",
          Self.echo,
        ])
    // Different outcomes per track: each said, microphone first.
    #expect(
      P.liveStatusLines(
        Self.live(.stopped(.engineFailed), .running, dropped: [.callSound]),
        callSoundRecorded: true)
        == [
          Self.intro, "Live words stopped for You. The recording continues.", Self.skipped,
          Self.echo,
        ])
    // Dropped audio on both tracks: one note.
    #expect(
      P.liveStatusLines(
        Self.live(.running, .running, dropped: [.microphone, .callSound]),
        callSoundRecorded: false)
        == [Self.intro, Self.skipped])
  }

  static let noWordsYet = "No words yet."
  static let endedIntro =
    "Live words from the recording. The full transcript replaces them when it is ready."

  @Test("No words yet shows only while recording and a track can still bring words")
  func waitingForWords() {
    #expect(P.emptyLiveWords(Self.live(.starting, .starting)) == Self.noWordsYet)
    #expect(P.emptyLiveWords(Self.live(.running, .off(.notCaptured))) == Self.noWordsYet)
    #expect(P.emptyLiveWords(Self.live(.running, .running, lines: [Self.line])) == nil)
    #expect(P.emptyLiveWords(Self.live(.off(.universalNotDownloaded), .off(.notCaptured))) == nil)
    #expect(P.emptyLiveWords(Self.live(.stopped(.modelRemoved), .stopped(.modelRemoved))) == nil)
    #expect(P.emptyLiveWords(Self.live(.stopped(.engineFailed), .off(.couldNotStart))) == nil)
  }

  @Test("after Stop the kept live words promise no more words and no recording going on")
  func afterStop() {
    let ended = { (live: MeetingLiveWords.Transcript, call: Bool) in
      P.liveStatusLines(live, callSoundRecorded: call, recordingEnded: true)
    }
    // Empty tracks still starting or running when Stop came.
    #expect(ended(Self.live(.starting, .starting), false) == [Self.endedIntro])
    #expect(
      P.emptyLiveWords(Self.live(.running, .running), recordingEnded: true)
        == "No live words were heard.")
    #expect(
      P.emptyLiveWords(Self.live(.starting, .off(.notCaptured)), recordingEnded: true)
        == "No live words were heard.")
    // Words kept: no empty note.
    #expect(
      P.emptyLiveWords(Self.live(.running, .running, lines: [Self.line]), recordingEnded: true)
        == nil)
    // An earlier failure, dropped audio and echo, in past terms.
    #expect(
      ended(Self.live(.stopped(.engineFailed), .running, dropped: [.microphone]), true)
        == [
          Self.endedIntro, "Live words stopped for You before the recording ended.", Self.skipped,
          "Echo is hidden in the full transcript.",
        ])
    #expect(
      ended(Self.live(.stopped(.modelRemoved), .off(.modelBeingRemoved)), false)
        == [Self.endedIntro, "Live words stopped while the Universal engine was being removed."])
    #expect(
      ended(Self.live(.off(.previousStillClosing), .off(.previousStillClosing)), false)
        == [Self.endedIntro, "Live words were not available for this meeting."])
    #expect(
      ended(Self.live(.off(.universalNotDownloaded), .off(.notCaptured)), false)
        == [
          Self.endedIntro,
          "Live words need the Universal engine. Download it in Dictation Settings, Live Preview.",
        ])
    // No sentence after Stop speaks of a recording that goes on or words still to come.
    let every: [MeetingLiveWords.Status] = [
      .starting, .running, .off(.notCaptured), .off(.universalNotDownloaded),
      .off(.appleLanguageAndUniversalMissing(languageName: "German")), .off(.previousStillClosing),
      .off(.couldNotStart), .off(.unavailable), .off(.modelBeingRemoved), .stopped(.engineFailed),
      .stopped(.restartTimedOut), .stopped(.restartFailed), .stopped(.modelRemoved),
    ]
    for status in every {
      let all =
        ended(Self.live(status, status, dropped: [.microphone]), true)
        + [P.emptyLiveWords(Self.live(status, status), recordingEnded: true) ?? ""]
      for line in all {
        #expect(!line.contains("continues"), "\(status): \(line)")
        #expect(!line.contains("yet"), "\(status): \(line)")
        #expect(!line.contains("as people speak"), "\(status): \(line)")
        #expect(!line.contains("is being removed"), "\(status): \(line)")
        #expect(!line.contains("finishes closing"), "\(status): \(line)")
        #expect(!line.contains("when the meeting ends"), "\(status): \(line)")
      }
    }
  }
}
