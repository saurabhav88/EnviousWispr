import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprStorage
import Foundation

/// Where a meeting's damaged audio leaves gaps on its timeline (#3972 R3), from what recovery
/// and the track read reported and what is on disk. Moved out of `MeetingCoordinator`
/// (#3995): it produces `MeetingTranscriptionJob.MissingAudio`, the pass's own input.
package enum MeetingDamagedAudio {
  /// Damaged-audio markers in the transcript: one per missing stretch, on every track.
  package static func markerCount(
    _ missingAudio: [MeetingTrackKind: [MeetingTranscriptionJob.MissingAudio]]
  ) -> Int {
    missingAudio.values.reduce(0) { $0 + $1.count }
  }

  /// The file a recovery problem is about, when the problem means its audio is lost. Empty
  /// files and overlaps lose nothing a listener would hear.
  package static func damagedFileName(_ problem: MeetingTrackRecovery.Problem) -> String? {
    switch problem {
    case .unreadablePartial(let name), .unreadableFinal(let name), .incompatibleFinal(let name):
      return name
    case .folderUnreadable, .emptyPartial, .partialBesideFinal, .promotionFailed,
      .directorySyncFailed, .emptyFinal, .duplicateIndex:
      return nil
    }
  }

  package static func damagedFileName(_ problem: MeetingTrackAudio.Problem) -> String? {
    switch problem {
    case .unreadable(let name), .incompatibleFormat(let name):
      return name
    case .empty, .overlap:
      return nil
    }
  }

  /// Per track, the stretches only a damaged file claims (milliseconds). A damaged file's
  /// claim runs from its own start to the next file's start on that track; with no next file
  /// its end is unknown (nil), never a guess. Audio a readable file covers is removed from it.
  package static func missingAudio(
    damaged: Set<String>, onDisk: [MeetingStore.SegmentFile],
    readable: [MeetingTrackKind: MeetingTrackAudio]
  ) -> [MeetingTrackKind: [MeetingTranscriptionJob.MissingAudio]] {
    var result: [MeetingTrackKind: [MeetingTranscriptionJob.MissingAudio]] = [:]
    let unbounded = Int.max
    for kind in MeetingTrackKind.allCases {
      let files = onDisk.filter { $0.track == kind }.sorted { $0.startMs < $1.startMs }
      let covered = (readable[kind]?.segments ?? []).map {
        ms($0.readStartSample)..<ms($0.endSample)
      }.filter { !$0.isEmpty }.sorted { $0.lowerBound < $1.lowerBound }
      for (i, file) in files.enumerated() where damaged.contains(file.url.lastPathComponent) {
        let next = files[(i + 1)...].first { $0.startMs > file.startMs }?.startMs
        var pieces = [file.startMs..<(next ?? unbounded)]
        for cover in covered {
          pieces = pieces.flatMap { piece -> [Range<Int>] in
            guard cover.overlaps(piece) else { return [piece] }
            var left: [Range<Int>] = []
            if piece.lowerBound < cover.lowerBound {
              left.append(piece.lowerBound..<cover.lowerBound)
            }
            if cover.upperBound < piece.upperBound {
              left.append(cover.upperBound..<piece.upperBound)
            }
            return left
          }
        }
        for piece in pieces {
          result[kind, default: []].append(
            .init(
              startMs: piece.lowerBound,
              endMs: piece.upperBound == unbounded ? nil : piece.upperBound))
        }
      }
    }
    return result
  }

  private static func ms(_ sample: Int) -> Int {
    Int((Double(sample) * 1_000 / MeetingAudioFormat.sampleRate).rounded())
  }
}
