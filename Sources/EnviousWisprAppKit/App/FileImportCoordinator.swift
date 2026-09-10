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

  // MARK: - Where the user is in the flow

  /// The six steps of the approved design, in order.
  ///
  /// **A wizard rather than one card**, because the user chooses BOTH engines
  /// per import before anything runs, and the design gives each choice its own
  /// screen with the specs needed to make it. The step bar is always visible and
  /// a completed step can be gone back to while nothing has run.
  enum Step: Int, CaseIterable, Equatable {
    case upload = 1
    case transcription
    case polish
    case review
    case working
    case done

    var title: String {
      switch self {
      case .upload: return "Upload"
      case .transcription: return "Transcription"
      case .polish: return "Polish"
      case .review: return "Review"
      case .working: return "Working"
      case .done: return "Done"
      }
    }
  }

  private(set) var step: Step = .upload

  /// The engines THIS import will use. Seeded from the user's current settings
  /// so the common case is one Continue away, and changed here without writing
  /// back: a choice made for one file is not a change to how dictation works.
  var chosenBackend: ASRBackendType = .parakeet
  var chosenPolish: LLMProvider = .none

  /// The file the user picked, described. Everything the Upload and Review steps
  /// show about it comes from here rather than from a second read.
  private(set) var file: ChosenFile?

  struct ChosenFile: Equatable, Sendable {
    let name: String
    let seconds: Double
    let byteCount: Int64
    let codec: String
    let sampleRate: Double
    let channelCount: Int

    /// "1 hr 12 min · 68.4 MB · AAC · 44.1 kHz · mono"
    var detailLine: String {
      [
        FileImportCoordinator.durationText(seconds),
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file),
        codec,
        String(format: "%.1f kHz", sampleRate / 1000),
        channelCount == 1 ? "mono" : (channelCount == 2 ? "stereo" : "\(channelCount) channels"),
      ].joined(separator: " · ")
    }
  }

  /// "1 hr 12 min", "3 min", "48 sec".
  ///
  /// `nonisolated` because `ChosenFile.detailLine` is a plain value computation
  /// that has no business hopping to the main actor to format a number.
  nonisolated static func durationText(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    if total < 60 { return "\(total) sec" }
    let minutes = total / 60
    if minutes < 60 { return "\(minutes) min" }
    return "\(minutes / 60) hr \(minutes % 60) min"
  }

  /// How long the run is expected to take, for "Ready in about 3 minutes".
  ///
  /// Measured shape rather than a guess: the fast engine transcribes about an
  /// hour of audio in seven seconds, and the polish is what actually costs time
  /// — roughly twelve seconds per 500-word part.
  var estimateText: String {
    guard let file else { return "" }
    // Rounded UP: 1,100 words is three parts, not two, and an estimate that
    // truncates gets shorter exactly as the file gets longer.
    let parts = max(1, Int(((file.seconds / 60.0 * 150.0) / 500.0).rounded(.up)))
    let minutes = max(1, Int((Double(parts) * 12.0 / 60.0).rounded()))
    return minutes == 1 ? "about a minute" : "about \(minutes) minutes"
  }

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

  /// What the Working step's phase label says. The words describe the JOB, never
  /// the mechanism: the user is never told about parts or chunks.
  private(set) var phase: String = ""

  /// How many words the transcript holds, shown live beside the progress bar.
  var wordCount: Int { TranscriptSplitter.wordCount(in: rawTranscript) }

  /// 0...1 for the progress bar.
  var progress: Double {
    if case .polishing(let done, let total) = state, total > 0 {
      return Double(done) / Double(total)
    }
    if case .finished = state { return 1 }
    return 0
  }

  /// The whole raw transcript, kept so a re-polish never re-reads the file.
  private(set) var rawTranscript: String = ""

  /// The configuration the CURRENT document was produced under, held until a new
  /// run starts. `nil` before the first run.
  private(set) var runConfiguration: RunConfiguration?

  /// The bundled local polisher a RUNNING import has pinned, or nil. Read by the
  /// settings sync so a provider switch defers tearing down the server this run
  /// is using, exactly as it already defers for a live dictation.
  var pinnedLocalPolishProvider: LLMProvider? {
    isRunning ? runConfiguration?.localPolishProvider : nil
  }

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

  private let decode: @Sendable (URL) async throws -> AudioFileDecoder.Decoded
  private let transcribe: @MainActor ([Float]) async throws -> String
  private let engineAdmission: EngineAdmissionAccess

  /// What one run is pinned to, captured at Start.
  ///
  /// **Everything that must not drift mid-run reads THIS, never live settings.**
  /// Cloud review found two places that read the live value instead: the page's
  /// privacy line, which would retrospectively claim "nothing is uploaded" over
  /// a cloud-polished document, and the local-engine reconciliation, which would
  /// tear down the very server this run is using.
  struct RunConfiguration: Equatable, Sendable {
    /// Whether the polisher this run froze sends text off the machine.
    let polishIsCloud: Bool
    /// The BUNDLED local polisher this run froze, if any, so the settings sync
    /// can defer tearing its server down until the run releases its claim.
    let localPolishProvider: LLMProvider?
  }

  /// Freezes the configuration this run uses and returns it. Called once per
  /// run, before the first part — the founder's "one import, one configuration"
  /// call, so a settings change halfway through cannot produce a document
  /// polished two different ways.
  private let beginRun: @MainActor () -> RunConfiguration

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
    decode: @escaping @Sendable (URL) async throws -> AudioFileDecoder.Decoded,
    transcribe: @escaping @MainActor ([Float]) async throws -> String,
    engineAdmission: EngineAdmissionAccess,
    beginRun: @escaping @MainActor () -> RunConfiguration,
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
    file = nil
    step = .upload
    state = .reading(fileName: name)
    Task { [weak self] in
      guard let self else { return }
      do {
        let decoded = try await decode(url)
        guard generationAtStart == generation else { return }
        file = ChosenFile(
          name: name, seconds: decoded.seconds, byteCount: decoded.byteCount,
          codec: decoded.codec, sampleRate: decoded.sampleRate,
          channelCount: decoded.channelCount)
        state = .ready(fileName: name, seconds: decoded.seconds)
        decodedSamples = decoded.samples
      } catch {
        guard generationAtStart == generation else { return }
        state = .rejected(Self.rejection(for: error))
      }
    }
  }

  /// Moves forward through the wizard. Refused once a run is in flight: the
  /// choices are frozen for the run, so a step that could still change them
  /// would be lying about what is about to happen.
  func advance() {
    guard !isRunning else { return }
    switch step {
    case .upload:
      if case .ready = state { step = .transcription }
    case .transcription: step = .polish
    case .polish: step = .review
    case .review: start()
    case .working, .done: break
    }
  }

  /// Goes back one step. Only ever available while nothing has run.
  func goBack() {
    guard !isRunning else { return }
    switch step {
    case .upload, .working, .done: break
    case .transcription: step = .upload
    case .polish: step = .transcription
    case .review: step = .polish
    }
  }

  /// Jumps to a completed step from the step bar. Same rule: only before a run.
  func jump(to target: Step) {
    guard !isRunning, target.rawValue < step.rawValue else { return }
    step = target
  }

  /// Clears everything and returns to an empty Upload step.
  func startOver() {
    guard !isRunning else { return }
    generation += 1
    file = nil
    parts = []
    rawTranscript = ""
    decodedSamples = []
    runConfiguration = nil
    state = .idle
    step = .upload
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

    runConfiguration = beginRun()

    generation += 1
    let generationAtStart = generation
    step = .working
    phase = "Writing down what was said"
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
    // **The step moves with the state.** Stopping is an ENDING, so the user
    // lands on Done holding whatever finished, with Copy, Save and New
    // transcription in reach. Leaving `step` on `.working` stranded them on a
    // progress bar that would never move again, beside a Stop button that had
    // already been pressed.
    step = .done
    phase = ""
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

    runConfiguration = beginRun()

    generation += 1
    let generationAtStart = generation
    parts = []
    step = .working
    phase = "Cleaning it up"

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
      // **Released as soon as the engine is done with it, on every exit.** At 16
      // kHz mono float this is ~230 MB per hour of audio, and re-polish needs
      // only `rawTranscript` — holding it for the rest of the app's life would
      // cost the user hundreds of megabytes for a document they have already
      // read. Found by cloud review.
      decodedSamples = []
      guard generationAtStart == generation else { return }
      guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        state = .rejected(.noSpeechFound)
        return
      }
      rawTranscript = transcript
      phase = "Dividing it up to clean"
      await polishAll(TranscriptSplitter.split(transcript), generationAtStart: generationAtStart)
    } catch is CancellationError {
      decodedSamples = []
      // Stop already set the visible state; there is nothing to say.
    } catch {
      decodedSamples = []
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
      step = .done
      return
    }
    phase = "Cleaning it up"
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
    phase = ""
    state = .finished
    step = .done
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
