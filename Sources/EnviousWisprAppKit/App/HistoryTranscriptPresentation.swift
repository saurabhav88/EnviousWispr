import EnviousWisprCore
import Foundation

/// The drawing rules of the Transcripts tab (#3147 PR3 §3.5): what an imported transcript's short
/// card, full view and docked player say, decided from plain values so tests can read them.
///
/// **Copy never claims more than the app knows.** A missing, changed or unreadable original is
/// "unavailable", never "moved" or "verified"; a legacy row (no stored identity) asks before a
/// chosen file is adopted, and nothing says that file was checked (§17 R2).
enum HistoryTranscriptPresentation {

  // MARK: - Document identity

  /// What isolates one document's rename popovers and Marked up diffs: the row and its import
  /// attempt. Transcribe again with keeps the row id and mints a new attempt, so the replaced
  /// text starts with no open rename and no diffs of the old words.
  struct DocumentKey: Hashable, Sendable {
    let rowID: UUID
    let importAttemptID: UUID?

    init(_ row: Transcript) {
      rowID = row.id
      importAttemptID = row.importAttemptID
    }
  }

  // MARK: - Short card

  /// The facts a short card shows as chips, in the order drawn (the legacy row's inventory,
  /// `TranscriptRowView`): file name, sorted speaker names, Recovered, Interrupted, the polish
  /// model, the speech engine.
  enum Chip: Hashable, Sendable {
    case file(String)
    case speakers(String)
    case recovered
    case interrupted
    /// AI polish ran; the model name when the row recorded one.
    case polish(model: String?)
    case backend(String)
  }

  static func chips(for row: Transcript) -> [Chip] {
    var chips: [Chip] = []
    if let file = row.importedFileName { chips.append(.file(file)) }
    if let names = speakerList(row) { chips.append(.speakers(names)) }
    // The legacy row's order: Recovered, then the verified-removal-only Interrupted.
    if row.isRecovered == true { chips.append(.recovered) }
    if row.inputDeviceWasRemoved == true { chips.append(.interrupted) }
    if row.polishedText != nil { chips.append(.polish(model: row.llmModel)) }
    chips.append(.backend(row.backendType.displayName))
    return chips
  }

  /// Speaker names sorted for a stable order (a dictionary's iteration order is not); nil when
  /// the row names nobody.
  static func speakerList(_ row: Transcript) -> String? {
    guard let names = row.speakerNames, !names.isEmpty else { return nil }
    return names.values.sorted().joined(separator: ", ")
  }

  /// The card's title: the imported file's name, or the kind word for a row without one.
  static func title(for row: Transcript) -> String {
    row.importedFileName ?? transcriptWord
  }

  /// "12:04 long": the source file's length (`Transcript.duration`), nil when unknown.
  static func lengthLine(for row: Transcript) -> String? {
    guard row.duration > 0 else { return nil }
    let clock = HistoryDictationPresentation.clock(row.duration)
    return String(
      localized: "\(clock) long",
      comment: "History transcript card: how long the original file is. %@ is a time like 12:04.")
  }

  // MARK: - Original file

  /// What the card's source line and the dock say about the original file.
  enum SourceLine: Equatable, Sendable {
    /// Not looked up yet: nothing is drawn, so the card never flashes a wrong claim.
    case checking
    /// The original was found and plays.
    case plays
    /// No usable original; Locate original is offered.
    case unavailable(UnavailableReason)
    /// The row is gone.
    case removed
  }

  enum UnavailableReason: Equatable, Sendable {
    /// No link, it does not resolve, or the file is gone.
    case missing
    /// The linked file is not the one transcribed.
    case changed
    /// The file is there but could not be read.
    case unreadable
    /// An older transcript: a file is there, but nothing proves it is the original.
    case unproven
    /// The stored identity is from a newer version of the app.
    case unsupported
    /// The file was found but could not be opened for playback.
    case cannotPlay
  }

  /// The line for `state`. `playable` is whether a player was actually opened: an available
  /// original that could not be opened still says so instead of promising playback.
  static func sourceLine(state: ImportedSourceState?, playable: Bool) -> SourceLine {
    guard let state else { return .checking }
    switch state {
    case .available: return playable ? .plays : .unavailable(.cannotPlay)
    case .missing: return .unavailable(.missing)
    case .changed: return .unavailable(.changed)
    case .unreadable: return .unavailable(.unreadable)
    case .unverifiable: return playable ? .plays : .unavailable(.unproven)
    case .unsupportedIdentity: return .unavailable(.unsupported)
    case .removed: return .removed
    }
  }

  /// Whether Locate original is offered for this line.
  static func offersLocate(_ line: SourceLine) -> Bool {
    if case .unavailable = line { return true }
    return false
  }

  /// The card's short line.
  static func cardLine(_ line: SourceLine) -> String? {
    switch line {
    case .checking, .removed: return nil
    case .plays:
      return String(
        localized: "Plays from the original file",
        comment: "History transcript card: the original audio or video file was found and can play."
      )
    case .unavailable(let reason):
      return unavailableLine(reason)
    }
  }

  /// One sentence per reason. "Unavailable", never a guessed cause such as "moved".
  static func unavailableLine(_ reason: UnavailableReason) -> String {
    switch reason {
    case .missing:
      String(
        localized: "Original file unavailable, so it can't play.",
        comment:
          "History transcript: the original audio or video file can't be found. No cause is claimed."
      )
    case .changed:
      String(
        localized: "Original file unavailable. The file there now is a different one.",
        comment:
          "History transcript: the file at the original's place is not the file that was transcribed."
      )
    case .unreadable:
      String(
        localized: "Original file unavailable. It can't be read right now.",
        comment: "History transcript: the original file is there but could not be read.")
    case .unproven:
      String(
        localized:
          "This older transcript can't confirm which file it came from.",
        comment:
          "History transcript: a transcript saved before the app stored file details; a file is there but nothing confirms it is the original."
      )
    case .unsupported:
      String(
        localized: "Original file unavailable. It was linked by a newer version of EnviousWispr.",
        comment:
          "History transcript: the stored file details come from a newer app version this one cannot read."
      )
    case .cannotPlay:
      String(
        localized: "Original file unavailable. It can't be opened for playback.",
        comment: "History transcript: the original file was found but could not be opened to play.")
    }
  }

  /// The dock's line when nothing can play: the times stay, for reading only.
  static func dockUnavailableLine(_ reason: UnavailableReason) -> String {
    String(
      localized: "\(unavailableLine(reason)) The times are for reading only.",
      comment:
        "History transcript dock: why the original can't play, then that turn times can't be clicked. %@ is the reason sentence."
    )
  }

  // MARK: - Locate original

  /// Whether Locate original must ask before adopting a chosen file: a legacy row stores no
  /// identity, so the app cannot check the file and the user decides.
  static func locateNeedsConfirmation(_ row: Transcript) -> Bool {
    row.sourceFingerprint == nil
  }

  /// What the user hears after Locate original, nil when the confirmation is asked next.
  static func relocationLine(_ outcome: ImportedRelocationOutcome) -> String? {
    switch outcome {
    case .linked:
      String(
        localized: "Original file linked. It plays again.",
        comment: "History transcript: Locate original linked the chosen file.")
    case .confirmationRequired:
      nil
    case .wrongFile:
      String(
        localized: "That isn't the file this transcript came from. Choose the original.",
        comment:
          "History transcript: Locate original refused a file that differs from the one transcribed."
      )
    case .stale:
      String(
        localized: "This transcript changed while you were choosing. Try again.",
        comment:
          "History transcript: Locate original was refused because the transcript's file link changed meanwhile."
      )
    case .removed:
      String(
        localized: "This transcript was deleted.",
        comment: "History transcript: the transcript was deleted while Locate original ran.")
    }
  }

  static var relocationFailedLine: String {
    String(
      localized: "Couldn't link that file. Try again.",
      comment: "History transcript: Locate original failed with an error.")
  }

  // MARK: - Header and plain fallback

  /// The full view's provenance facts: creation date and engine always; the polish model only
  /// from real polish provenance (polished text present and a model recorded).
  struct Provenance: Equatable, Sendable {
    let createdAt: Date
    let backend: String
    let polishModel: String?
    let aiPolished: Bool
    let speakers: String?
    let length: String?
  }

  static func provenance(for row: Transcript) -> Provenance {
    Provenance(
      createdAt: row.createdAt, backend: row.backendType.displayName,
      polishModel: row.polishedText != nil ? row.llmModel : nil,
      aiPolished: row.polishedText != nil, speakers: speakerList(row),
      length: lengthLine(for: row))
  }

  /// The plain document shown when a row has no turns (`nil` or empty), as the legacy detail
  /// draws it: polished or processed output with the original below, or the raw words alone.
  enum PlainDocument: Equatable, Sendable {
    /// AI polish rewrote the text.
    case polished(output: String, original: String)
    /// Processing (numbers, saved words) ran without AI polish; never labelled AI Polished.
    case processed(output: String, original: String)
    case raw(String)
  }

  static func plainDocument(for row: Transcript) -> PlainDocument {
    if let polished = row.polishedText { return .polished(output: polished, original: row.text) }
    if let processed = row.processedText {
      return .processed(output: processed, original: row.text)
    }
    return .raw(row.text)
  }

  /// `nil` and `[]` turns are the same "nothing turn-shaped" outcome.
  static func hasRenderableTurns(_ row: Transcript) -> Bool {
    guard let turns = row.turns else { return false }
    return !turns.isEmpty
  }

  /// The hint beside the view picker.
  static func viewHint(
    mode: FileImportCoordinator.DocumentView, playable: Bool
  ) -> String {
    switch mode {
    case .original:
      String(
        localized: "What the speech engine wrote, before cleanup",
        comment: "History transcript: hint beside the Original view.")
    case .markedUp:
      String(
        localized: "Struck through: removed by cleanup. Highlighted: added.",
        comment: "History transcript: hint beside the Marked up view, explaining the marks.")
    case .cleaned:
      playable
        ? String(
          localized: "Click a turn's play button to hear that part",
          comment: "History transcript: hint beside the Cleaned view when the original can play.")
        : String(
          localized: "The cleaned-up transcript",
          comment: "History transcript: hint beside the Cleaned view when the original can't play.")
    }
  }

  // MARK: - Dock

  /// Fifteen seconds back or forward, kept inside the recording.
  static func skip(from positionMs: Int, by deltaMs: Int, durationMs: Int) -> Int {
    min(max(0, positionMs + deltaMs), max(0, durationMs))
  }

  static let skipMs = 15_000

  /// "1×", "1.25×", "0.75×": the speed as the menu and its button show it.
  static func rateLabel(_ rate: Float) -> String {
    let formatter = NumberFormatter()
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 2
    formatter.minimumIntegerDigits = 1
    let number = formatter.string(from: NSNumber(value: rate)) ?? "\(rate)"
    return "\(number)×"
  }

  /// What the main button does now.
  enum PlayAction: Equatable, Sendable {
    case play, pause, replay
  }

  static func playAction(for state: MeetingPlaybackController.State) -> PlayAction {
    switch state {
    case .playing: .pause
    case .finished: .replay
    case .idle, .paused, .unavailable: .play
    }
  }

  static func playLabel(_ action: PlayAction) -> String {
    switch action {
    case .play:
      String(localized: "Play", comment: "History transcript dock: plays the original file.")
    case .pause:
      String(localized: "Pause", comment: "History transcript dock: pauses the original file.")
    case .replay:
      String(
        localized: "Play again from the start",
        comment: "History transcript dock: the original finished; plays it again from the start.")
    }
  }

  static func playSymbol(_ action: PlayAction) -> String {
    switch action {
    case .play: "play.fill"
    case .pause: "pause.fill"
    case .replay: "arrow.counterclockwise"
    }
  }

  /// Whether a fresh, deletion-fenced lookup needs a new player: none yet, another file, or a
  /// player a deletion or read failure stopped for good.
  @MainActor static func needsNewPlayer(
    current: MeetingPlaybackController?, currentSource: ResolvedImportedSource?,
    resolved: ResolvedImportedSource
  ) -> Bool {
    guard let current else { return true }
    return currentSource != resolved || current.state == .unavailable
  }

  // MARK: - Transcribe again with

  /// The line shown for a row's Transcribe again with job; nil when nothing is worth saying.
  static func retranscriptionLine(_ state: ImportedRetranscriptionState) -> String? {
    switch state {
    case .idle:
      return nil
    case .running(let fraction):
      guard let fraction else {
        return String(
          localized: "Transcribing again…",
          comment: "History transcript: Transcribe again with is running; no progress is known.")
      }
      let percent = Int((min(max(fraction, 0), 1) * 100).rounded(.down))
      return String(
        localized: "Transcribing again… \(percent)%",
        comment: "History transcript: Transcribe again with is running. %lld is a percentage.")
    case .cancelling:
      return String(
        localized: "Stopping…",
        comment: "History transcript: Transcribe again with is being cancelled.")
    case .finished(let outcome):
      return outcomeLine(outcome)
    }
  }

  static func outcomeLine(_ outcome: ImportedRetranscriptionOutcome) -> String {
    switch outcome {
    case .replaced:
      String(
        localized: "Transcribed again. The new text replaced the old one.",
        comment: "History transcript: Transcribe again with finished and replaced the text.")
    case .busy:
      String(
        localized: "Another file is being transcribed. Try again when it finishes.",
        comment:
          "History transcript: Transcribe again with could not start because another file transcription runs."
      )
    case .sourceUnavailable:
      String(
        localized: "The original file is unavailable, so it can't be transcribed again.",
        comment:
          "History transcript: Transcribe again with needs the original file, which is unavailable."
      )
    case .stale:
      String(
        localized: "This transcript changed meanwhile, so nothing was replaced. Try again.",
        comment:
          "History transcript: Transcribe again with was refused because the transcript changed or was deleted."
      )
    case .cancelled:
      String(
        localized: "Stopped. The transcript wasn't changed.",
        comment: "History transcript: Transcribe again with was cancelled.")
    case .failed:
      String(
        localized: "Couldn't transcribe again. The transcript wasn't changed.",
        comment: "History transcript: Transcribe again with failed.")
    }
  }

  /// Whether a job for the row is in progress (running or stopping).
  static func isBusy(_ state: ImportedRetranscriptionState) -> Bool {
    switch state {
    case .running, .cancelling: true
    case .idle, .finished: false
    }
  }

  /// Whether a finished line is an error the user should notice.
  static func isFailure(_ state: ImportedRetranscriptionState) -> Bool {
    guard case .finished(let outcome) = state else { return false }
    return outcome != .replaced && outcome != .cancelled
  }

  // MARK: - Words

  static var transcriptWord: String {
    String(
      localized: "Transcript",
      comment:
        "History detail title for a row made with Transcribe a File. Also the default file name when saving it."
    )
  }
}
