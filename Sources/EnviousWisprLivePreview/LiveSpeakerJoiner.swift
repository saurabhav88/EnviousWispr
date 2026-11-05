import EnviousWisprCore
import Foundation

/// Who one live-words piece belongs to (#4355 PR C plan §3.3 Joiner).
package enum LiveSpeakerAssignment: Sendable, Equatable {
  /// Microphone text: the user.
  case you
  /// Call text owned by one live speaker model slot in `epoch`. A slot is not a person: the model
  /// can misattribute or reuse a slot within an epoch without any signal, so numbering and names
  /// are derived later from current evidence.
  case remote(epoch: Int, slot: Int)
  /// Not enough final evidence to say.
  case unresolved
}

/// The pure per-piece assignment rule (#4355 PR C plan §3.3). One piece at a time, never a
/// coalesced line, so text joined into one line can still belong to different speakers.
///
/// A call piece gets a speaker only when the model's FINAL activity of the current recording,
/// call track, run and epoch covers its whole span, and within that coverage one slot owns at
/// least 80% of the speech while no other slot exceeds 20%. Speech is the time at least one slot
/// is active; each slot's ownership is its active time within that speech, so overlap counts for
/// every active slot (never argmax). An empty slot set is analyzed silence; a missing interval is
/// unknown and keeps the piece unresolved, as do zero speech and competing ownership.
package enum LiveSpeakerJoiner {
  package static func assign(
    _ piece: MeetingTimedPiece, track: MeetingTrackKind, activities: [LiveSpeakerActivity],
    currentEpoch: Int
  ) -> LiveSpeakerAssignment {
    switch track {
    case .microphone:
      return .you
    case .callSound:
      guard let span = piece.span, span.track == .callSound else { return .unresolved }
      return remote(span: span, activities: activities, epoch: currentEpoch)
    }
  }

  private static func remote(
    span: MeetingAudioSpan, activities: [LiveSpeakerActivity], epoch: Int
  ) -> LiveSpeakerAssignment {
    let start = span.startSample
    let end = span.endSample
    // Only this recording's call track, this run and this epoch; clipped to the piece.
    let evidence: [(start: Int, end: Int, slots: Set<Int>)] = activities.compactMap { activity in
      let a = activity.span
      guard activity.epoch == epoch, a.recording == span.recording, a.track == .callSound,
        a.run == span.run
      else { return nil }
      let lower = max(a.startSample, start)
      let upper = min(a.endSample, end)
      guard lower < upper else { return nil }
      return (lower, upper, Set(activity.activeSlots))
    }
    // Elementary segments between every boundary; each must be covered, and duplicated coverage
    // unions its slots instead of counting twice.
    var bounds = Set([start, end])
    for item in evidence {
      bounds.insert(item.start)
      bounds.insert(item.end)
    }
    let edges = bounds.sorted()
    var speech = 0
    var owned: [Int: Int] = [:]
    for (lower, upper) in zip(edges, edges.dropFirst()) {
      let covering = evidence.filter { $0.start <= lower && $0.end >= upper }
      guard !covering.isEmpty else { return .unresolved }
      let slots = covering.reduce(into: Set<Int>()) { $0.formUnion($1.slots) }
      guard !slots.isEmpty else { continue }
      let length = upper - lower
      speech += length
      for slot in slots { owned[slot, default: 0] += length }
    }
    guard speech > 0 else { return .unresolved }
    // Integer comparisons: owner >= 80% of speech, every other slot <= 20% (equality allowed).
    guard let owner = owned.first(where: { $0.value * 5 >= speech * 4 })?.key,
      owned.allSatisfy({ $0.key == owner || $0.value * 5 <= speech })
    else { return .unresolved }
    return .remote(epoch: epoch, slot: owner)
  }
}
