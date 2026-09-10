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
  /// before anything runs, and the design gives each choice its own screen with
  /// the specs needed to make it. The step bar is always visible and a completed
  /// step can be gone back to while nothing has run. The choices are the app's
  /// own settings, written through the same doors the Speech Engine and AI
  /// Polish pages use — see the note below `estimateText`.
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

  // The engines this import uses are NOT held here. The Transcription and
  // Polish steps read and write `SettingsManager` directly, the same way the
  // Speech Engine and AI Polish pages do, because those settings already have
  // owners that make a choice REAL: `EngineCoordinator` switches the speech
  // engine and loads its model, `PipelineSettingsSync` starts and stops the
  // polish runtimes, and `SettingsManager` canonicalizes `llmModel` when the
  // provider changes. Gate 2 approved reusing them ("ASR engines |
  // EngineCoordinator, settings.selectedBackend | Reuse").
  //
  // A per-import copy was tried and did none of that: picking All Languages
  // left Parakeet transcribing, and picking a polisher the app was not already
  // using sent the previous provider's model id to the new provider and never
  // started its server. Three defects, one cause, and the cause was holding a
  // second copy of a setting whose effects live elsewhere. Found by Codex.

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
    /// The engine chosen on the Transcription step is not downloaded.
    case engineNotInstalled
    /// It is installed but did not come up. The next Start retries.
    case engineNotReady
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

  /// A sentence about the last Save, or nil. Shown on Done, beside the buttons.
  ///
  /// **A failed save has to be LOUD**, because the next thing the user does is
  /// press New transcription, which clears the only copy of the document. A
  /// discarded write error — a full disk, a removed volume, a folder they cannot
  /// write to — meant they threw the words away believing they were on disk.
  /// Found by Codex.
  private(set) var saveMessage: String?

  func noteSaveSucceeded(fileName: String) { saveMessage = "Saved to \(fileName)." }

  /// Forgets the last save outcome. Called wherever the document is replaced or
  /// regenerated, because a stale "Saved to Meeting.txt" over words that have
  /// never been saved is the exact belief that makes a user press New
  /// transcription and lose them. Found by Codex.
  private func forgetSaveOutcome() {
    saveMessage = nil
    saveFailureDetail = nil
  }

  func noteSaveFailed(_ error: any Error) {
    saveMessage = "That file couldn't be saved. Your words are still here. Try another place."
    saveFailureDetail = String(describing: error)
  }

  /// The underlying failure, for the log. Never shown: the sentence above is
  /// what the user reads.
  private(set) var saveFailureDetail: String?

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
  ///
  /// **Held separately from `runConfiguration`, which is document metadata and
  /// is RESETTABLE.** Stop returns while the cancelled work still holds the
  /// engine; pressing New transcription in that window cleared the configuration
  /// and with it the pin, so a provider change could tear down a server the work
  /// was still inside. The pin now lives and dies with the physical hold. Found
  /// by Codex.
  var pinnedLocalPolishProvider: LLMProvider? {
    isEngineHeld ? heldLocalPolishProvider : nil
  }

  private var heldLocalPolishProvider: LLMProvider?

  /// The document as one piece of text, for copy and save.
  /// The document as one piece of text, for Copy and Save.
  ///
  /// **Falls back to the raw transcript, because the screen does.** Stopping
  /// during the FIRST passage leaves no finished parts and a full transcript,
  /// and Done renders those raw words — while Copy put nothing on the clipboard
  /// and Save wrote an empty file over the only copy the user had. Found by
  /// Codex. Reading the same value the page renders is what makes the two unable
  /// to disagree.
  var documentText: String {
    parts.isEmpty ? rawTranscript : parts.map(\.text).joined(separator: "\n\n")
  }

  /// Whether a run is in flight AS THE SCREEN SEES IT. Drives the sidebar dot,
  /// the Stop button and whether the wizard's steps are navigable.
  ///
  /// **Not a resource question.** Stop flips this the instant it is pressed,
  /// deliberately, while the cancelled work is still inside the engine.
  var isRunning: Bool {
    switch state {
    case .transcribing, .polishing: return true
    case .idle, .reading, .ready, .finished, .rejected, .stopped: return false
    }
  }

  /// Whether the run task still PHYSICALLY holds the shared engine.
  ///
  /// **Separate from `isRunning` because Stop separates them**, and every guard
  /// that protects a resource must read this one. `isRunning` goes false at the
  /// press; the claim is held until the cancelled transcription or polish call
  /// actually returns, because a Core ML decode cannot be stopped cooperatively.
  /// In that window a settings change reading `isRunning` would unload the ASR
  /// backend, or tear down the polish server, out from under work still using
  /// it. Found by Codex.
  private(set) var isEngineHeld = false

  // MARK: - Collaborators

  private let decode: @Sendable (URL) async throws -> AudioFileDecoder.Decoded
  private let transcribe: @MainActor ([Float]) async throws -> String
  private let engineAdmission: EngineAdmissionAccess

  /// Drives the SELECTED speech engine to active-and-warm, and says what
  /// happened. The composition root points this at
  /// `EngineCoordinator.ensureSelectedReadyForPress()`, the same authority a
  /// record press uses.
  ///
  /// **A run must not begin until this says ready.** Choosing All Languages
  /// while its model is not downloaded leaves the coordinator's active engine
  /// unchanged, so the import happily transcribed with the fast English engine
  /// while Review promised the other one. A switch still in flight produced the
  /// same mismatch. Found by Codex.
  ///
  /// Runs BEFORE the claim, deliberately: gate 6b defers an engine switch while
  /// an import holds the engine, so claiming first would make the switch wait
  /// for a run that is itself waiting for the switch.
  private let ensureEngineReady: @MainActor () async -> EngineReadiness

  /// Mirrors `EngineCoordinator.PressReadiness` without importing it, so this
  /// type keeps knowing nothing about who owns engine switching.
  enum EngineReadiness: Sendable, Equatable {
    case ready
    case notInstalled
    case notReady
  }

  /// Called once, on the main actor, after a run has physically released the
  /// shared engine. The composition root points it at the existing retry paths.
  let onEngineReleased: @MainActor () -> Void

  /// Whether the polish model selected RIGHT NOW is an Ollama model the daemon
  /// proxies to its own servers. Read live before a run for the page's privacy
  /// line, and frozen into `RunConfiguration` at Start so a finished document is
  /// never re-described by a later catalog refresh.
  let polishIsRemoteOllamaNow: @MainActor () -> Bool

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
    /// The polisher this run was configured with, for the line crediting the
    /// document. Reading LIVE settings there credited whatever was selected
    /// NOW: finishing with EG-1, pressing Change, picking Claude and returning
    /// to Done labelled unchanged EG-1 output as Claude's. Found by Codex.
    let polishProvider: LLMProvider
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
    polishIsRemoteOllamaNow: @escaping @MainActor () -> Bool = { false },
    ensureEngineReady: @escaping @MainActor () async -> EngineReadiness = { .ready },
    onEngineReleased: @escaping @MainActor () -> Void = {},
    beginRun: @escaping @MainActor () -> RunConfiguration,
    processPart: @escaping @MainActor (String) async throws -> FileImportRunner.PartOutcome
  ) {
    self.polishIsRemoteOllamaNow = polishIsRemoteOllamaNow
    self.ensureEngineReady = ensureEngineReady
    self.onEngineReleased = onEngineReleased
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
    forgetSaveOutcome()
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
        showRejection(Self.rejection(for: error))
      }
    }
  }

  /// Where a refusal is READ, which is not always where it was produced.
  ///
  /// A rejection raised during a run leaves the user on Working, where nothing
  /// renders it: a progress bar that will never move again, beside a Stop button
  /// that does nothing because `isRunning` is already false. A rejection raised
  /// at Start leaves them on Review with an inert button. Both go back to Upload,
  /// which is the one step that renders a refusal AND offers the way out of it —
  /// choosing another file. Found by Codex.
  private func showRejection(_ reason: FileImportRejection) {
    state = .rejected(reason)
    phase = ""
    // **Where a refusal is READ, and it depends on what the user would lose.**
    // With no document, Upload is the step that renders a refusal AND offers the
    // way out of it: another file. With one, Upload offers only the thing that
    // DESTROYS it — refusing "Clean it again" because a dictation is running
    // sent the user to a screen from which their finished transcript could not
    // be copied, saved or retried. Done renders the same refusal beside the
    // words. Found by Codex.
    jump(to: hasDocument ? .done : .upload)
  }

  /// Moves forward through the wizard. Refused once a run is in flight: the
  /// choices are frozen for the run, so a step that could still change them
  /// would be lying about what is about to happen.
  func advance() {
    guard !isRunning else { return }
    switch step {
    case .upload: jump(to: .transcription, advancing: true)
    case .transcription: jump(to: .polish, advancing: true)
    case .polish: jump(to: .review, advancing: true)
    // With a transcript already in hand, Start means POLISH AGAIN: the audio
    // has been read and transcribed, and re-doing either would be slower and
    // would produce the same words.
    case .review: rawTranscript.isEmpty ? start() : rePolish()
    case .working, .done: break
    }
  }

  /// Whether there is a document to go back TO. The single fact three of the
  /// rules below turn on.
  var hasDocument: Bool { !rawTranscript.isEmpty }

  /// Whether Back is offered right now, so the button is absent rather than
  /// present and inert.
  var canGoBack: Bool {
    guard let previous = Step(rawValue: step.rawValue - 1) else { return false }
    return canGo(to: previous)
  }

  /// Goes back one step, if that step is one the user may be on.
  func goBack() {
    guard let previous = Step(rawValue: step.rawValue - 1) else { return }
    jump(to: previous)
  }

  /// Takes the user back to the Polish step with the finished document intact.
  ///
  /// **Change is a request to choose, not a request to re-run.** It used to
  /// clear every finished passage and immediately re-run the SAME polisher,
  /// which threw the document away to reproduce it. The raw transcript is kept,
  /// so picking a different polisher and pressing Start again costs no re-read
  /// and no second transcription. Found by Codex.
  func choosePolisherAgain() {
    guard hasDocument else { return }
    jump(to: .polish)
  }

  /// **The ONE answer to "may the user be on this step right now".**
  ///
  /// Read by the step bar's `disabled`, by `jump(to:)`, by `goBack()` and by
  /// where a refusal lands. Three separate movers each had their own rule and
  /// each let the user reach a screen the finished document could not be
  /// reached from: the bar offered Working after a run, Back walked from Polish
  /// to Upload where Continue is refused because the state is finished, and a
  /// refusal sent the user to Upload whose only offer is choosing another file,
  /// which clears the document. Three findings, three rounds, one cause — so
  /// this is the rule, and nothing moves `step` without asking it.
  ///
  /// **The test that decides every case: can the user get back to their words?**
  /// - Parameter advancing: true only for Continue, which is the one mover that
  ///   goes FORWARD through a wizard the user has not finished. Without it this
  ///   predicate answered a narrower question than its name — backward step-bar
  ///   navigation — and `advance()` had to bypass it to work at all, which is
  ///   how a "single authority" ended up with five writers around it. Codex
  ///   round 4 enumerated them from the code and found the claim false.
  func canGo(to target: Step, advancing: Bool = false) -> Bool {
    guard !isRunning, target != step else { return false }
    switch target {
    // Never by navigation: it shows a run in progress, and after one there is
    // none. `start()` and `rePolish()` are the only ways in.
    case .working: return false
    // **The way back to the document, and the reason the others can be strict.**
    case .done: return hasDocument
    // Choosing another file is `startOver()`'s job, because it also has to clear
    // the document. Offering Upload with a document present is what stranded it.
    case .upload: return !hasDocument
    // With a document the choice steps go both ways: picking a different
    // polisher and returning to the words is a supported thing to do. Without
    // one, the bar only goes back and Continue is the only way forward — one
    // step at a time, and only once a file has actually been read.
    case .transcription, .polish, .review:
      guard file != nil else { return false }
      if hasDocument || target.rawValue < step.rawValue { return true }
      guard advancing, case .ready = state else { return false }
      return target.rawValue == step.rawValue + 1
    }
  }

  /// Takes the user to `target` if `canGo(to:advancing:)` allows it. **The only
  /// navigation writer.** Three writers remain outside it and are exceptions by
  /// construction, not by oversight:
  ///
  /// - `choose(url:)` and `startOver()` RESET to Upload while clearing what made
  ///   Upload unreachable, so asking a predicate about the state they are in the
  ///   middle of replacing would answer about the old one.
  /// - `start()`, `stop()`, `rePolish()` and `polishAll` move the user because
  ///   the WORK moved. They are not navigation and must not be refusable.
  func jump(to target: Step, advancing: Bool = false) {
    guard canGo(to: target, advancing: advancing) else { return }
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
    forgetSaveOutcome()
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

    // Refused at the press, not after the warm-up. See `currentHolder`.
    if let holder = engineAdmission.currentHolder() {
      showRejection(.engineBusy(holder))
      return
    }

    generation += 1
    let generationAtStart = generation
    step = .working
    // The engine may need switching or warming, which takes long enough to be
    // worth naming rather than showing a bar at 0% with no explanation.
    phase = "Getting the engine ready"
    state = .transcribing(fileName: name)

    runTask = Task { [weak self] in
      guard let self else { return }

      // 1. The engine the user picked, actually active and actually warm.
      let readiness = await ensureEngineReady()
      guard generationAtStart == generation else { return }
      switch readiness {
      case .notInstalled: showRejection(.engineNotInstalled); return
      case .notReady: showRejection(.engineNotReady); return
      case .ready: break
      }

      // 2. Only now claim, and only now freeze: the snapshot records the engine
      // that is running, which step 1 has just made true.
      let token: EngineLease.Token
      switch engineAdmission.claim() {
      case .granted(let granted): token = granted
      case .refused(let holder): showRejection(.engineBusy(holder)); return
      }
      isEngineHeld = true
      // **The claim goes back only here**, after the physical work has exited.
      // Releasing where Stop is DECIDED would let a dictation in while a
      // cancelled part was still inside the one-slot polish server.
      defer {
        engineAdmission.release(token)
        finishEngineHold()
      }
      runConfiguration = beginRun()
      // Pinned from the SAME freeze, so the pin cannot outlive or predate it.
      heldLocalPolishProvider = runConfiguration?.localPolishProvider
      phase = "Writing down what was said"

      await run(generationAtStart: generationAtStart)
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
      showRejection(.engineBusy(holder))
      return
    }

    runConfiguration = beginRun()
    // Pinned from the SAME freeze, so the pin cannot outlive or predate it.
    heldLocalPolishProvider = runConfiguration?.localPolishProvider

    generation += 1
    let generationAtStart = generation
    parts = []
    // The saved words are about to be replaced by different ones.
    forgetSaveOutcome()
    step = .working
    phase = "Cleaning it up"

    isEngineHeld = true
    runTask = Task { [weak self] in
      defer {
        self?.engineAdmission.release(token)
        self?.finishEngineHold()
      }
      guard let self else { return }
      await polishAll(
        TranscriptSplitter.split(rawTranscript), generationAtStart: generationAtStart)
    }
  }

  // MARK: - The run

  private func run(generationAtStart: Int) async {
    do {
      let transcript = try await transcribe(decodedSamples)
      // **The generation guard comes FIRST, before any shared write.** A slow
      // transcription that returns after the user stopped and chose another file
      // belongs to a run nobody is watching; clearing `decodedSamples` on the way
      // out erased the NEW file's audio while its Ready screen stayed up, and the
      // next Start then transcribed an empty buffer. Found by Codex.
      guard generationAtStart == generation else { return }
      releaseDecodedAudio()
      guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        showRejection(.noSpeechFound)
        return
      }
      rawTranscript = transcript
      phase = "Dividing it up to clean"
      await polishAll(TranscriptSplitter.split(transcript), generationAtStart: generationAtStart)
    } catch is CancellationError {
      guard generationAtStart == generation else { return }
      releaseDecodedAudio()
      // Stop already set the visible state; there is nothing to say.
    } catch {
      guard generationAtStart == generation else { return }
      releaseDecodedAudio()
      showRejection(Self.rejection(for: error))
    }
  }

  /// Ends the physical hold and wakes whatever deferred itself because of it.
  ///
  /// **A deferral needs a wake-up or it is just a stall.** `EngineCoordinator`
  /// defers a speech-engine switch while an import runs, `PipelineSettingsSync`
  /// defers tearing down a polish runtime this run pinned, and crash recovery
  /// defers a replay. All three were written to be retried when the blocker
  /// clears, and nothing was telling them it had. A settings change made during
  /// a long import then sat pending until some unrelated event happened to poke
  /// the same paths. Found by Codex.
  private func finishEngineHold() {
    isEngineHeld = false
    heldLocalPolishProvider = nil
    onEngineReleased()
  }

  /// Drops the decoded audio once the engine is done with it.
  ///
  /// At 16 kHz mono float this is ~230 MB per hour of recording, and a re-polish
  /// needs only `rawTranscript`, so holding it for the life of the app would cost
  /// the user hundreds of megabytes for a document they have already read. Found
  /// by cloud review. Only ever called after the generation guard, so it can
  /// never drop audio belonging to a NEWER selection.
  private func releaseDecodedAudio() { decodedSamples = [] }

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
