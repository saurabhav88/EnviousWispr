import Foundation

/// Where a stretch of live samples sits on the written timeline (#4355): `count` samples from
/// `offset` in their chunk are `span`. Only exactly adjacent written audio of one recording,
/// track and run shares a slice, so a gap, a refused chunk, an eviction or a run break always
/// starts a new one.
package struct MeetingLiveAudioSlice: Equatable, Sendable {
  package let offset: Int
  package let span: MeetingAudioSpan
  package var count: Int { span.sampleCount }

  package init(offset: Int, span: MeetingAudioSpan) {
    self.offset = offset
    self.span = span
  }
}

/// Live 16 kHz samples with their written positions, in order. The slices cover `samples` in
/// order; a stretch no slice covers has no known position (the live pump's bank slice list was
/// full, plan §3.1 amendment), and attribution abstains for it rather than guessing.
package struct MeetingLiveAudioChunk: Equatable, Sendable {
  package let samples: [Float]
  package let slices: [MeetingLiveAudioSlice]

  package init(samples: [Float], slices: [MeetingLiveAudioSlice]) {
    self.samples = samples
    self.slices = slices
  }

  /// The samples in `range` with their slices cut to match: a slice's span advances by exactly
  /// the samples cut from its front.
  package func subrange(_ range: Range<Int>) -> MeetingLiveAudioChunk {
    var cut: [MeetingLiveAudioSlice] = []
    for slice in slices {
      let lower = max(slice.offset, range.lowerBound)
      let upper = min(slice.offset + slice.count, range.upperBound)
      guard upper > lower,
        let span = MeetingAudioSpan(
          recording: slice.span.recording, track: slice.span.track, run: slice.span.run,
          startSample: slice.span.startSample + (lower - slice.offset), sampleCount: upper - lower)
      else { continue }
      cut.append(MeetingLiveAudioSlice(offset: lower - range.lowerBound, span: span))
    }
    return MeetingLiveAudioChunk(samples: Array(samples[range]), slices: cut)
  }
}
