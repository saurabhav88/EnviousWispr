import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation
import os

/// #4355 PR C plan §3.3 Live names: turns the recording meeting's settled live speaker evidence
/// into the shipped namer's inputs. Naming policy stays entirely in `MeetingSpeakerNamer`.
///
/// Only solo speech is evidence: the stretches inside a settled piece where its owning slot, and
/// no other, was active by final model evidence. An 80/20 owner's overlap, silence and the other
/// slot's share are left out, so a vote can only land on time one voice alone filled.
///
/// Clock: a written position is NOT observation time. The writer continues its cursor through
/// small arrival jitter (`MeetingTrackWriter.write`), so written samples can sit away from when
/// the audio was acquired. Each released call chunk carries both (`MeetingReleasedChunk.span`
/// and `.acquired`), so a written stretch maps to the call-app log's clock (milliseconds after
/// the recorder anchor, `CallSpeakerTimeline.observationMs`) through the chunk that holds it:
/// the chunk's acquisition time plus the stretch's offset inside the chunk. The namer then
/// applies each segment's frozen lag once. Stretches in no recorded chunk, or in a chunk whose
/// time was only estimated, abstain. Never arrival time on the main actor.
enum MeetingLiveNaming {
  /// What one settled piece contributes: its live speaker and its solo stretches, already on
  /// the call-app log's clock (milliseconds after the recorder anchor).
  struct Evidence: Equatable, Sendable {
    let speakerID: String
    let epoch: Int
    let soloMs: [Range<Int>]
  }

  /// One released call chunk's written position and acquisition time.
  struct ClockEntry: Equatable, Sendable {
    let run: Int
    let startSample: Int
    let sampleCount: Int
    let acquired: MeetingAcquisitionTime

    init(_ chunk: MeetingReleasedChunk) {
      run = chunk.span.run
      startSample = chunk.span.startSample
      sampleCount = chunk.span.sampleCount
      acquired = chunk.acquired
    }

    var endSample: Int { startSample + sampleCount }
  }

  /// The clock pairs of one recording, kept for naming. The writer queue
  /// (`MeetingRecorder.liveSamples`: never blocks, no allocation) writes into preallocated slots
  /// with `withLockIfAvailable`; when the main actor holds the lock, the pair is dropped. A
  /// dropped or replaced pair only leaves that audio out of name evidence
  /// (`observationStretches` skips parts in no chunk), never gives it a wrong time.
  final class ClockRing: Sendable {
    private struct State: Sendable {
      var slots: [ClockEntry?]
      var next = 0
    }
    private let state: OSAllocatedUnfairLock<State>

    init(capacity: Int) {
      precondition(capacity > 0)
      state = OSAllocatedUnfairLock(
        initialState: State(slots: [ClockEntry?](repeating: nil, count: capacity)))
    }

    /// Writer queue: never waits and never allocates. The main actor reads copies
    /// (`entries()`), so the slot storage is never shared when this writes into it.
    func note(_ entry: ClockEntry) {
      _ = state.withLockIfAvailable { s in
        s.slots[s.next] = entry
        s.next = (s.next + 1) % s.slots.count
      }
    }

    /// Main actor: a fresh copy of the pairs kept, in no particular order.
    func entries() -> [ClockEntry] {
      state.withLock { s in s.slots.compactMap { $0 } }
    }
  }

  /// Written stretches of `run` on the call-app log's clock, through the chunks that hold them.
  /// Parts in no chunk, or in a chunk with an estimated time, are left out.
  static func observationStretches(
    _ stretches: [Range<Int>], run: Int, clock: [ClockEntry], anchor: UInt64
  ) -> [Range<Int>] {
    var result: [Range<Int>] = []
    for stretch in stretches {
      for entry in clock where entry.run == run && entry.acquired.provenance != .estimated {
        let lower = max(stretch.lowerBound, entry.startSample)
        let upper = min(stretch.upperBound, entry.endSample)
        guard lower < upper,
          let base = CallSpeakerTimeline.observationMs(
            readStart: entry.acquired.hostTicks, readEnd: entry.acquired.hostTicks, anchor: anchor)
        else { continue }
        let start = base + MeetingTranscriptionJob.ms(lower - entry.startSample)
        let end = base + MeetingTranscriptionJob.ms(upper - entry.startSample)
        if start < end { result.append(start..<end) }
      }
    }
    return result.sorted { $0.lowerBound < $1.lowerBound }
  }

  /// A genuine call speaker id the namer accepts (`sys:<id>`), stable for one slot in one
  /// epoch of this meeting. Never a displayed or localized name.
  static func speakerID(epoch: Int, slot: Int) -> String {
    "\(MeetingTrackKind.callSound.speakerPrefix):live-\(epoch)-\(slot)"
  }

  /// The stretches of `span` where `slot` alone was active, from final evidence of `epoch`
  /// in the span's recording and run. Duplicated reports union; anything else (overlap,
  /// silence, missing coverage) is left out.
  static func soloStretches(
    span: MeetingAudioSpan, slot: Int, epoch: Int, activities: [LiveSpeakerActivity]
  ) -> [Range<Int>] {
    let start = span.startSample
    let end = span.endSample
    let evidence = activities.compactMap { activity -> (Int, Int, Set<Int>)? in
      let a = activity.span
      guard activity.epoch == epoch, a.recording == span.recording, a.track == .callSound,
        a.run == span.run
      else { return nil }
      let lower = max(a.startSample, start)
      let upper = min(a.endSample, end)
      return lower < upper ? (lower, upper, Set(activity.activeSlots)) : nil
    }
    var bounds = Set([start, end])
    for item in evidence {
      bounds.insert(item.0)
      bounds.insert(item.1)
    }
    let edges = bounds.sorted()
    var stretches: [Range<Int>] = []
    for (lower, upper) in zip(edges, edges.dropFirst()) {
      let slots = evidence.filter { $0.0 <= lower && $0.1 >= upper }
        .reduce(into: Set<Int>()) { $0.formUnion($1.2) }
      guard slots == [slot] else { continue }
      if let last = stretches.last, last.upperBound == lower {
        stretches[stretches.count - 1] = last.lowerBound..<upper
      } else {
        stretches.append(lower..<upper)
      }
    }
    return stretches
  }

  /// The namer's inputs: one call turn per solo stretch, and the same stretches as the call
  /// speech, so `MeetingSpeakerNamer.eligibleSpeech` keeps exactly each voice's solo time.
  static func inputs(_ evidence: [Evidence]) -> (MeetingComposition, MeetingNamingEligibility) {
    var turns: [Turn] = []
    var speech: [MeetingNamingInterval] = []
    for item in evidence {
      for stretch in item.soloMs {
        let startMs = stretch.lowerBound
        let endMs = stretch.upperBound
        guard let interval = MeetingNamingInterval(startMs: startMs, endMs: endMs) else { continue }
        turns.append(
          Turn(
            id: "live-\(turns.count)", speakerId: item.speakerID, startMs: startMs,
            endMs: endMs, originalTextRange: 0..<0))
        speech.append(interval)
      }
    }
    let ids = Set(evidence.map(\.speakerID))
    let composition = MeetingComposition(
      text: "", turns: turns, speakerNames: [:], echoTurnIDs: [], speakerCount: ids.count)
    return (
      composition,
      MeetingNamingEligibility(callSpeakerIDs: ids, callSpeech: speech, markers: [])
    )
  }
}
