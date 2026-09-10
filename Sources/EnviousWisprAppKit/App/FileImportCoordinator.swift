import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprPipeline
import Foundation
import Observation

/// #2648 — the state machine behind Transcribe a File.
///
/// **A coordinator rather than a view model, because the job outlives the view.**
/// The founder's requirement is that leaving the page and coming back returns to
/// the same state, and that the sidebar shows a dot while a run is going.
/// A view that owned the state could do neither. `TranscriptCoordinator` is the
/// precedent for a `@MainActor @Observable` coordinator the composition root
/// holds and injects into the environment.
///
/// **Five states, one direction, no re-entry**, plus two terminal side branches:
/// `rejected` from reading, and `stopped` from anywhere after transcribing.
/// `stopped` keeps whatever was produced, because a user who stops a 40-minute
/// import after 30 minutes should not lose the 30.
@MainActor
@Observable
final class FileImportCoordinator {

  // MARK: - What the screen is showing

  enum State: Equatable {
    case idle
    case reading(fileName: String)
    case ready(fileName: String, seconds: Double)
    case transcribing(fileName: String)
    /// `done` parts of `total` have finished. The user never sees these numbers
    /// as "chunks" — the founder's call is that the chunking is never
    /// user-facing — but the progress they drive is.
    case polishing(done: Int, total: Int)
    case finished
    case rejected(FileImportRejection)
    case stopped
  }

  /// Why a file never started. Each one is a sentence a person can act on.
  enum FileImportRejection: Equatable, Sendable {
    case cannotRead
    case noAudio
    case noSpeechFound
    case engineBusy(SharedEngineHolder)
    case failed(String)
  }

  /// One part of the document, as the reader sees it.
  struct Part: Equatable, Identifiable, Sendable {
    let id: Int
    /// The words as they stand now: polished if polish landed, deterministic
    /// otherwise.
    var text: String
    /// True when this part is showing unpolished text. Marked in the document
    /// rather than hidden: thirteen good parts and one raw part is a good
    /// outcome, and hiding the raw one is the failure.
    var isUnpolished: Bool
  }

  private(set) var state: State = .idle
  private(set) var parts: [Part] = []

  /// The whole raw transcript, kept so a re-polish never re-reads the file.
  private(set) var rawTranscript: String = ""

  /// The document as one piece of text, for copy and save.
  var documentText: String { parts.map(\.text).joined(separator: "\n\n") }

  /// Whether a run is in flight, for the sidebar dot.
  var isRunning: Bool {
    switch state {
    case .transcribing, .polishing: return true
    case .idle, .reading, .ready, .finished, .rejected, .stopped: return false
    }
  }

  // MARK: - Collaborators

  private let decode: @Sendable (URL) async throws -> [Float]
  private let transcribe: @MainActor ([Float]) async throws -> String
  private let engineAdmission: EngineAdmissionAccess

  /// Freezes the configuration this run uses. Called once per run, before the
  /// first part — the founder's "one import, one configuration" call, so a
  /// settings change halfway through cannot produce a document polished two
  /// different ways.
  private let beginRun: @MainActor () -> Void

  /// Runs one part. A closure rather than the concrete `FileImportRunner` for
  /// one reason and it is not style: the property this type exists to hold —
  /// that Stop changes the screen at once while the claim waits for the work to
  /// exit — cannot be tested at all unless a test can make a part take as long
  /// as it likes.
  private let processPart: @MainActor (String) async throws -> FileImportRunner.PartOutcome

  /// **Generation protects STATE. Terminal completion protects the RESOURCE.**
  /// Neither substitutes for the other, and this coordinator needs both: Stop
  /// changes what the user sees at once and bumps this, so a late part cannot
  /// write into a run the user has already ended — while the claim is released
  /// only from the run task's own `defer`, after the physical work has exited.
  private var generation = 0
  private var runTask: Task<Void, Never>?

  init(
    decode: @escaping @Sendable (URL) async throws -> [Float],
    transcribe: @escaping @MainActor ([Float]) async throws -> String,
    engineAdmission: EngineAdmissionAccess,
    beginRun: @escaping @MainActor () -> Void,
    processPart: @escaping @MainActor (String) async throws -> FileImportRunner.PartOutcome
  ) {
    self.decode = decode
    self.transcribe = transcribe
    self.engineAdmission = engineAdmission
    self.beginRun = beginRun
    self.processPart = processPart
  }

  // MARK: - The user's four actions

  /// The user picked a file. Reads it far enough to say whether it can be
  /// transcribed at all, before anything touches an engine.
  func choose(url: URL) {
    guard !isRunning else { return }
    parts = []
    rawTranscript = ""
    decodedSamples = []
    let name = url.lastPathComponent
    // Bumped HERE too, not only when a run starts. Picking a second file while
    // the first is still decoding is an ordinary thing to do, and without this
    // both decodes carry the same generation, so whichever finishes last wins —
    // which can be the file the user already replaced.
    generation += 1
    let generationAtStart = generation
    state = .reading(fileName: name)
    Task { [weak self] in
      guard let self else { return }
      do {
        let samples = try await decode(url)
        guard generationAtStart == generation else { return }
        state = .ready(
          fileName: name, seconds: Double(samples.count) / AudioConstants.sampleRate)
        decodedSamples = samples
      } catch {
        guard generationAtStart == generation else { return }
        state = .rejected(Self.rejection(for: error))
      }
    }
  }

  /// The decoded audio, held between `choose` and `start` so pressing Start does
  /// not read the file a second time.
  private var decodedSamples: [Float] = []

  /// Runs the import. Claims the shared engine first: a refusal here is a
  /// refusal to start, not a queue.
  func start() {
    guard case .ready(let name, _) = state else { return }

    let token: EngineLease.Token
    switch engineAdmission.claim() {
    case .granted(let granted):
      token = granted
    case .refused(let holder):
      state = .rejected(.engineBusy(holder))
      return
    }

    beginRun()

    generation += 1
    let generationAtStart = generation
    state = .transcribing(fileName: name)

    runTask = Task { [weak self] in
      // **The claim goes back only here**, after the physical work has exited.
      // Releasing where Stop is DECIDED would let a dictation in while a
      // cancelled part was still inside the one-slot polish server.
      defer { self?.engineAdmission.release(token) }
      await self?.run(generationAtStart: generationAtStart)
    }
  }

  /// Stop changes what the user sees at once and keeps whatever is finished.
  /// The claim is not released here — see `start`.
  func stop() {
    guard isRunning else { return }
    generation += 1
    state = .stopped
    runTask?.cancel()
  }

  /// Re-runs the cleanup under the current settings, from the transcript already
  /// in memory. **The file is never read again**, which is the whole point of
  /// keeping the raw transcript.
  func rePolish() {
    guard !rawTranscript.isEmpty, !isRunning else { return }

    let token: EngineLease.Token
    switch engineAdmission.claim() {
    case .granted(let granted):
      token = granted
    case .refused(let holder):
      state = .rejected(.engineBusy(holder))
      return
    }

    beginRun()

    generation += 1
    let generationAtStart = generation
    parts = []

    runTask = Task { [weak self] in
      defer { self?.engineAdmission.release(token) }
      guard let self else { return }
      await polishAll(
        TranscriptSplitter.split(rawTranscript), generationAtStart: generationAtStart)
    }
  }

  // MARK: - The run

  private func run(generationAtStart: Int) async {
    do {
      let transcript = try await transcribe(decodedSamples)
      guard generationAtStart == generation else { return }
      guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        state = .rejected(.noSpeechFound)
        return
      }
      rawTranscript = transcript
      await polishAll(TranscriptSplitter.split(transcript), generationAtStart: generationAtStart)
    } catch is CancellationError {
      // Stop already set the visible state; there is nothing to say.
    } catch {
      guard generationAtStart == generation else { return }
      state = .rejected(Self.rejection(for: error))
    }
  }

  /// Runs every part, one at a time, publishing each as it lands.
  ///
  /// One at a time is not a simplification: the polish server has a single
  /// inference slot, so parts in parallel would queue inside it and the progress
  /// the user sees would stop meaning anything.
  private func polishAll(_ pieces: [String], generationAtStart: Int) async {
    guard !pieces.isEmpty else {
      state = .finished
      return
    }
    state = .polishing(done: 0, total: pieces.count)

    for (index, piece) in pieces.enumerated() {
      if Task.isCancelled || generationAtStart != generation { return }
      do {
        let outcome = try await processPart(piece)
        // Re-read AFTER the await: a Stop during this part must not write into
        // a run the user has already ended.
        guard generationAtStart == generation else { return }
        parts.append(
          Part(id: index, text: outcome.displayText, isUnpolished: outcome.isUnpolished))
      } catch is CancellationError {
        return
      } catch {
        guard generationAtStart == generation else { return }
        // A part that could not run at all still appears, carrying its raw
        // words. A gap in the document would be the silent failure.
        parts.append(Part(id: index, text: piece, isUnpolished: true))
      }
      guard generationAtStart == generation else { return }
      state = .polishing(done: index + 1, total: pieces.count)
    }
    guard generationAtStart == generation else { return }
    state = .finished
  }

  private static func rejection(for error: any Error) -> FileImportRejection {
    switch error {
    case AudioFileDecoder.Rejection.unreadable:
      return .cannotRead
    case AudioFileDecoder.Rejection.noAudioTrack, AudioFileDecoder.Rejection.noAudio:
      return .noAudio
    default:
      return .failed(String(describing: error))
    }
  }
}
