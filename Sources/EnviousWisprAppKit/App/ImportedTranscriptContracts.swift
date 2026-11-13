import EnviousWisprCore
import Foundation

// #3147 PR3 shared contract: the types the Transcripts tab's lanes compile against. Lane A
// implements `ImportedSourceAccessing`, lane C implements `ImportedTranscriptRetranscribing`,
// lane B consumes both. No production implementation lives here.

/// A row's source link as stored: what a source command expects to replace.
struct ImportedSourceReference: Equatable, Sendable {
  let bookmark: Data?
  let fingerprint: String?

  init(bookmark: Data?, fingerprint: String?) {
    self.bookmark = bookmark
    self.fingerprint = fingerprint
  }

  init(_ row: Transcript) {
    self.init(bookmark: row.sourceBookmark, fingerprint: row.sourceFingerprint)
  }
}

/// Permission to replace one import's content with a fresh transcription (Transcribe again
/// with), minted by `TranscriptCoordinator.beginImportedReplacement` after the user confirms.
/// The commit refuses when the row changed since (its stored digest), its source changed, or
/// a newer ticket replaced this one.
struct ImportedReplacementTicket: Sendable, Equatable {
  let rowID: UUID
  let requestID: UUID
  let attemptID: UUID
  let expectedRowDigest: String
  let source: ImportedSourceReference
}

/// An import's original file, found and identified now.
struct ResolvedImportedSource: Equatable, Sendable {
  let rowID: UUID
  let reference: ImportedSourceReference
  let url: URL
  let identity: ImportedSourceIdentity
}

/// What History can say about an import's original file. Copy never diagnoses a cause it
/// cannot establish ("unavailable", never "moved" from a generic absence).
enum ImportedSourceState: Equatable, Sendable {
  case available(ResolvedImportedSource)
  /// No link, the link does not resolve, or the file is gone.
  case missing
  /// The link resolves to a file whose identity differs from the stored fingerprint.
  case changed
  /// The file is there but could not be read.
  case unreadable
  /// A legacy row with no fingerprint: the file may be the original; nothing proves it.
  case unverifiable(URL)
  /// The stored fingerprint is a version this build does not understand.
  case unsupportedIdentity
  /// The row itself is gone.
  case removed
}

/// What Locate original did.
enum ImportedRelocationOutcome: Equatable, Sendable {
  case linked
  /// A legacy row needs the user's explicit confirmation before a file is adopted.
  case confirmationRequired
  /// The chosen file is not the original (fingerprint differs).
  case wrongFile
  /// The row's source changed while this ran.
  case stale
  case removed
}

/// The original file opened for playback.
struct ImportedPlaybackSource: Sendable {
  let source: ResolvedImportedSource
  let durationMs: Int
  let audio: any PlaybackWindowAudio
}

/// Finds, checks, relinks and opens imports' original files (lane A implements it).
@MainActor
protocol ImportedSourceAccessing: AnyObject {
  /// Bumped whenever a row's source state may have changed, so views re-read it.
  func revision(for rowID: UUID) -> Int
  func state(for rowID: UUID) async -> ImportedSourceState
  func playbackSource(for rowID: UUID) async throws -> ImportedPlaybackSource?
  func relocate(rowID: UUID, to url: URL, userConfirmed: Bool) async throws
    -> ImportedRelocationOutcome
}

/// The speech engine and model a Transcribe again with run uses, frozen when it starts.
enum ImportedASRSelection: Equatable, Sendable {
  case parakeet(ParakeetModelSelection, identity: ASRModelIdentity)
  case whisper(modelFile: URL, identity: ASRModelIdentity)
}

/// How a Transcribe again with run ended.
enum ImportedRetranscriptionOutcome: Equatable, Sendable {
  case replaced
  /// Another file transcription holds the engine.
  case busy
  case sourceUnavailable
  /// The row changed, was deleted or a newer run replaced this one.
  case stale
  case cancelled
  case failed
}

/// One row's Transcribe again with progress, as every window shows it.
enum ImportedRetranscriptionState: Equatable, Sendable {
  case idle
  /// `fraction` is nil when the engine reports no progress.
  case running(fraction: Double?)
  case cancelling
  case finished(ImportedRetranscriptionOutcome)
}

/// Runs Transcribe again with in place (lane C implements it). Confirmation happens before
/// `startConfirmed`; nothing runs without it.
@MainActor
/// One installed speech model the Transcribe again with menu can offer.
struct ImportedASRChoice: Identifiable, Equatable, Sendable {
  let id: String
  let title: String
  let selection: ImportedASRSelection
  /// The model that produced the row's current text.
  let isCurrent: Bool
}

protocol ImportedTranscriptRetranscribing: AnyObject {
  /// The installed models the user can pick for this row; empty means no usable model.
  /// Never downloads and never changes the global engine.
  func choices(for rowID: UUID) -> [ImportedASRChoice]
  func state(for rowID: UUID) -> ImportedRetranscriptionState
  func startConfirmed(rowID: UUID, selection: ImportedASRSelection) async
    -> ImportedRetranscriptionOutcome
  func cancel(rowID: UUID)
}
