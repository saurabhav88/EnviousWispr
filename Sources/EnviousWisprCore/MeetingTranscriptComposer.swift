import Foundation

/// One transcribed segment of one meeting track, as the after-recording pass hands it to the
/// composer (#3972 §3.7).
///
/// `words` carry ranges into THIS piece's `text` and times on the meeting timeline (already
/// offset by the segment's start). A word the engine gave no time keeps `nil`; the composer
/// interpolates it inside the piece (#3972 R5) so every word becomes a timed entry.
///
/// `segments` (#3973 C3) are an engine's segment timings for an engine with no word timings
/// (Whisper): ranges into this piece's `text`, times on the meeting timeline. A track whose
/// speech pieces carry segments and no words is assembled by segment.
public struct MeetingTrackPiece: Sendable, Equatable {
  public let text: String
  public let startMs: Int
  public let endMs: Int
  public let words: [ASRWordTiming]
  public let segments: [ASRSegmentTiming]
  /// False for a marker the job writes in place of speech it could not transcribe ("[Could not
  /// transcribe ...]"): a marker on the call track is not the far side talking (#4138).
  public let isSpeech: Bool

  public init(
    text: String, startMs: Int, endMs: Int, words: [ASRWordTiming],
    segments: [ASRSegmentTiming] = [], isSpeech: Bool = true
  ) {
    self.text = text
    self.startMs = startMs
    self.endMs = endMs
    self.words = words
    self.segments = segments
    self.isSpeech = isSpeech
  }

  /// #3973 C3: speech timed by segment only.
  var isSegmentTimed: Bool { isSpeech && words.isEmpty && !segments.isEmpty }
}

/// Everything one track contributes: its transcribed pieces in time order and its speaker
/// segments on the meeting timeline, with the diarizer's own (track-local) speaker ids.
public struct MeetingTrackInput: Sendable, Equatable {
  public let kind: MeetingTrackKind
  public let pieces: [MeetingTrackPiece]
  public let speakerSegments: [SpeakerSegment]

  public init(
    kind: MeetingTrackKind, pieces: [MeetingTrackPiece], speakerSegments: [SpeakerSegment]
  ) {
    self.kind = kind
    self.pieces = pieces
    self.speakerSegments = speakerSegments
  }
}

/// The composed meeting transcript: what the History row stores.
public struct MeetingComposition: Sendable, Equatable {
  public let text: String
  public let turns: [Turn]
  public let speakerNames: [String: String]
  /// Ids (in `turns`) of microphone turns that repeat the call sound.
  public let echoTurnIDs: [String]
  /// Distinct speakers across both tracks, echo turns excluded; at least 1 when any turn exists.
  public let speakerCount: Int
}

/// Merges per-track turns into one transcript (#3972 §3.7, R5). Pure and deterministic.
///
/// Peers do the same split: Wispr Flow and FluidVoice keep the microphone and the call sound
/// as separate tracks and name the microphone voice "You" (#3972 teardown). On a call every
/// microphone voice is the one speaker "You": on speakers the call leaks into the microphone and
/// its speaker analysis splits the user's own voice (#4138). Turns are
/// assembled per track by the shipped `TurnAssembler`, so a
/// word can only ever belong to its own track's speakers.
public enum MeetingTranscriptComposer {

  /// The name the microphone voice gets when the call sound shows it is a call.
  public static let youName = "You"
  /// Synthetic speaker ids used when a track's speaker analysis produced nothing usable.
  /// `mic:you` is also the one microphone speaker of every call (#4138).
  public static let fallbackMicrophoneSpeakerID = "mic:you"
  public static let fallbackCallSpeakerID = "sys:call"
  public static let fallbackCallName = "Call"

  /// Window around a microphone turn in which call-sound words are compared for echo. Wide,
  /// because the microphone clock is approximate (#3972 R27); the TEXT must repeat the call.
  public static let echoWindowMs = 5_000
  /// R27: an echo passage has at least this many words, and at least `echoTokenShare` of them
  /// pair one-to-one, in order, with call words nearby. Shorter repeats ("yeah", "okay") recur
  /// by chance and stay visible.
  public static let echoMinimumTokens = 3
  public static let echoTokenShare = 0.6
  /// Inside one echo passage, at most this many unpaired words in a row (an ASR variant of the
  /// call's word). A longer unpaired run is the user's own speech and ends the passage.
  public static let echoMaxUnpairedRun = 1

  public static func compose(tracks: [MeetingTrackInput]) -> MeetingComposition {
    var trackTurns: [(kind: MeetingTrackKind, turn: Turn, text: String, echo: Bool)] = []
    let joinedTracks = tracks.map { (track: $0, joined: joinPieces($0.pieces)) }

    // The call sound's words, for echo matching. Collected first so the microphone track can be
    // compared whichever order the tracks arrive in.
    var collected: [(token: String, startMs: Int, endMs: Int)] = []
    // A segment-timed track has no word times to pair (#3973 C3).
    for (track, joined) in joinedTracks where track.kind == .callSound && joined.segmentTimings == nil {
      for entry in joined.entries {
        guard let start = entry.startMs, let end = entry.endMs else { continue }
        let token = normalizedToken(entry.word)
        if !token.isEmpty { collected.append((token, start, end)) }
      }
    }
    let callWords = CallWords(collected)
    // Whether the far side said anything: a transcribed call piece with text. Markers for audio
    // that could not be transcribed do not count (#4138).
    let callHasSpeech = tracks.contains { track in
      track.kind == .callSound
        && track.pieces.contains {
          $0.isSpeech && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    for (track, joined) in joinedTracks {
      guard !joined.entries.isEmpty else { continue }
      let segments = prefixedSegments(track.speakerSegments, kind: track.kind)
      let fallback = fallbackSpeakerID(for: track.kind)
      var flagged: [(turn: Turn, echo: Bool)]
      if let timings = joined.segmentTimings {
        // #3973 C3: a segment takes one label (mixed or unbound segments are Both). No word
        // times exist, so no pause or echo splitting.
        var turns =
          segments.isEmpty
          ? []
          : TurnAssembler.assemble(segmentTimings: timings, rawText: joined.text, segments: segments)
            .turns
        if turns.isEmpty {
          turns = [singleTurn(entries: joined.entries, speaker: fallback, granularity: .segment)]
        }
        flagged = turns.map { ($0, false) }
      } else {
        var turns: [Turn]
        if segments.isEmpty {
          turns = [singleTurn(entries: joined.entries, speaker: fallback)]
        } else {
          turns = TurnAssembler.assemble(entries: joined.entries, segments: segments)
          if turns.isEmpty { turns = [singleTurn(entries: joined.entries, speaker: fallback)] }
        }
        turns = turns.flatMap { splitAtPauses($0, entries: joined.entries) }
        flagged = turns.map { ($0, false) }
        if track.kind == .microphone, !callWords.words.isEmpty {
          flagged = turns.flatMap { splitAtEcho($0, entries: joined.entries, callWords: callWords) }
        }
      }
      let utf16 = Array(joined.text.utf16)
      for (turn, echo) in flagged {
        let lower = max(0, min(turn.originalTextRange.lowerBound, utf16.count))
        let upper = max(lower, min(turn.originalTextRange.upperBound, utf16.count))
        let text = String(decoding: utf16[lower..<upper], as: UTF16.self)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }
        trackTurns.append((track.kind, turn, text, echo))
      }
    }

    // Stable time order; ties put the call sound first (the far side usually spoke first when
    // both tracks begin a turn in the same millisecond), then original order.
    let ordered = trackTurns.enumerated().sorted { lhs, rhs in
      let l = lhs.element.turn.startMs ?? Int.max
      let r = rhs.element.turn.startMs ?? Int.max
      if l != r { return l < r }
      if lhs.element.kind != rhs.element.kind { return lhs.element.kind == .callSound }
      return lhs.offset < rhs.offset
    }.map(\.element)

    var text = ""
    var turns: [Turn] = []
    var echoIDs: [String] = []
    let separator = "\n\n"
    for (index, item) in ordered.enumerated() {
      if !text.isEmpty { text += separator }
      let lower = text.utf16.count
      text += item.text
      let upper = text.utf16.count
      let id = "m\(index)-\(item.turn.startMs ?? -1)"
      // On a call every microphone turn is the user, whatever the speaker analysis split it into,
      // Both and Unknown included (#4138); turn boundaries and echo flags stay as they were.
      let speakerId =
        callHasSpeech && item.kind == .microphone
        ? fallbackMicrophoneSpeakerID : item.turn.speakerId
      turns.append(
        Turn(
          id: id, speakerId: speakerId, startMs: item.turn.startMs,
          endMs: item.turn.endMs, originalTextRange: lower..<upper,
          // Meetings are not polished in this release: `true` is the deliberate-bypass value
          // (`Turn.wasPolished`), so History never shows "Not fully polished" (#3972 R19).
          wasPolished: true, granularity: item.turn.effectiveGranularity))
      if item.echo { echoIDs.append(id) }
    }

    let names = speakerNames(turns: turns, echoIDs: Set(echoIDs), callHasSpeech: callHasSpeech)
    let distinct = Set(
      turns.filter { !echoIDs.contains($0.id) }.map(\.speakerId)
        .filter { $0 != TurnAssembler.bothSpeakersID && $0 != TurnAssembler.unknownSpeakerID })
    return MeetingComposition(
      text: text, turns: turns, speakerNames: names, echoTurnIDs: echoIDs,
      speakerCount: turns.isEmpty ? 0 : max(1, distinct.count))
  }

  // MARK: - Pieces to entries

  struct JoinedTrack {
    let text: String
    let entries: [ASRWordTiming]
    /// #3973 C3: set for a segment-timed track: every piece's segments with ranges into
    /// `text`; a piece without segments (a marker, or text the engine could not time) is one
    /// segment over its whole text and time. Nil for a word-timed track.
    let segmentTimings: [ASRSegmentTiming]?
  }

  /// Joins a track's pieces into one text with a space between pieces and turns every word
  /// into a timed entry whose range points into that text.
  static func joinPieces(_ pieces: [MeetingTrackPiece]) -> JoinedTrack {
    var text = ""
    var entries: [ASRWordTiming] = []
    let segmentTimed = pieces.contains(where: \.isSegmentTimed)
    var segmentTimings: [ASRSegmentTiming] = []
    for piece in pieces {
      let trimmed = piece.text
      guard !trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
      if !text.isEmpty { text += " " }
      let base = text.utf16.count
      text += trimmed
      if segmentTimed {
        if piece.segments.isEmpty {
          segmentTimings.append(
            ASRSegmentTiming(
              range: base..<(base + trimmed.utf16.count), startMs: piece.startMs,
              endMs: piece.endMs))
        } else {
          for segment in piece.segments {
            segmentTimings.append(
              ASRSegmentTiming(
                range: (base + segment.range.lowerBound)..<(base + segment.range.upperBound),
                startMs: segment.startMs, endMs: segment.endMs))
          }
        }
      }
      let timed = interpolatedTimes(for: piece)
      if timed.isEmpty {
        // No word data at all: the whole piece is one entry spanning the piece.
        entries.append(
          ASRWordTiming(
            word: trimmed, range: base..<(base + trimmed.utf16.count),
            startMs: piece.startMs, endMs: piece.endMs))
        continue
      }
      for word in timed {
        let lower = base + word.range.lowerBound
        let upper = base + word.range.upperBound
        entries.append(
          ASRWordTiming(
            word: word.word, range: lower..<upper, startMs: word.startMs, endMs: word.endMs))
      }
    }
    return JoinedTrack(
      text: text, entries: entries, segmentTimings: segmentTimed ? segmentTimings : nil)
  }

  /// Gives every untimed word a time between its timed neighbours, clamped to the piece
  /// (#3972 R5). A piece whose words are all untimed spreads them evenly across the piece.
  static func interpolatedTimes(for piece: MeetingTrackPiece) -> [ASRWordTiming] {
    let words = piece.words.filter { $0.range.lowerBound < $0.range.upperBound }
    guard !words.isEmpty else { return [] }
    var starts = words.map(\.startMs)
    var ends = words.map(\.endMs)
    let count = words.count
    var index = 0
    while index < count {
      if starts[index] != nil, ends[index] != nil {
        index += 1
        continue
      }
      var runEnd = index
      while runEnd < count, starts[runEnd] == nil || ends[runEnd] == nil { runEnd += 1 }
      let left = index > 0 ? (ends[index - 1] ?? piece.startMs) : piece.startMs
      let right = runEnd < count ? (starts[runEnd] ?? piece.endMs) : piece.endMs
      let lo = max(piece.startMs, min(left, piece.endMs))
      let hi = max(lo, min(right, piece.endMs))
      let n = runEnd - index
      let step = n > 0 ? Double(hi - lo) / Double(n) : 0
      for k in 0..<n {
        let s = lo + Int((Double(k) * step).rounded())
        let e = lo + Int((Double(k + 1) * step).rounded())
        starts[index + k] = s
        ends[index + k] = max(s, e)
      }
      index = runEnd
    }
    return words.indices.map { i in
      let s = max(piece.startMs, min(starts[i] ?? piece.startMs, piece.endMs))
      let e = max(s, min(ends[i] ?? s, piece.endMs))
      return ASRWordTiming(word: words[i].word, range: words[i].range, startMs: s, endMs: e)
    }
  }

  /// A per-track turn is one speaker's run of words, which on one track can span minutes while
  /// the OTHER track speaks in between. Splitting it wherever its own words pause longer than
  /// this lets the merge interleave the two tracks in the order people spoke.
  public static let turnSplitPauseMs = 1_500

  static func splitAtPauses(_ turn: Turn, entries: [ASRWordTiming]) -> [Turn] {
    let members = entries.filter {
      $0.range.lowerBound >= turn.originalTextRange.lowerBound
        && $0.range.upperBound <= turn.originalTextRange.upperBound
    }
    guard members.count > 1 else { return [turn] }
    var groups: [[ASRWordTiming]] = [[members[0]]]
    for entry in members.dropFirst() {
      let previousEnd = groups[groups.count - 1].last?.endMs
      if let previousEnd, let start = entry.startMs, start - previousEnd > turnSplitPauseMs {
        groups.append([entry])
      } else {
        groups[groups.count - 1].append(entry)
      }
    }
    guard groups.count > 1 else { return [turn] }
    return groups.map { group in
      let starts = group.compactMap(\.startMs)
      let ends = group.compactMap(\.endMs)
      let range = group.first!.range.lowerBound..<group.last!.range.upperBound
      return Turn(
        id: "\(range.lowerBound)-\(range.upperBound)", speakerId: turn.speakerId,
        startMs: starts.min(), endMs: ends.max(), originalTextRange: range, granularity: .word)
    }
  }

  /// Splits a microphone turn into echo passages (hidden by default) and the user's own speech
  /// (always visible) (#3972 R27; Codex C1 reviews r1-r2).
  ///
  /// The whole class, decided in one place:
  /// - Pairing is ONE-TO-ONE and IN ORDER: the longest common subsequence of the turn's
  ///   normalized tokens and the call words within ±`echoWindowMs` of the turn. A single call
  ///   "no" can pair with one microphone "no", never four.
  /// - A passage is a cluster of paired words with at most `echoMaxUnpairedRun` unpaired words
  ///   between neighbours; it is echo when it has at least `echoMinimumTokens` words and at least
  ///   `echoTokenShare` of them are paired.
  /// - Every word outside echo passages stays in ONE visible turn per contiguous stretch, so a
  ///   reply next to an echo, and a sentence sharing a few words with the call, are never hidden
  ///   and never cut into fragments.
  static func splitAtEcho(
    _ turn: Turn, entries: [ASRWordTiming], callWords: CallWords
  ) -> [(turn: Turn, echo: Bool)] {
    let members = entries.filter {
      $0.range.lowerBound >= turn.originalTextRange.lowerBound
        && $0.range.upperBound <= turn.originalTextRange.upperBound
    }
    guard members.count >= echoMinimumTokens, let start = turn.startMs, let end = turn.endMs else {
      return [(turn, false)]
    }
    let mic = members.map { (token: normalizedToken($0.word), time: $0.startMs ?? start) }
    let window = callWords.overlapping(start - echoWindowMs, end + echoWindowMs)
      .map { (token: $0.token, time: $0.startMs) }
    guard !window.isEmpty else { return [(turn, false)] }
    let paired = pairedPositions(mic, window, maxLagMs: echoWindowMs)
    guard paired.contains(true) else { return [(turn, false)] }

    // Clusters of paired words, allowing short unpaired runs inside a cluster.
    var echoRanges: [ClosedRange<Int>] = []
    var clusterStart: Int?
    var lastPaired = -1
    for (i, isPaired) in paired.enumerated() where isPaired {
      if clusterStart != nil, i - lastPaired - 1 <= echoMaxUnpairedRun {
        lastPaired = i
        continue
      }
      if let s = clusterStart { echoRanges.append(s...lastPaired) }
      clusterStart = i
      lastPaired = i
    }
    if let s = clusterStart { echoRanges.append(s...lastPaired) }
    echoRanges = echoRanges.filter { range in
      let count = range.count
      let pairedCount = range.filter { paired[$0] }.count
      return count >= echoMinimumTokens && Double(pairedCount) >= echoTokenShare * Double(count)
    }
    guard !echoRanges.isEmpty else { return [(turn, false)] }

    // Emit visible stretches and echo passages in order.
    var pieces: [(range: ClosedRange<Int>, echo: Bool)] = []
    var cursor = 0
    for range in echoRanges {
      if cursor < range.lowerBound { pieces.append((cursor...(range.lowerBound - 1), false)) }
      pieces.append((range, true))
      cursor = range.upperBound + 1
    }
    if cursor < members.count { pieces.append((cursor...(members.count - 1), false)) }
    if pieces.count == 1 { return [(turn, pieces[0].echo)] }
    return pieces.map { piece in
      let group = Array(members[piece.range])
      let range = group.first!.range.lowerBound..<group.last!.range.upperBound
      let split = Turn(
        id: "\(range.lowerBound)-\(range.upperBound)", speakerId: turn.speakerId,
        startMs: group.compactMap(\.startMs).min(), endMs: group.compactMap(\.endMs).max(),
        originalTextRange: range, granularity: .word)
      return (split, piece.echo)
    }
  }

  /// The call sound's words in time order, for finding the words near one microphone turn
  /// without scanning the whole call each time.
  struct CallWords {
    let words: [(token: String, startMs: Int, endMs: Int)]
    private let longestMs: Int

    init(_ unordered: [(token: String, startMs: Int, endMs: Int)]) {
      // Stable by arrival order on equal starts, so equal inputs always give equal pairings.
      words = unordered.enumerated()
        .sorted { ($0.element.startMs, $0.offset) < ($1.element.startMs, $1.offset) }
        .map(\.element)
      longestMs = words.map { max(0, $0.endMs - $0.startMs) }.max() ?? 0
    }

    /// Words with `endMs >= from` and `startMs <= to`, in time order.
    func overlapping(_ from: Int, _ to: Int) -> [(token: String, startMs: Int, endMs: Int)] {
      // No word lasts longer than `longestMs`, so none starting before this can reach `from`.
      var lo = 0
      var hi = words.count
      let earliest = from - longestMs
      while lo < hi {
        let mid = (lo + hi) / 2
        if words[mid].startMs < earliest { lo = mid + 1 } else { hi = mid }
      }
      var end = lo
      while end < words.count, words[end].startMs <= to { end += 1 }
      return words[lo..<end].filter { $0.endMs >= from }
    }
  }

  /// Which positions of `a` belong to one longest common subsequence of `a` and `b`, where two
  /// words may pair only when their tokens are equal (and not empty) and their times are within
  /// `maxLagMs`. One-to-one and order-preserving by construction.
  ///
  /// Sparse (Hunt-Szymanski): only the candidate pairs that satisfy the time window are
  /// visited, and the longest chain increasing in both positions is found with a patience
  /// search. `b` must be in time order. Memory and time grow with the number of candidate pairs
  /// (each microphone word against the call words in its own ±`maxLagMs` window), never with
  /// the product of the two lengths, so a lecture heard on both tracks stays bounded.
  static func pairedPositions(
    _ a: [(token: String, time: Int)], _ b: [(token: String, time: Int)], maxLagMs: Int
  ) -> [Bool] {
    var result = Array(repeating: false, count: a.count)
    guard !a.isEmpty, !b.isEmpty else { return result }
    // Chain links: (position in a, position in b, previous link or -1).
    var links: [(i: Int, j: Int, previous: Int)] = []
    // tails[k]: the link ending the best chain of length k + 1 (the one with the smallest j).
    var tails: [Int] = []
    for i in a.indices where !a[i].token.isEmpty {
      let t = a[i].time
      var lo = 0
      var hi = b.count
      while lo < hi {
        let mid = (lo + hi) / 2
        if b[mid].time < t - maxLagMs { lo = mid + 1 } else { hi = mid }
      }
      var candidates: [Int] = []
      var j = lo
      while j < b.count, b[j].time <= t + maxLagMs {
        if b[j].token == a[i].token { candidates.append(j) }
        j += 1
      }
      // Descending j, so one position of `a` can extend a chain at most once.
      for j in candidates.reversed() {
        var low = 0
        var high = tails.count
        while low < high {
          let mid = (low + high) / 2
          if links[tails[mid]].j < j { low = mid + 1 } else { high = mid }
        }
        links.append((i, j, low > 0 ? tails[low - 1] : -1))
        if low == tails.count { tails.append(links.count - 1) } else { tails[low] = links.count - 1 }
      }
    }
    var link = tails.last ?? -1
    while link >= 0 {
      result[links[link].i] = true
      link = links[link].previous
    }
    return result
  }

  // MARK: - Speakers

  static func prefixedSegments(_ segments: [SpeakerSegment], kind: MeetingTrackKind)
    -> [SpeakerSegment]
  {
    segments.map {
      SpeakerSegment(
        speakerId: "\(kind.speakerPrefix):\($0.speakerId)", startMs: $0.startMs,
        endMs: $0.endMs, quality: $0.quality)
    }
  }

  static func fallbackSpeakerID(for kind: MeetingTrackKind) -> String {
    kind == .microphone ? fallbackMicrophoneSpeakerID : fallbackCallSpeakerID
  }

  static func singleTurn(
    entries: [ASRWordTiming], speaker: String, granularity: TurnGranularity = .word
  ) -> Turn {
    let range = entries.first!.range.lowerBound..<entries.last!.range.upperBound
    let starts = entries.compactMap(\.startMs)
    let ends = entries.compactMap(\.endMs)
    return Turn(
      id: "\(range.lowerBound)-\(range.upperBound)", speakerId: speaker,
      startMs: starts.min(), endMs: ends.max(), originalTextRange: range,
      granularity: granularity)
  }

  /// "You" for the one microphone speaker of a call (`compose` maps every microphone turn to
  /// `mic:you` when the call sound has speech, #4138; this replaces the #3972 R5 single-speaker
  /// and mostly-echo heuristic, founder 2026-10-27); everyone else "Speaker N" in
  /// first-appearance order. With no call speech the microphone keeps its own speakers.
  static func speakerNames(turns: [Turn], echoIDs: Set<String>, callHasSpeech: Bool)
    -> [String: String]
  {
    var names: [String: String] = [:]
    if turns.contains(where: { $0.speakerId == fallbackCallSpeakerID }) {
      names[fallbackCallSpeakerID] = fallbackCallName
    }
    if callHasSpeech, turns.contains(where: { $0.speakerId == fallbackMicrophoneSpeakerID }) {
      names[fallbackMicrophoneSpeakerID] = youName
    }
    let generated = TurnAssembler.defaultSpeakerNames(
      for: turns.filter { !echoIDs.contains($0.id) }, existingNames: names)
    names.merge(generated) { current, _ in current }
    // A speaker that only ever appears in echo turns still needs a name to render.
    for turn in turns
    where names[turn.speakerId] == nil
      && turn.speakerId != TurnAssembler.bothSpeakersID
      && turn.speakerId != TurnAssembler.unknownSpeakerID
    {
      let more = TurnAssembler.defaultSpeakerNames(for: [turn], existingNames: names)
      names.merge(more) { current, _ in current }
    }
    return names
  }

  // MARK: - Echo

  static func normalizedToken(_ word: String) -> String {
    word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
      .map(String.init).joined()
  }
}
