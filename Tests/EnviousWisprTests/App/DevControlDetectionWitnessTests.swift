#if DEBUG
  import Foundation
  import Testing

  @testable import EnviousWisprASR
  @testable import EnviousWisprAppKit

  /// #4254 runtime checkpoint: when these fail, the checkpoint cannot tell whether a dictation
  /// start, a meeting delete or an engine switch reached the app while a meeting's speech
  /// detection ran, or the line leaks a setting's value.
  @Suite("Dev control detection witness", .serialized, .tags(.productOutcome))
  struct DevControlDetectionWitnessTests {
    typealias Door = DevControlDoor

    @Test("only a dictation start, a meeting delete and a selectedBackend write are witnessed")
    func witnessedCommands() {
      #expect(Door.detectionWitness(.dictationStart, args: [:], id: "a") != nil)
      #expect(Door.detectionWitness(.meetingDelete, args: ["id": "m"], id: "b") != nil)
      #expect(
        Door.detectionWitness(
          .settingsSet, args: ["key": "selectedBackend", "value": "whisper"], id: "c") != nil)
      #expect(
        Door.detectionWitness(
          .settingsSet, args: ["key": "meetingTranscriptEngine", "value": "x"], id: "d") == nil)
      #expect(Door.detectionWitness(.meetingRetry, args: [:], id: "e") == nil)
      #expect(Door.detectionWitness(nil, args: [:], id: "f") == nil)
    }

    @Test("the line names the request id and every running detection, and no argument value")
    func lineContents() throws {
      MeetingSpeechDetectionActivity.begin(11)
      MeetingSpeechDetectionActivity.begin(7)
      defer {
        MeetingSpeechDetectionActivity.end(11)
        MeetingSpeechDetectionActivity.end(7)
      }
      let line = try #require(
        Door.detectionWitness(
          .settingsSet, args: ["key": "selectedBackend", "value": "whisper"], id: "req-1"))
      #expect(line.hasPrefix("whisper_meeting_vad_active request=engine_switch id=req-1 tokens="))
      #expect(line.contains("tokens=7,11 "), "\(line)")
      #expect(line.contains("whisper ") == false, "no argument value: \(line)")
      #expect(line.contains("uptime_raw_ns="))
    }
  }
#endif
