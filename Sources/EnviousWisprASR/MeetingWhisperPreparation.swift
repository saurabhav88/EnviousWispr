import Darwin
import EnviousWisprAudio
import EnviousWisprCore
import Foundation
import os

/// Groups the detected speech of one meeting run for decoding (#4254 plan §17, r5.1).
///
/// Speech is never joined: Whisper drops a spoken repetition when joined speech brings the same
/// words close together (plan §17, Q-b round 2). Each group is one CONTIGUOUS slice of the
/// original run, from its first speech span's start to its last span's end, with the silences
/// inside it kept as recorded, so detection never brings speech closer together than the
/// speaker did. A silence of `gap` or more between spans starts a new group; only those
/// silences are left out. Each group is decoded on its own.
enum MeetingWhisperPreparation {
  static let sampleRate = 16_000

  /// The provisional grouping gap (plan §17: 8 s, pending validation).
  static let groupGapSamples = 8 * sampleRate

  /// The groups of `spans` within a run of `count` samples, in order and apart. Spans are
  /// clamped to the run; empty ones are dropped. Empty when no speech remains (confirmed
  /// silence).
  static func groups(spans: [Range<Int>], count: Int, gap: Int = groupGapSamples) -> [Range<Int>] {
    let bounds = 0..<count
    let kept = spans.map { $0.clamped(to: bounds) }.filter { !$0.isEmpty }
      .sorted { $0.lowerBound < $1.lowerBound }
    var groups: [Range<Int>] = []
    for span in kept {
      if let last = groups.last, span.lowerBound - last.upperBound < gap {
        groups[groups.count - 1] = last.lowerBound..<max(last.upperBound, span.upperBound)
      } else {
        groups.append(span)
      }
    }
    return groups
  }
}

/// The detector a meeting decode uses: speech ranges (padded, merged) of the whole input.
/// Throws `CancellationError` when cancelled and any other error when detection cannot run.
package typealias MeetingSpeechSpans = @Sendable ([Float]) async throws -> [Range<Int>]

/// `CLOCK_UPTIME_RAW` in nanoseconds: the one clock the meeting detection lines and the
/// runtime checkpoint's witnesses use (the harness reads the same clock id).
package func meetingDetectionUptimeNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

#if DEBUG
  /// #4254 runtime checkpoint (DEBUG only): the meeting speech detections running now, by
  /// token. A set, so concurrent detections are all visible. Each change and each read takes
  /// its `CLOCK_UPTIME_RAW` reading under the same lock; nothing logs or waits under it.
  package enum MeetingSpeechDetectionActivity {
    private static let active = OSAllocatedUnfairLock(initialState: Set<UInt32>())

    /// Adds `token`; the clock reading at the change.
    @discardableResult
    package static func begin(_ token: UInt32) -> UInt64 {
      active.withLock { tokens in
        tokens.insert(token)
        return meetingDetectionUptimeNanos()
      }
    }

    /// Removes `token`; the clock reading at the change.
    @discardableResult
    package static func end(_ token: UInt32) -> UInt64 {
      active.withLock { tokens in
        tokens.remove(token)
        return meetingDetectionUptimeNanos()
      }
    }

    /// The active tokens, sorted, and the clock reading taken with them.
    package static func snapshot() -> (tokens: [UInt32], uptimeNs: UInt64) {
      active.withLock { tokens in (tokens.sorted(), meetingDetectionUptimeNanos()) }
    }
  }
#endif

extension MeetingWhisperPreparation {
  /// The app's pinned bundled model, a fresh detector per call (plan §16.8).
  static let bundled: MeetingSpeechSpans = { try await MeetingSpeechDetector.spans(in: $0) }

  /// The pinned model's name, logged with each decode's outcome.
  static let detectorVersion = MeetingSpeechDetector.modelVersion
}
