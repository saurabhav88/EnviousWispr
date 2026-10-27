import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprCore

/// #4118: when these fail, a burst of short segments rewrites the meeting record again and
/// again, a recording's History duration stops moving, or a segment goes missing from the
/// meeting's saved list at Stop.
@Suite("Meeting segment saves", .tags(.productOutcome))
struct MeetingSegmentSavesTests {
  static func segment(_ index: Int, startMs: Int, ms: Int = 60_000) -> MeetingSegmentInfo {
    MeetingSegmentInfo(
      index: index, fileName: "seg-\(index).caf", startMs: startMs, frameCount: ms * 16)
  }

  @Test("normal 60 s segments save at every close, with only the newest per track")
  func normalSegmentsSaveEachClose() {
    let saves = MeetingSegmentSaves()
    for index in 1...3 {
      #expect(
        saves.append(track: .microphone, info: Self.segment(index, startMs: (index - 1) * 60_000)))
      let update = saves.update()
      #expect(update.shouldSave)
      #expect(
        update.checkpoint == [.microphone: [Self.segment(index, startMs: (index - 1) * 60_000)]])
    }
  }

  @Test("a burst schedules one update and saves once per 30 s of recorded audio")
  func burstIsSpaced() {
    let saves = MeetingSegmentSaves()
    var scheduled = 0
    var saved = 0
    for index in 1...3_000 {
      if saves.append(
        track: .callSound, info: Self.segment(index, startMs: (index - 1) * 20, ms: 10))
      {
        scheduled += 1
      }
      // An update every 100 segments, as a busy main actor would run them.
      if index % 100 == 0, saves.update().shouldSave { saved += 1 }
    }
    // 3,000 segments 20 ms apart span 60 s: a save at the first update, then each 30 s.
    #expect(scheduled == 30)
    #expect(saved == 2)
    #expect(saves.checkpoint()[.callSound]?.count == 1)
  }

  @Test("spacing follows the latest end on any track, not the last arrival")
  func spacingUsesMeetingWideEnd() {
    let saves = MeetingSegmentSaves()
    _ = saves.append(track: .microphone, info: Self.segment(1, startMs: 0, ms: 40_000))
    #expect(saves.update().shouldSave)
    // A call-sound segment that ends earlier arrives later: no new recorded time, no save.
    _ = saves.append(track: .callSound, info: Self.segment(1, startMs: 0, ms: 20_000))
    #expect(saves.update().shouldSave == false)
    _ = saves.append(track: .callSound, info: Self.segment(2, startMs: 20_000, ms: 50_000))
    #expect(saves.update().shouldSave)
  }

  @Test("finish hands over every segment in order and refuses later ones")
  func finishHandsOverEverything() {
    let saves = MeetingSegmentSaves()
    let mic = (1...5).map { Self.segment($0, startMs: ($0 - 1) * 20, ms: 10) }
    for info in mic { _ = saves.append(track: .microphone, info: info) }
    _ = saves.append(track: .callSound, info: Self.segment(1, startMs: 0))
    let all = saves.finish()
    #expect(all[.microphone] == mic)
    #expect(all[.callSound]?.count == 1)
    #expect(saves.append(track: .microphone, info: Self.segment(6, startMs: 100)) == false)
    #expect(saves.update().shouldSave == false)
  }

  @Test("an abnormal rate is noted once per minute of recorded time, a normal one never")
  func rateNoteOncePerWindow() {
    let saves = MeetingSegmentSaves()
    for index in 1...10 {
      _ = saves.append(
        track: .microphone, info: Self.segment(index, startMs: (index - 1) * 1_000, ms: 1_000))
    }
    #expect(saves.update().notes.isEmpty, "ten closes in a minute is the limit, not over it")
    _ = saves.append(track: .microphone, info: Self.segment(11, startMs: 10_000, ms: 1_000))
    #expect(saves.update().notes == [.microphone: 11])
    for index in 12...40 {
      _ = saves.append(
        track: .microphone, info: Self.segment(index, startMs: (index - 1) * 1_000, ms: 1_000))
    }
    #expect(saves.update().notes.isEmpty, "a second note waits a full minute")
    for index in 41...75 {
      _ = saves.append(
        track: .microphone, info: Self.segment(index, startMs: (index - 1) * 1_000, ms: 1_000))
    }
    #expect(saves.update().notes == [.microphone: 11])
  }
}
