import CryptoKit
import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
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
    /// `done` parts of `total` have finished.
    ///
    /// **These numbers ARE user-facing now (#2772 finding 14).** The comment here used to
    /// say the opposite — "the user never sees these numbers as chunks" — and the Working
    /// step was built to that rule. The approved prototype contradicts it: its label reads
    /// "Cleaning part 9 of 14 with EG-1". Founder, on the shipped version: "the clean up was
    /// supposed to show # of chunks and it processing each chunk, not pasting the finished
    /// polished work in real-time." Under his standing instruction the prototype is the
    /// target, so the rule is retired and its reason is recorded in the PR that retired it.
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
    /// The bundled cleanup engine is installed but did not start. The words are already
    /// transcribed and saved; only the cleanup is refused, and Clean it again retries it.
    case polisherNotReady
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
    /// Whether a polisher actually produced these words (#2772 finding 12).
    ///
    /// **Not the inverse of `isUnpolished`.** That one asks whether this passage is SHOWING
    /// raw text and drives the note beneath it; this asks whether any polish ran at all, and
    /// drives the credit on the header. A document with no parts has neither, and the credit
    /// must not name an engine for work that never happened.
    var wasPolished: Bool = false
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
  /// The raw pieces this run will clean, in order, published so the Working step can show
  /// the QUEUE rather than only the finished text (#2772 finding 14).
  ///
  /// Empty until the split happens, and cleared by `startOver`/`choose` with everything else
  /// belonging to a document. The view pairs it with `parts.count` to know which row is
  /// being worked: the queue is fixed for a run and the finished count only grows.
  private(set) var pendingPieces: [String] = []

  /// "Cleaning part 9 of 14 with EG-1", or "" when nothing is being cleaned.
  ///
  /// The engine is the one FROZEN with the run, never the live selection: a user who
  /// changes their polisher while a run is going would otherwise watch the label credit an
  /// engine that is not doing the work. Same rule the Done screen already follows.
  var cleaningLabel: String {
    guard case .polishing(let done, let total) = state, total > 0 else { return "" }
    let engine = (runConfiguration?.polishProvider ?? .none).displayName
    return "Cleaning part \(min(done + 1, total)) of \(total) with \(engine)"
  }

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

  /// The Ollama model a RUNNING import has frozen, or nil.
  ///
  /// **A different pin from the one above, because it protects a different
  /// thing.** `pinnedLocalPolishProvider` stops a bundled server being torn
  /// down; this stops `reconcileOllamaEviction` unloading the WEIGHTS of the
  /// model this run's remaining passages are about to use. That rule's pin check
  /// reads the two dictation drivers' session configs, and an import has no
  /// session config, so its model was unprotected: changing provider mid-import
  /// evicted it, and every later passage paid a reload it could exceed its
  /// polish deadline waiting for, returning raw text. Found by Codex.
  var pinnedOllamaModel: String? {
    isEngineHeld ? heldOllamaModel : nil
  }

  private var heldLocalPolishProvider: LLMProvider?
  private var heldOllamaModel: String?

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
  /// Returns the words AND the language the engine reported, because the
  /// cleanup chain's language ladder prefers the engine's own answer over
  /// identifying one from the text. Reducing this to a bare `String` discarded
  /// the better source at the only place it existed.
  private let transcribe: @MainActor ([Float]) async throws -> ASRResult
  /// The dormant, phase-2 speaker step (#2809). Runs after ASR on the same PCM, bounded
  /// and cancellable — see `run(generationAtStart:)`. Defaults to reporting the models as
  /// unavailable rather than silently doing nothing, so a coordinator built without this
  /// closure fails the same way a real one would if the bundled models were missing.
  private let speakerLabeler: @MainActor ([Float], TimeInterval) async -> SpeakerAnalysis
  /// Shape-only telemetry for the dormant speaker step (#2809): the outcome, the file's
  /// own duration, how long analysis took, and the word-timing coverage ASR reported for
  /// the SAME run — never text, never a file name. No-op default so a coordinator built
  /// without this closure (most tests) simply emits nothing, same as every other
  /// telemetry-shaped closure in this app.
  private let emitSpeakerTelemetry:
    @MainActor (SpeakerAnalysis, TimeInterval, Int, ASRWordTimingCoverage?) -> Void

  /// Shape-only telemetry for the speaker turns (#2810 addendum §3a, #2851): outcome, the
  /// turn count (only meaningful on a successful store), and how many turns kept their raw
  /// words. No-op default, same as every other telemetry-shaped closure in this app.
  private let emitTurnTelemetry:
    @MainActor (TelemetryService.FileImportTurnsOutcome, Int?, Int) -> Void

  /// Shape-only telemetry for a rename attempt, a "Try again" press, and the first time this
  /// screen draws a turn view for a document (#2811, phase 4 of #2807 §3e) — No-op defaults,
  /// same as every other telemetry-shaped closure in this app.
  private let emitRenameTelemetry: @MainActor (TelemetryService.FileImportRenameOutcome) -> Void
  private let emitSpeakerRetryTelemetry:
    @MainActor (TelemetryService.FileImportSpeakerRetryOutcome) -> Void
  private let emitTurnsDisplayedTelemetry: @MainActor () -> Void
  /// Documents this wizard has already reported as displayed, so a Done step that re-appears
  /// (view mode flip, window re-open) reports each document once per launch, never per draw.
  private var displayedTurnHistoryIDs: Set<UUID> = []

  private let engineAdmission: EngineAdmissionAccess

  /// Stops both engines' pending model-unload timers, and puts the user's
  /// setting back. **Called as a PAIR, by one `defer`.**
  ///
  /// The first version disarmed them in `ensureEngineReady` and re-armed them in
  /// `onEngineReleased`, which only runs once a lease token has been acquired.
  /// Every exit before that — the engine not installed, a warm that did not
  /// take, a Stop landing during the readiness drive, a refusal because
  /// something else holds the claim — left both timers disarmed for the rest of
  /// the session, so the user's model-unload setting silently stopped applying.
  ///
  /// **Two rounds of cloud review found two different halves of this same
  /// bracket left undone**, so it is now one `defer` in one place rather than a
  /// pair of calls that have to be kept in step by remembering.
  private let disarmEngineTimers: @MainActor () -> Void
  private let rearmEngineTimers: @MainActor () -> Void

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

  /// Whether the selected engine still has a model resident. Asked once, after
  /// the claim, because the unload timer is only disarmed from that point on.
  private let engineIsLoaded: @MainActor () async -> Bool

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

  /// Where an Ollama polish would send the text, for the model selected NOW.
  ///
  /// **Three answers, and the third one is the point.** `true` proxied to
  /// Ollama's servers, `false` running on this Mac, `nil` the daemon has not
  /// been asked yet — which is the ordinary state after a relaunch, because the
  /// catalog is populated by the AI Polish page and a user who opens Transcribe
  /// a File directly has never been there. Collapsing `nil` into `false` made
  /// the page promise the transcript stays on this Mac while sending it to
  /// Ollama's servers. Found by Codex. A privacy promise may only be made from
  /// a KNOWN answer.
  let polishOllamaLocalityNow: @MainActor () -> Bool?

  /// Asks the daemon, so the answer above stops being `nil`. Called when the
  /// Polish step appears rather than at launch: it is one local request, and
  /// only this screen needs it.
  let refreshOllamaFacts: @MainActor () async -> Void

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
    /// The LOCAL Ollama model this run froze, if any, so the eviction rule can
    /// leave its weights alone while the run is using them. Nil for every other
    /// provider, for a model Ollama proxies to its own servers (no weights here
    /// to protect), and for one whose location is unknown — an unknown model is
    /// evicted by the existing rule on purpose, and pinning it would defer an
    /// eviction on a guess.
    let ollamaModel: String?
    /// The polish MODEL this run froze, for the History row's provenance. Same reason as
    /// `polishProvider` one field up: the row records what produced THESE words, and a live
    /// read would credit whatever is selected when the write happens (#2772).
    let polishModel: String
    /// The transcription engine this run froze, for the History row. Imports share the
    /// dictation engine (#2772 §3.2), so a live read here would be right today and wrong the
    /// moment the user changes engines between the raw save and the final update.
    let backendType: ASRBackendType
  }

  /// Freezes the configuration this run uses and returns it. Called once per
  /// run, before the first part — the founder's "one import, one configuration"
  /// call, so a settings change halfway through cannot produce a document
  /// polished two different ways.
  private let beginRun: @MainActor () -> RunConfiguration

  /// Brings THIS run's bundled polisher up, and waits for it.
  ///
  /// **Separate from `beginRun`, and the separation is the point.** Freezing stays
  /// synchronous, because `runConfiguration` is the finished document's disclosure and a
  /// test rightly pins that it is set the moment a run starts. Only the WAITING is async.
  ///
  /// Since #2772 the import's bundled polisher can differ from dictation's, so this run may
  /// be the thing that starts it, and a fire-and-forget start loses the race. Live UAT on
  /// 2026-09-10 measured exactly that: `provider=egOne, model=eg-1` requested, then
  /// `EG-1 polish skipped (notReady) after 0.2ms`, then `Local polish server ready` — the
  /// server came up two tenths of a millisecond after the part that needed it, and the user
  /// got raw words with nothing on screen saying why. No test found it; three review rounds
  /// argued about it; one forty-second clip settled it.
  /// Starts the bundled polisher this run froze, and says whether it came up. False is a
  /// refusal of the CLEANUP only, raised after the raw words are safe.
  ///
  /// The Continue gate admits an INSTALLED bundled engine whatever its server is doing and
  /// leaves health to the run (#2772 Live UAT). This is where the run asks. Its answer was
  /// discarded, so an engine that failed to start produced a whole document of raw words
  /// with no refusal anywhere: the polish step reads a missing endpoint as a silent skip.
  /// Found by the cloud review of PR #2786.
  private let prepareLocalPolish: @MainActor (RunConfiguration) async -> Bool

  /// What `prepareLocalPolish` answered for the run in flight. Read at the cleanup's entry,
  /// after the durability gate, so a refused cleanup still leaves the raw words in History.
  private var localPolisherIsReady = true

  /// Runs one part. A closure rather than the concrete `FileImportRunner` for
  /// one reason and it is not style: the property this type exists to hold —
  /// that Stop changes the screen at once while the claim waits for the work to
  /// exit — cannot be tested at all unless a test can make a part take as long
  /// as it likes.
  private let processPart: @MainActor (String, String?) async throws -> FileImportRunner.PartOutcome

  /// Writes this import to History, or throws.
  ///
  /// #2772 finding 11: the approved plan promised imports reach History in three places and
  /// none of it shipped. Founder: "We had agreed when planning this feature that
  /// transcriptions would be saved to history once done."
  ///
  /// Called TWICE per run and deliberately so. Once with the RAW words the moment
  /// transcription lands, before a single part is cleaned, and once with the finished
  /// document. Same id both times, so the second write UPDATES the first rather than
  /// creating a second row — `TranscriptStore` names its file by id.
  ///
  /// A closure rather than the concrete store because this type is tested without a disk,
  /// and because the FAILING case is the one that matters: a raw save that throws must stop
  /// the run before polish, per the approved plan, and a test cannot make a real store fail
  /// on demand.
  private let saveToHistory: @MainActor (Transcript) throws -> Void

  /// The SECOND write, which may only ever update. Returns false when the row is no longer
  /// in History, which means the user deleted it while the cleanup ran.
  ///
  /// Separate from `saveToHistory` because they are different operations, not one operation
  /// with a flag: the first CREATES and must be allowed to, the second may not.
  private let updateHistoryRow: @MainActor (Transcript) throws -> Bool

  /// The speaker-fields write (#2810 addendum §3 E), separate from `updateHistoryRow` because
  /// it merges speaker fields against the row's CURRENT state at call time — never a value
  /// captured earlier — which is what makes it safe against a rename racing this write.
  /// Returns false when the row is no longer in History, same meaning as `updateHistoryRow`.
  private let mergeSpeakerFields:
    @MainActor (UUID, TranscriptSpeakerAnalysis, [Turn]?) throws -> Bool

  /// The rename write (#2811, phase 4 of #2807) — a SEPARATE closure from `mergeSpeakerFields`
  /// rather than a widened one, so every existing turn-storage call site (which never renames)
  /// stays untouched. Backed by the SAME `TranscriptCoordinator.mergeSpeakerFields
  /// (explicitRename:)` method underneath (no new coordinator method, per §4's contract
  /// delta) — this coordinator's own rename entry point re-reads the row's current analysis
  /// and turns via `currentHistoryRow` immediately before calling this, never reusing a value
  /// captured when a popover opened. Defaults to a harmless failure so tests that do not
  /// exercise rename need not wire it.
  private let writeExplicitRename:
    @MainActor (UUID, TranscriptSpeakerAnalysis, [Turn]?, (speakerId: String, name: String))
      throws -> Bool

  /// Whether the import's row is in History RIGHT NOW. Every "saved" answer on this page
  /// goes through it, because a remembered write is not a row: the user can delete the row
  /// from History at any moment after either write, including after a Stop that ends the
  /// run before the cleaned write would have noticed. Found by the cloud review of PR #2786,
  /// the second route to the same defect.
  private let historyRowExists: @MainActor (UUID) -> Bool

  /// The row's CURRENT state, read fresh at call time — never `originalHistoryRow`'s own
  /// cached copy (#2811, phase 4 of #2807). Two callers need this: `savePolishedToHistory`'s
  /// rename-safety fix (carries the live speaker fields forward rather than reverting them to
  /// a stale snapshot) and this coordinator's own rename/retry entry points, which must read
  /// the row's current analysis and turns TOGETHER, atomically, rather than reusing a value
  /// captured earlier (§3 Design correction). Defaults to "no row" so tests that do not
  /// exercise rename/retry need not wire it.
  private let currentHistoryRow: @MainActor (UUID) -> Transcript?

  /// The row this import first wrote, kept whole rather than as an id.
  ///
  /// **Rebuilding it per write was wrong in three ways at once**, all found by Codex: a
  /// fresh `Transcript` takes `Date()` for `createdAt`, so the raw and final writes
  /// disagreed about when the recording happened; a re-polish after the user changed the
  /// shared transcription engine credited an engine that never ran; and there was no record
  /// of what had actually been persisted. Holding the original means every later write is
  /// that row plus the one thing that changed.
  private var originalHistoryRow: Transcript?

  /// The last version that reached the store. `isSavedToHistory` compares it to what is ON
  /// SCREEN, so a Stop after one cleaned part cannot claim the partial document was saved.
  private var savedHistoryRow: Transcript?

  /// ONE identity across the raw save, the final update and any number of re-polishes.
  var historyID: UUID? { originalHistoryRow?.id }

  /// Whether the raw words are in History under `historyID` right now. A re-polish arriving
  /// without them saves the raw row first: the case a user reaches by re-polishing a document
  /// whose original save failed, and the case where they deleted the row and are asking for
  /// the work again, which writes it anew on purpose.
  private var rawIsSavedToHistory: Bool {
    guard let historyID, savedHistoryRow != nil else { return false }
    return historyRowExists(historyID)
  }

  /// Set when the raw save fails. The run stops before polish and the Done screen offers the
  /// raw words with Copy and Retry, per the approved plan's failure table: losing the words
  /// silently is worse than not cleaning them.
  private(set) var historySaveFailure: String?

  /// Whether the user deleted this import from History after it was written there.
  ///
  /// Not a failure: nothing went wrong and there is nothing to retry. A separate fact
  /// because the notice that fits it is different, and because reusing the failure field
  /// would put a retry offer under a deletion the user meant. Derived, never remembered:
  /// a flag set by the cleaned write missed every deletion that write did not observe,
  /// which is any deletion followed by a Stop, and any deletion after Done.
  var historyRowWasDeleted: Bool {
    guard let historyID, savedHistoryRow != nil else { return false }
    return !historyRowExists(historyID)
  }

  /// **Generation protects STATE. Terminal completion protects the RESOURCE.**
  /// Neither substitutes for the other, and this coordinator needs both: Stop
  /// changes what the user sees at once and bumps this, so a late part cannot
  /// write into a run the user has already ended — while the claim is released
  /// only from the run task's own `defer`, after the physical work has exited.
  private(set) var generation = 0
  private var runTask: Task<Void, Never>?

  init(
    decode: @escaping @Sendable (URL) async throws -> AudioFileDecoder.Decoded,
    transcribe: @escaping @MainActor ([Float]) async throws -> ASRResult,
    speakerLabeler: @escaping @MainActor ([Float], TimeInterval) async -> SpeakerAnalysis = {
      _, _ in .failed(.modelsUnavailable)
    },
    emitSpeakerTelemetry: @escaping @MainActor (
      SpeakerAnalysis, TimeInterval, Int, ASRWordTimingCoverage?
    ) -> Void = { _, _, _, _ in },
    emitTurnTelemetry: @escaping @MainActor (TelemetryService.FileImportTurnsOutcome, Int?, Int) ->
      Void = { _, _, _ in },
    emitRenameTelemetry: @escaping @MainActor (TelemetryService.FileImportRenameOutcome) -> Void = {
      _ in
    },
    emitSpeakerRetryTelemetry: @escaping @MainActor (
      TelemetryService.FileImportSpeakerRetryOutcome
    ) -> Void = { _ in },
    emitTurnsDisplayedTelemetry: @escaping @MainActor () -> Void = {},
    engineAdmission: EngineAdmissionAccess,
    polishOllamaLocalityNow: @escaping @MainActor () -> Bool? = { false },
    refreshOllamaFacts: @escaping @MainActor () async -> Void = {},
    engineIsLoaded: @escaping @MainActor () async -> Bool = { true },
    disarmEngineTimers: @escaping @MainActor () -> Void = {},
    rearmEngineTimers: @escaping @MainActor () -> Void = {},
    ensureEngineReady: @escaping @MainActor () async -> EngineReadiness = { .ready },
    onEngineReleased: @escaping @MainActor () -> Void = {},
    beginRun: @escaping @MainActor () -> RunConfiguration,
    // True is "nothing to prepare", which is what a coordinator with no bundled polisher has.
    prepareLocalPolish: @escaping @MainActor (RunConfiguration) async -> Bool = { _ in true },
    // No defaults (#2772): a coordinator built without History closures would report every
    // run as saved, and the general test factory did exactly that. A caller that means to
    // simulate History says so at the call site.
    saveToHistory: @escaping @MainActor (Transcript) throws -> Void,
    updateHistoryRow: @escaping @MainActor (Transcript) throws -> Bool,
    mergeSpeakerFields:
      @escaping @MainActor (UUID, TranscriptSpeakerAnalysis, [Turn]?) throws -> Bool,
    // Defaulted, unlike the four closures above (#2772's "no defaults" rule protects the
    // MAIN import write path — every new import always calls those four; rename and retry
    // are opt-in UI actions most tests never exercise, so a harmless default here does not
    // risk a silently-wrong "saved" answer the way defaulting the core writes would).
    writeExplicitRename: @escaping @MainActor (
      UUID, TranscriptSpeakerAnalysis, [Turn]?, (speakerId: String, name: String)
    ) throws -> Bool = { _, _, _, _ in false },
    currentHistoryRow: @escaping @MainActor (UUID) -> Transcript? = { _ in nil },
    historyRowExists: @escaping @MainActor (UUID) -> Bool,
    processPart:
      @escaping @MainActor (String, String?) async throws -> FileImportRunner.PartOutcome
  ) {
    self.polishOllamaLocalityNow = polishOllamaLocalityNow
    self.refreshOllamaFacts = refreshOllamaFacts
    self.ensureEngineReady = ensureEngineReady
    self.engineIsLoaded = engineIsLoaded
    self.disarmEngineTimers = disarmEngineTimers
    self.rearmEngineTimers = rearmEngineTimers
    self.onEngineReleased = onEngineReleased
    self.decode = decode
    self.transcribe = transcribe
    self.speakerLabeler = speakerLabeler
    self.emitSpeakerTelemetry = emitSpeakerTelemetry
    self.emitTurnTelemetry = emitTurnTelemetry
    self.emitRenameTelemetry = emitRenameTelemetry
    self.emitSpeakerRetryTelemetry = emitSpeakerRetryTelemetry
    self.emitTurnsDisplayedTelemetry = emitTurnsDisplayedTelemetry
    self.engineAdmission = engineAdmission
    self.beginRun = beginRun
    self.prepareLocalPolish = prepareLocalPolish
    self.saveToHistory = saveToHistory
    self.updateHistoryRow = updateHistoryRow
    self.mergeSpeakerFields = mergeSpeakerFields
    self.writeExplicitRename = writeExplicitRename
    self.currentHistoryRow = currentHistoryRow
    self.historyRowExists = historyRowExists
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
    // Same reason as `startOver`: a different file must not read as though the LAST
    // file's speaker analysis was about this one (found by second-pass review).
    speakerAnalysis = nil
    // #2811, phase 4: same reason, and the same points `decodedSamples` itself resets — a
    // retained retry from the LAST file must never fire against this one.
    speakerStepState = .notStarted
    retainedAnalysisSamples = []
    retainedWordTimings = nil
    retainedWordTimingCoverage = nil
    // Detached from `runTask` (see `run()`), so choosing a new file while a PRIOR
    // file's speaker step is still quietly running in the background must stop it
    // itself, not rely on Stop having already done so.
    speakerStepTask?.cancel()
    // And a run still in flight. Since #2851 nothing runs behind Done, so after Done this
    // is a no-op.
    runTask?.cancel()
    resetTurnAlignment()
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
    // Same rule as `startOver`: a different file is a different row (#2772).
    originalHistoryRow = nil
    documentView = .cleaned
    timesOn = true
    markedUpCache = nil
    markedUpWorker?.task.cancel()
    markedUpWorker = nil
    turnDiffCache = nil
    turnDiffWorker?.task.cancel()
    turnDiffWorker = nil
    savedHistoryRow = nil
    historySaveFailure = nil
    pendingPieces = []
    state = .reading(fileName: name)
    // **Cancelled, not merely ignored.** The generation check discards a stale
    // result AFTER the work is done, which is the right answer to "whose file is
    // this" and no answer at all to "should this still be running". A three-hour
    // recording decodes to about 690 MB of samples; picking a second file while
    // the first is reading left both decodes running and both arrays growing,
    // for a result one of them was always going to throw away. `AudioFileDecoder`
    // already checks cancellation inside its read loop, so this stops it in the
    // middle rather than at the end. Found by Codex.
    decodeTask?.cancel()
    decodeTask = Task { [weak self] in
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
      } catch is CancellationError {
        // Superseded by another file. The newer decode owns the screen.
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
  /// Whether this refusal is about the ENGINE rather than the file.
  ///
  /// **The difference decides what the user has to redo.** A file we could not
  /// read needs a different file. A busy engine, a missing model or a warm-up
  /// that did not take needs nothing redone at all — the audio is decoded and in
  /// memory, and the message says "try again". It did not mean it: the only
  /// route back was choosing the file again and paying the read a second time,
  /// which on a long recording is the slowest part. Found by Codex.
  static func isAboutTheEngine(_ reason: FileImportRejection) -> Bool {
    switch reason {
    case .engineBusy, .engineNotInstalled, .engineNotReady: return true
    // About the POLISHER, not the transcription engine: nothing needs reading again, so
    // Try again (which re-transcribes) is the wrong offer. The document is in hand, the
    // refusal renders beside it on Done, and Review's Clean it again is the retry.
    case .cannotRead, .noAudio, .noSpeechFound, .polisherNotReady, .failed: return false
    }
  }

  /// Whether there is audio in hand to run, however the screen got here: a file
  /// that decoded cleanly, or one whose run was refused for a reason about the
  /// ENGINE rather than the file.
  var isReadyToRun: Bool {
    if case .ready = state { return true }
    return canRetry
  }

  /// Whether Try again is offered: an engine refusal, with the audio still here.
  var canRetry: Bool {
    guard case .rejected(let reason) = state else { return false }
    return Self.isAboutTheEngine(reason) && !decodedSamples.isEmpty && file != nil
  }

  /// Puts the already-decoded file back in hand and starts it again.
  func retry() {
    guard canRetry, let file else { return }
    // Back to the state `start()` requires. The user is already standing on
    // Review, where the refusal placed them and where Try again is.
    state = .ready(fileName: file.name, seconds: file.seconds)
    start()
  }

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
    //
    // An ENGINE refusal with the audio still in hand stays on Review, where Try
    // again is, because nothing about the file needs redoing.
    step =
      if hasDocument {
        // Done renders the refusal above the words it did not touch. Upload
        // would offer only the thing that destroys them.
        .done
      } else if canRetry {
        // Already read, nothing to redo: stay where Try again is.
        .review
      } else {
        // The one step that renders a refusal AND offers the way out: a
        // different file.
        .upload
      }
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

  /// Whether the Done screen is showing the ORIGINAL words instead of the
  /// cleaned ones.
  ///
  /// **The page promises "Original kept" and "Your untouched words are kept
  /// beside this one", and nothing showed them.** Once the first cleaned passage
  /// landed, the raw transcript was in memory and unreachable — no view rendered
  /// it, and Copy and Save exported only the cleaned passages. A promise with no
  /// way to check it is a promise the product does not keep. Found by Codex.
  var documentView: DocumentView = .cleaned

  /// Times on/off for turn-labeled rendering and export (#2811, phase 4 of #2807). A
  /// per-view-session UI toggle, never a persisted preference (plan §2.2 non-goal) —
  /// defaults ON and resets at the same points `documentView` itself resets, matching that
  /// property's own "screen-local, not carried across documents" contract.
  var timesOn = true

  /// Which words the Done screen shows (#2773). Copy, Save and Share follow Cleaned and
  /// Original; the marked-up view has no plain-text form, so it exports the CLEANED text.
  enum DocumentView: Equatable, Sendable {
    case cleaned
    /// The original words with the cleanup marked on them: removed struck through, altered
    /// highlighted, and the counts above. The founder's request: "people can quickly see
    /// that it worked" instead of reading two blobs of prose.
    case markedUp
    case original
  }

  /// What the marked-up view compares the original against: the cleaned parts, then any
  /// passage the cleanup never reached, unchanged. After a Stop, `documentText` holds only
  /// the finished parts, and comparing the whole original against that marked every waiting
  /// passage as REMOVED by a cleanup that never touched it. Found by Codex (chunk review).
  /// Comparison only; Copy, Save and Share still export `documentText`.
  var markedUpInput: MarkedUpInput {
    // With no split in hand (nothing has run) the whole transcript is one untouched passage.
    guard !pendingPieces.isEmpty else {
      return MarkedUpInput(
        passages: [.init(original: rawTranscript, cleaned: nil)], language: engineReportedLanguage)
    }
    return MarkedUpInput(
      passages: placedPassages().map { .init(original: $0.original, cleaned: $0.cleaned) },
      language: engineReportedLanguage)
  }

  /// One cleanup passage as the scan placed it in the raw transcript (#2851 §3c: computed
  /// ONCE here and shared by the marked-up view and the turn-text alignment).
  struct PlacedPassage: Equatable, Sendable {
    let placement: TurnTextAligner.Passage.Placement
    /// The passage's original text: from the previous cursor to the piece's end, so the gap
    /// BEFORE the piece rides with it; the unplaceable case carries the piece itself.
    let original: String
    let cleaned: String?
    /// False when this passage's polish was attempted and failed; also false, and unread,
    /// while the cleanup has not reached it (`cleaned == nil`).
    let wasPolished: Bool
  }

  /// The split's pieces are the passages the cleanup ran on, in order; `parts[i]` is what it
  /// made of `pendingPieces[i]`. A piece past the last finished part was never reached.
  /// Each passage's original is recovered FROM the transcript, not taken from the piece:
  /// `TranscriptSplitter` slices from a word's start to a word's end and drops the
  /// whitespace between pieces, so the pieces concatenated rendered "alphaalpha" across a
  /// cut. Each piece is found by scanning forward, and the passage is the text from the
  /// cursor to the piece's end, so the gap BEFORE a piece rides with it; the last passage
  /// runs to the transcript's end. Every gap renders exactly as spoken. A piece the scan
  /// cannot place should not happen (the splitter yields ordered verbatim slices); if it
  /// did, that piece is compared directly, marked unplaceable for the aligner, and the
  /// cursor does not advance, so later pieces still place by their own scan (Codex,
  /// confirming round; #2851 P5).
  func placedPassages() -> [PlacedPassage] {
    var cursor = rawTranscript.startIndex
    var passages: [PlacedPassage] = []
    for (index, piece) in pendingPieces.enumerated() {
      let cleaned = index < parts.count ? parts[index].text : nil
      // `!isUnpolished`, not `wasPolished` (#2851 §3 D): the turns' flag drives the
      // "Not fully polished" disclosure, and a document the user chose not to have polished
      // is not a document with fourteen problems in it (`PartOutcome.isUnpolished`'s own
      // rule). The header's credit reads `Part.wasPolished` and is unchanged.
      let wasPolished = index < parts.count ? !parts[index].isUnpolished : false
      guard
        let found = rawTranscript.range(
          of: piece, options: .literal, range: cursor..<rawTranscript.endIndex)
      else {
        passages.append(
          PlacedPassage(
            placement: .unplaceable, original: piece, cleaned: cleaned, wasPolished: wasPolished))
        continue
      }
      let end = index == pendingPieces.count - 1 ? rawTranscript.endIndex : found.upperBound
      let rawRange = cursor.utf16Offset(in: rawTranscript)..<end.utf16Offset(in: rawTranscript)
      let contentRange =
        found.lowerBound.utf16Offset(in: rawTranscript)..<end.utf16Offset(in: rawTranscript)
      passages.append(
        PlacedPassage(
          placement: .placed(rawRange: rawRange, contentRange: contentRange),
          original: String(rawTranscript[cursor..<end]), cleaned: cleaned,
          wasPolished: wasPolished))
      cursor = end
    }
    return passages
  }

  /// The passages, not a joined text: this is read on every redraw as the view's task id and
  /// as the cache key, and the strings inside are the coordinator's own, shared not copied.
  /// Passage by passage because that is how the cleanup ran; one joined block lost the
  /// boundaries and could mark untouched waiting words as removed (second-pass review).
  struct MarkedUpInput: Equatable, Sendable {
    let passages: [WordDiff.Passage]
    /// The engine's language code for the transcript, which decides the case fold (Turkish
    /// has two I's). Part of the key so a re-transcription in another language recomputes.
    let language: String?
  }

  /// The comparison, once `prepareMarkedUp` has run for the current input; nil while it is
  /// still being made or the input moved. Kept while the two texts it was made from stand.
  /// OBSERVED, deliberately: the write lands from `prepareMarkedUp` after an await, never
  /// during a body evaluation, and it is the mutation that replaces the placeholder with the
  /// result. Ignoring it left the view on "Comparing words" until an unrelated redraw. Codex,
  /// round 2.
  private var markedUpCache: (input: MarkedUpInput, result: WordDiff.Result)?
  var markedUp: WordDiff.Result? {
    guard let cached = markedUpCache, cached.input == markedUpInput else { return nil }
    return cached.result
  }

  /// Runs the comparison OFF the main actor. Cleanup-shaped inputs take milliseconds, but the
  /// algorithm is linear in the edit distance too, and two transcripts with nothing in common
  /// took three seconds at the three-hour size; done in a getter that froze the window.
  /// Found by Codex (chunk review). A result for an input that moved while it ran is dropped.
  func prepareMarkedUp() async {
    let input = markedUpInput
    guard markedUp == nil else { return }
    // ONE comparison per input. Leaving the view cancels its task but not the detached work,
    // and coming back before it finished used to start a second; switching back and forth on
    // a large, heavily rewritten transcript piled them up. A worker for a different input is
    // cancelled (its result is dropped; the algorithm itself runs to its end, bounded by the
    // worst case noted on `WordDiff`), and a worker for THIS input is awaited, not repeated.
    // Second-pass review.
    if let inFlight = markedUpWorker, inFlight.input != input {
      inFlight.task.cancel()
      markedUpWorker = nil
    }
    let task: Task<WordDiff.Result, Never>
    if let inFlight = markedUpWorker {
      task = inFlight.task
    } else {
      task = Task.detached(priority: .userInitiated) {
        WordDiff.compare(passages: input.passages, language: input.language)
      }
      markedUpWorker = (input, task)
    }
    let result = await task.value
    guard markedUpInput == input else { return }
    if markedUpWorker?.input == input { markedUpWorker = nil }
    markedUpCache = (input, result)
  }

  @ObservationIgnored private var markedUpWorker:
    (input: MarkedUpInput, task: Task<WordDiff.Result, Never>)?

  /// Whether the words on screen are the RAW ones: the user asked for them, or there is no
  /// cleaned part to show instead.
  ///
  /// ONE answer to "what is the screen showing", read by the export text, the saved badge and
  /// the view. Each had been answering it on its own, and the badge's copy had only the
  /// second half: after a Stop with one cleaned part and Show original words pressed, the
  /// screen and Copy both had the raw transcript, which was saved, while the badge compared
  /// the partial cleaned document and said it was not. Found by the cloud review of
  /// PR #2786, and the same shape as the credit it fixed earlier: a status about what was
  /// held rather than what was shown.
  var screenShowsRawWords: Bool { documentView == .original || parts.isEmpty }

  /// What Copy and Save hand over, which is always what the screen is showing.
  ///
  /// Turn-labeled documents route through the presenter FIRST (#2811, phase 4 of #2807) —
  /// its own `exportText` returns `nil` for `turns == nil`/empty, which is exactly when this
  /// falls through to the EXISTING selection below, unchanged (plan §9: "each screen keeps
  /// calling its OWN existing fallback UNCHANGED"). Never both: the presenter's fallback for
  /// `.markedUp` is the CLEANED text, not `markedUpKeptText`, since a turn's own
  /// `processedText` is what cleanup actually produced for that turn.
  var exportText: String {
    if let turns,
      let result = TranscriptDocumentPresenter.exportText(
        turns: turns, rawText: rawTranscript, speakerNames: speakerNames, timesOn: timesOn,
        mode: documentView)
    {
      return result.text
    }
    if screenShowsRawWords { return rawTranscript }
    if documentView == .markedUp { return markedUpKeptText }
    return documentText
  }

  /// Copy/Save/Share titles. The founder's export rule (plan §2.1) is general, not scoped to
  /// turn-labeled documents: `exportText` above already substitutes the CLEANED text for
  /// `.markedUp` on every document, turn-labeled or not, so the label disclosure applies
  /// uniformly too — never gated on `turns != nil`.
  var exportButtonLabels: (copy: String, save: String, share: String) {
    TranscriptDocumentPresenter.exportButtonLabels(mode: documentView)
  }

  /// What the marked-up view presents as KEPT: the cleaned passages, then every passage the
  /// cleanup never reached, unchanged. After a Stop that is more than `documentText`, which
  /// holds only the finished passages, and an export that dropped the visible tail would
  /// hand over less than the screen shows. Found by the cloud review of PR #2799. On a
  /// finished run the two are the same text.
  var markedUpKeptText: String {
    // The cleaned passages as `documentText` joins them, then the untouched passages as the
    // TRANSCRIPT has them: each recovered original begins with the whitespace that preceded
    // it, so nothing is invented between them. Joining the split's pieces with a blank line
    // changed a single space or tab into a paragraph break. Found by the cloud review.
    let cleaned = parts.map(\.text).joined(separator: "\n\n")
    let untouched = markedUpInput.passages.dropFirst(parts.count).map(\.original).joined()
    return cleaned + untouched
  }

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
      // **A retryable file goes forward exactly like a ready one.** Refused for
      // a busy engine, the user goes Back to pick a different one — and could
      // not come forward again, because this asked for `.ready` and a refusal
      // leaves `.rejected`. The audio is decoded and in hand either way, which
      // is the only thing "forward" depends on. Found by Codex.
      guard advancing, isReadyToRun else { return false }
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
  /// - `showRejection(_:)` PLACES the user where a refusal can be read and acted
  ///   on. That destination is chosen by what they would LOSE, not by where they
  ///   asked to go, and on a refusal raised from Review it is Review itself —
  ///   which `canGo` refuses by construction, since it never returns true for
  ///   the step you are already on.
  func jump(to target: Step, advancing: Bool = false) {
    guard canGo(to: target, advancing: advancing) else { return }
    step = target
  }

  /// Clears everything and returns to an empty Upload step.
  func startOver() {
    guard !isRunning else { return }
    decodeTask?.cancel()
    decodeTask = nil
    generation += 1
    file = nil
    parts = []
    rawTranscript = ""
    decodedSamples = []
    runConfiguration = nil
    // A different file is a different speaker analysis — the prior file's outcome must
    // not survive to be read against this one (found by second-pass review).
    speakerAnalysis = nil
    // #2811, phase 4: same reason, same reset point as `decodedSamples`.
    speakerStepState = .notStarted
    retainedAnalysisSamples = []
    retainedWordTimings = nil
    retainedWordTimingCoverage = nil
    speakerStepTask?.cancel()
    // And a run still in flight. Since #2851 nothing runs behind Done, so after Done this
    // is a no-op.
    runTask?.cancel()
    resetTurnAlignment()
    forgetSaveOutcome()
    // A new file is a NEW History row. Carrying the id forward would make the next import
    // overwrite the last one's words, because the store names its file by id — which is the
    // same property that makes the raw-then-polished pair an update rather than a duplicate.
    originalHistoryRow = nil
    documentView = .cleaned
    timesOn = true
    markedUpCache = nil
    markedUpWorker?.task.cancel()
    markedUpWorker = nil
    turnDiffCache = nil
    turnDiffWorker?.task.cancel()
    turnDiffWorker = nil
    savedHistoryRow = nil
    historySaveFailure = nil
    pendingPieces = []
    state = .idle
    step = .upload
  }

  /// The decoded audio, held between `choose` and `start` so pressing Start does
  /// not read the file a second time.
  private var decodedSamples: [Float] = []

  /// The in-flight read, so replacing or clearing the file can stop it.
  private var decodeTask: Task<Void, Never>?

  /// The speaker step's ANALYZER outcome, held in memory for telemetry and the log
  /// (#2809 addendum §3 B3). This is the in-memory, analyzer-only value — phase 4's UI reads
  /// the STORED outcome instead (via `currentHistoryRow`/`speakerStepState` together), since
  /// several branches downstream of this (missing timings, admission refusal, polisher
  /// unavailable) either downgrade or never touch what gets persisted (§3 Design "failure
  /// authority" correction). Kept for telemetry/log continuity, not read directly by any view.
  private(set) var speakerAnalysis: SpeakerAnalysis?

  /// UI-facing lifecycle signal for the phase-3 speaker/turn-storage pass (#2811 §4 contract
  /// deltas): "is the invisible step currently running," nothing about its outcome. Neither
  /// `speakerAnalysis` (analyzer-only) nor the stored `speakerAnalysis` field alone can
  /// distinguish not-started from in-progress from a `.single` result with nothing to say, so
  /// this is tracked explicitly. Transitions exactly once per run/retry:
  /// `.notStarted` → `.inProgress` → `.finished`, whatever the outcome (success, failure, or
  /// Stop all reach `.finished`); reset to `.notStarted` at the same points `speakerAnalysis`
  /// itself resets.
  enum SpeakerStepState: Equatable, Sendable { case notStarted, inProgress, finished }
  private(set) var speakerStepState: SpeakerStepState = .notStarted

  /// The ONE line the Done step shows for background speaker work, or nil for none: the
  /// analysis itself. Since #2851 nothing runs a second cleanup behind Done, so there is no
  /// count to show; the turns appear raw as soon as they exist and their text turns clean
  /// as each cleanup part lands (`refreshTurnTexts`).
  var speakerStatusLabel: String? {
    speakerStepState == .inProgress ? "Finding speakers" : nil
  }

  // MARK: - Turn text alignment (#2851)

  /// Everything the alignment depends on, so a result is committed only against the SAME
  /// state it was computed from (plan §3 B: document identity alone cannot reject a result
  /// made obsolete by a later part, a re-polish or a retry on the same document).
  struct AlignInput: Equatable, Sendable {
    struct TurnKey: Equatable, Sendable {
      let id: String
      let speakerId: String
      let range: Range<Int>
    }
    let historyID: UUID
    let rawText: String
    let language: String?
    let cleanupRevision: Int
    let cleanupComplete: Bool
    let passages: [TurnTextAligner.Passage]
    let turns: [TurnKey]
  }

  /// The one alignment job in flight (compute off-main, then commit on the main actor) and
  /// the input it was computed from. Cleared by the job itself, after its commit.
  @ObservationIgnored private var alignWorker: (input: AlignInput, job: Task<Void, Never>)?
  /// Set by the cleanup's own completion BEFORE the final alignment is requested, and part
  /// of `AlignInput`, so the worker's commit knows it is the final one (plan §3 B, grounded
  /// review round 3). Reset with the document.
  @ObservationIgnored private var cleanupComplete = false
  /// `file_import_turns` is once per document: `mergeAndReport` emits the FIRST terminal
  /// outcome it reports for a document (`stored` at the alignment commit that finds the
  /// cleanup complete and the turns present, whichever landed last; or `save_failed`,
  /// `row_deleted`, `no_word_timings`, `single_no_turns` from the pass that reached them)
  /// and logs every later one without emitting (whole-diff review: an intermediate write
  /// that threw used to emit `save_failed` and the final commit `stored` for one import).
  @ObservationIgnored private var turnsTelemetryEmittedFor: UUID?

  /// A new document: nothing computed for the old one may land, and the once-per-import
  /// event is owed again.
  private func resetTurnAlignment() {
    alignWorker?.job.cancel()
    alignWorker = nil
    cleanupComplete = false
    turnsTelemetryEmittedFor = nil
  }

  private func currentAlignInput() -> AlignInput? {
    guard let historyID, let current = currentHistoryRow(historyID),
      case .labeled = current.speakerAnalysis, let turns = current.turns, !turns.isEmpty,
      !pendingPieces.isEmpty
    else { return nil }
    return AlignInput(
      historyID: historyID, rawText: rawTranscript, language: engineReportedLanguage,
      cleanupRevision: generation, cleanupComplete: cleanupComplete,
      passages: placedPassages().map {
        TurnTextAligner.Passage(
          placement: $0.placement, cleaned: $0.cleaned, wasPolished: $0.wasPolished)
      },
      turns: turns.map { .init(id: $0.id, speakerId: $0.speakerId, range: $0.originalTextRange) })
  }

  /// Places the cleanup's words onto the stored turns and persists what changed (#2851 §3 B).
  /// Called after the raw turns persist, after each cleanup part lands, after a retry, and
  /// once more with `cleanupComplete` set. Returns only once the CURRENT input has been
  /// aligned and committed (or found unchanged): one job runs at a time; a caller finding
  /// a job on the same input shares it, and one finding a job on an older input waits for
  /// it and then runs its own, so the newest input is always the last one persisted and
  /// Done (`polishAll`'s final call) follows the final commit, never merely requests it.
  /// The commit re-validates the input and the row's existence immediately before the
  /// write, with no suspension point in between.
  func refreshTurnTexts() async {
    while let inFlight = alignWorker {
      // The job clears `alignWorker` on the main actor before its value resolves, so the
      // re-check sees either nothing or a job another waiter started first. A caller
      // returns only once a job has aligned exactly the CURRENT input: if the input moved
      // on while it waited (a part landed), it goes round again (whole-diff review).
      await inFlight.job.value
      if !inFlight.job.isCancelled, inFlight.input == currentAlignInput() { return }
    }
    guard let input = currentAlignInput() else { return }
    let job = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.alignAndCommit(input)
    }
    alignWorker = (input, job)
    await job.value
  }

  private func alignAndCommit(_ input: AlignInput) async {
    defer { if alignWorker?.input == input { alignWorker = nil } }
    let task = Task.detached(priority: .userInitiated) {
      TurnTextAligner.align(
        rawText: input.rawText, passages: input.passages,
        turns: input.turns.map {
          Turn(
            id: $0.id, speakerId: $0.speakerId, startMs: nil, endMs: nil,
            originalTextRange: $0.range)
        },
        language: input.language)
    }
    let outcome = await withTaskCancellationHandler(
      operation: { await task.value },
      onCancel: { task.cancel() }
    )
    // Commit, with nothing suspending between this re-validation and the write.
    guard !Task.isCancelled, currentAlignInput() == input,
      let current = currentHistoryRow(input.historyID),
      case .labeled(let labeledCount) = current.speakerAnalysis, let stored = current.turns
    else { return }
    let byID = Dictionary(uniqueKeysWithValues: outcome.texts.map { ($0.turnID, $0) })
    let patched = stored.map { turn -> Turn in
      guard let text = byID[turn.id] else { return turn }
      // A passage the cleanup has not reached yet says nothing about its turns: on a
      // "Clean it again" they keep their last cleaned text until the matching passage
      // lands (plan §2.5; chunk 3 review). Every other fallback is this cleanup's verdict.
      if outcome.fallbacks[turn.id] == .unreached { return turn }
      return Turn(
        id: turn.id, speakerId: turn.speakerId, startMs: turn.startMs, endMs: turn.endMs,
        originalTextRange: turn.originalTextRange, processedText: text.processedText,
        wasPolished: text.wasPolished)
    }
    let uncut = outcome.texts.filter { !$0.cleanedCut }.count
    let changed = patched != stored
    let emitsFinal = input.cleanupComplete && turnsTelemetryEmittedFor != input.historyID
    guard changed || emitsFinal else { return }
    let reasons = outcome.fallbacks.values
    await AppLogger.shared.log(
      "[TurnAlign] turns=\(stored.count) aligned=\(stored.count - uncut) uncut_boundary=\(reasons.filter { $0 == .boundary }.count) uncut_unplaced=\(reasons.filter { $0 == .unplaced }.count) uncut_unreached=\(reasons.filter { $0 == .unreached }.count) uncut_emptied=\(reasons.filter { $0 == .emptied }.count) final=\(emitsFinal)",
      level: .info, category: "FileImportCoordinator")
    // Re-check after the log's own suspension: same input, same row.
    guard !Task.isCancelled, currentAlignInput() == input else { return }
    await mergeAndReport(
      historyID: input.historyID, analysis: .labeled(count: labeledCount),
      turns: changed ? patched : stored, outcome: emitsFinal ? .stored : nil,
      turnCount: stored.count, fallbackTurnCount: uncut, passStart: CFAbsoluteTimeGetCurrent())
  }

  /// Retained PCM for a possible "Try again" (#2811 §3 Design "retained retry state"
  /// correction): a genuinely NEW retention this phase adds, since `releaseDecodedAudio()`
  /// already clears `decodedSamples` immediately after transcription, well before a retry
  /// would exist to need it. Cleared at the points `decodedSamples` itself resets
  /// (`choose(url:)`, `startOver()`), so a stale retry can never fire against a replaced
  /// document, AND as soon as a pass settles on an outcome no retry could change
  /// (`releaseRetryInputsIfNoLongerRetryable`, found by cloud review of PR #2846): this
  /// coordinator lives for the process, and a multi-hour import's buffer is hundreds of
  /// megabytes to hold behind a screen the user has left.
  private var retainedAnalysisSamples: [Float] = []
  private var retainedWordTimings: [ASRWordTiming]?
  private var retainedWordTimingCoverage: ASRWordTimingCoverage?

  /// Test-facing: whether a "Try again" still has audio to run against.
  var retainsRetryInputs: Bool { !retainedAnalysisSamples.isEmpty }

  /// Whether the retained timing data could ever bind a speaker: `nil` timings, or a
  /// coverage with zero timed entries (a space-free script, #2838), can only reach
  /// `.failed(.noWordTimings)` again however the analyzer segments the audio, since a retry
  /// reruns the analyzer and never the ASR or the timing mapper. A present-but-partial
  /// coverage stays retryable: assembly binds whatever entries ARE timed, and a different
  /// segmentation can bind them differently.
  private var retainedTimingsCanBindSpeakers: Bool {
    guard retainedWordTimings != nil else { return false }
    if let coverage = retainedWordTimingCoverage, coverage.timed == 0 { return false }
    return true
  }

  /// The one reading of "could a retry change this stored outcome", shared by the button
  /// and by the release of the retained audio, so the two can never disagree.
  private func retryCouldChange(_ analysis: TranscriptSpeakerAnalysis?) -> Bool {
    switch analysis {
    case .single, .labeled: return false
    case .failed(.noWordTimings): return retainedTimingsCanBindSpeakers
    case .failed, .unanalyzed, nil: return true
    }
  }

  /// Frees the retained retry inputs once the CURRENT document's stored outcome is one no
  /// retry could change. Reads the stored field, never the in-memory analyzer property, so
  /// a save that threw (row still at its previous retryable outcome) keeps them. A row that
  /// no longer exists is terminal too (cloud review of PR #2846, round 2): a retry has
  /// nothing to write against, and `canRetrySpeakerAnalysis` already reads false for it.
  private func releaseRetryInputsIfNoLongerRetryable() {
    guard let historyID else { return }
    if let current = currentHistoryRow(historyID), retryCouldChange(current.speakerAnalysis) {
      return
    }
    releaseRetryInputs()
  }

  /// History deleted a row (wired from `TranscriptCoordinator.onRowDeleted`). Drops the retry
  /// audio and stops the background speaker pass still aimed at that row (never a visible
  /// run in flight, whose own save already refuses a deleted row; since #2851 nothing runs
  /// behind Done, and an alignment commit re-checks the row exists). A row the user later
  /// resurrects with "Clean it again" comes back without speaker fields and without a
  /// retry: the audio for it is gone, on purpose.
  func noteHistoryRowDeleted(_ id: UUID) {
    guard id == historyID else { return }
    releaseRetryInputs()
    speakerStepTask?.cancel()
  }

  private func releaseRetryInputs() {
    retainedAnalysisSamples = []
    retainedWordTimings = nil
    retainedWordTimingCoverage = nil
  }

  /// Bumped only by a successful `renameSpeaker` (#2811, phase 4 of #2807). `turns`/
  /// `speakerNames` below read through `currentHistoryRow`, a plain closure the `@Observable`
  /// macro cannot see into — so nothing tells a view depending on them to re-render after a
  /// rename lands anywhere else (the wizard's own popover, or History's). Reading this
  /// alongside them inside their own getters gives Observation a real stored-property
  /// dependency to invalidate on. A background turn-storage pass or a retry needs no such
  /// bump: both already flip the genuinely-tracked `speakerStepState`, which a view showing
  /// "Finding speakers" already depends on.
  private(set) var speakerFieldsRevision = 0

  /// The wizard's own document turns, read fresh from the live store on every access — this
  /// coordinator never caches them itself, so a background pass finishing, a retry, or a
  /// rename is always reflected. `nil` under the exact same conditions
  /// `TranscriptDocumentPresenter.render` treats as "nothing turn-shaped to show."
  var turns: [Turn]? {
    _ = speakerFieldsRevision
    guard let historyID else { return nil }
    return currentHistoryRow(historyID)?.turns
  }

  /// `speakerId -> display name` for the current document, read fresh alongside `turns`.
  var speakerNames: [String: String] {
    _ = speakerFieldsRevision
    guard let historyID else { return [:] }
    return currentHistoryRow(historyID)?.speakerNames ?? [:]
  }

  /// One turn's original/cleaned pair, computed once per `turnDiffInput` build. Wrapped in a
  /// struct rather than a tuple because a tuple array is neither `Equatable` nor usable as an
  /// `Equatable` cache key.
  struct TurnDiffPair: Equatable, Sendable {
    let id: String
    let original: String
    let cleaned: String
  }

  struct TurnDiffInput: Equatable, Sendable {
    let pairs: [TurnDiffPair]
    let language: String?
  }

  /// The id of both screens' diff task: the input AND whether Marked up is the selected view,
  /// so the per-turn diffs are computed only while something would show them (found by
  /// cloud review, round 7: a long labeled recording opened in Cleaned mode diffed every turn
  /// at user-initiated priority for nothing). Switching to Marked up changes the id and starts
  /// the work then; switching away cancels it.
  struct TurnDiffRequest: Equatable, Sendable {
    let input: TurnDiffInput
    let markedUp: Bool
  }

  /// The current turns' own original/cleaned pairs, mirroring `markedUpInput`'s role but for
  /// per-turn Marked-up rendering (#2811, phase 4 of #2807) — the presenter's `render` never
  /// computes `WordDiff` itself (chunk-1 review), so this is the CALLER-side preparation it
  /// consumes via `diffLookup`.
  var turnDiffInput: TurnDiffInput {
    guard let turns else { return TurnDiffInput(pairs: [], language: engineReportedLanguage) }
    let text = rawTranscript
    let pairs = turns.map { turn -> TurnDiffPair in
      let original = TranscriptDocumentPresenter.slice(text, turn.originalTextRange)
      return TurnDiffPair(id: turn.id, original: original, cleaned: turn.processedText ?? original)
    }
    return TurnDiffInput(pairs: pairs, language: engineReportedLanguage)
  }

  private var turnDiffCache: (input: TurnDiffInput, results: [String: WordDiff.Result])?

  /// `nil` while `prepareTurnDiffs` is still running or the input has moved — same OBSERVED
  /// contract as `markedUp`.
  var turnDiffs: [String: WordDiff.Result]? {
    guard let cached = turnDiffCache, cached.input == turnDiffInput else { return nil }
    return cached.results
  }

  /// Computes every current turn's diff OFF the main actor in ONE batched pass, exactly
  /// mirroring `prepareMarkedUp`'s single-flight, cancel-on-mismatch shape — never per-turn
  /// caching, which would multiply that machinery by the turn count for no benefit, since all
  /// of a document's turns become stale together (a new analysis pass, a retry, or a
  /// `processedText` change replaces the whole array at once).
  func prepareTurnDiffs() async {
    let input = turnDiffInput
    guard turnDiffs == nil, !input.pairs.isEmpty else { return }
    if let inFlight = turnDiffWorker, inFlight.input != input {
      inFlight.task.cancel()
      turnDiffWorker = nil
    }
    let task: Task<[String: WordDiff.Result], Never>
    // A worker that was cancelled (the Done view left mid-batch) returns a PARTIAL dictionary;
    // reusing it would cache that partial result for good, and the missing turns would show
    // unmarked cleaned text forever (found by cloud review, round 6). Only a live worker is
    // shared; a cancelled one is replaced.
    if let inFlight = turnDiffWorker, !inFlight.task.isCancelled {
      task = inFlight.task
    } else {
      task = Task.detached(priority: .userInitiated) {
        var results: [String: WordDiff.Result] = [:]
        for pair in input.pairs {
          // Between compares, never mid-compare: an obsolete document's worker (file
          // replaced, retry changed the turns, Start Over) stops at the next turn instead of
          // diffing every remaining one (found by cloud review, round 4).
          guard !Task.isCancelled else { break }
          results[pair.id] = WordDiff.compare(
            original: pair.original, cleaned: pair.cleaned, language: input.language)
        }
        return results
      }
      turnDiffWorker = (input, task)
    }
    // `Task.detached` is UNSTRUCTURED: cancelling THIS caller (`.task(id:)` on an input change)
    // does not reach the worker by itself, same as `assembleTurnsOrPersistTerminal`'s own
    // assembly task. The handler forwards it; the worker is single-flight per input, so the
    // only caller awaiting it is the one whose input just went stale.
    let result = await withTaskCancellationHandler(
      operation: { await task.value },
      onCancel: { task.cancel() }
    )
    // Released on EVERY return path, cancelled included, so the next visit with the same
    // input starts a fresh worker instead of adopting this one's partial result.
    if turnDiffWorker?.input == input { turnDiffWorker = nil }
    guard !Task.isCancelled, turnDiffInput == input else { return }
    turnDiffCache = (input, result)
  }

  @ObservationIgnored private var turnDiffWorker:
    (input: TurnDiffInput, task: Task<[String: WordDiff.Result], Never>)?

  /// The in-flight speaker step, run detached from `run()`'s own completion — it touches
  /// no ASR engine and must never add its own deadline (20s minimum) to the user-visible
  /// polish latency every import already pays (found by cloud review: awaiting it inline
  /// before polish blocked every successful import on this dormant, invisible limb).
  /// Cancelled by `stop()`/a new `choose()`/`startOver()`, same as `decodeTask`.
  private var speakerStepTask: Task<Void, Never>?

  /// SHA-256 over the raw Float32 bytes of the PCM ASR consumed, so a retry can compare a
  /// re-decoded source against what actually ran without re-reading the whole buffer.
  /// #2809 addendum §2.5 "Retry identity" — a method with a unit test and no caller in
  /// phase 2; phase 4's retry-after-failure UI is the first caller.
  static func pcmDigestHex(_ samples: [Float]) -> String {
    samples.withUnsafeBufferPointer { buffer in
      let digest = SHA256.hash(data: Data(buffer: buffer))
      return digest.map { String(format: "%02x", $0) }.joined()
    }
  }

  /// What the engine said this recording's language was, kept so a re-polish
  /// uses the same evidence the first run did rather than falling back to
  /// guessing from the text.
  private var engineReportedLanguage: String?

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
      case .notInstalled:
        showRejection(.engineNotInstalled)
        return
      case .notReady:
        showRejection(.engineNotReady)
        return
      case .ready: break
      }

      // 2. Only now claim, and only now freeze: the snapshot records the engine
      // that is running, which step 1 has just made true.
      let token: EngineLease.Token
      switch engineAdmission.claim() {
      case .granted(let granted): token = granted
      case .refused(let holder):
        showRejection(.engineBusy(holder))
        return
      }
      isEngineHeld = true
      // **The unload-timer bracket lives INSIDE the claim, and that placement is
      // the fix.** Put around the whole task it also fired on the paths where
      // this run never got the claim — and `ensureEngineReady()` suspends, so
      // another workload can take the lease while it is running. The `defer`
      // then re-armed the timers under SOMEBODY ELSE'S run, which is the same
      // unload it exists to prevent, aimed at a different victim. Found by cloud
      // review, one round after the leak it was fixing.
      //
      // Nothing is lost by disarming later: a timer that fires between the
      // readiness drive and here unloads a model the readiness postcondition has
      // already confirmed, and the re-check below reloads it.
      disarmEngineTimers()
      // **The claim goes back only here**, after the physical work has exited.
      // Releasing where Stop is DECIDED would let a dictation in while a
      // cancelled part was still inside the one-slot polish server.
      defer {
        rearmEngineTimers()
        engineAdmission.release(token)
        finishEngineHold()
      }
      // The timer above could have fired while we were claiming. Cheap to ask,
      // and the alternative is transcribing on an engine that just unloaded.
      //
      // **Both awaits are suspension points a Stop can land in**, and this one
      // was added by the previous fix — for WhisperKit, readiness hops to the
      // backend actor, so the window is real rather than theoretical. Neither
      // await throws on cancellation, so without the guard a stopped run carried
      // on and transcribed. Found by cloud review.
      if await engineIsLoaded() == false {
        guard generationAtStart == generation else { return }
        guard await ensureEngineReady() == .ready else {
          guard generationAtStart == generation else { return }
          showRejection(.engineNotReady)
          return
        }
      }
      guard generationAtStart == generation else { return }

      let configuration = beginRun()
      runConfiguration = configuration
      // Pinned from the SAME freeze, so the pin cannot outlive or predate it.
      heldLocalPolishProvider = configuration.localPolishProvider
      heldOllamaModel = configuration.ollamaModel
      phase = "Writing down what was said"
      localPolisherIsReady = await prepareLocalPolish(configuration)
      guard generationAtStart == generation else { return }

      await run(generationAtStart: generationAtStart)
    }
  }

  /// Stop changes what the user sees at once and keeps whatever is finished.
  /// The claim is not released here — see `start`.
  func stop() {
    // Unconditional, BEFORE the `isRunning` guard (#2810 addendum §2.5 item 4): the
    // background speaker pass can still be running after the visible screen already shows
    // Done, and `choose(url:)`/`startOver()` already cancel it unconditionally in exactly
    // that situation. A direct Stop press must behave the same way. Cancelling a nil or
    // already-finished task is a documented no-op.
    //
    // `runTask` joins it here: it only ever holds a run (`start()`/`rePolish()`), so
    // cancelling it outside a run is a no-op, and inside one it is the point.
    speakerStepTask?.cancel()
    runTask?.cancel()
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
    // **Released HERE, because the run task can no longer do it.** Every
    // `releaseDecodedAudio()` sits behind the generation guard — deliberately,
    // so a late task cannot erase a file the user has since chosen — and `stop()`
    // bumps the generation, so after a Stop both the late-success and the
    // cancellation path return at that guard and the samples stayed resident for
    // the life of the app. Hundreds of megabytes on the multi-hour recordings
    // this feature advertises. Found by cloud review; introduced by the fix that
    // moved the guard in front of the release.
    //
    // Safe because Stop is terminal for this audio: `start()` requires `.ready`
    // and Stop leaves `.stopped`, `canRetry` requires a rejection about the
    // ENGINE, and a re-polish reads `rawTranscript`. Nothing left can want it.
    releaseDecodedAudio()
    // `runTask` and `speakerStepTask` are both already cancelled unconditionally above,
    // before this guard.
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

    let configuration = beginRun()
    runConfiguration = configuration
    // Pinned from the SAME freeze, so the pin cannot outlive or predate it.
    heldLocalPolishProvider = configuration.localPolishProvider
    heldOllamaModel = configuration.ollamaModel

    generation += 1
    let generationAtStart = generation
    parts = []
    // The turns follow the new cleanup part by part (#2851): a turn keeps its last cleaned
    // text until its passage lands again (`alignAndCommit` leaves unreached turns alone).
    // This is a fresh cleanup, so its own completion is what the final alignment waits for.
    cleanupComplete = false
    // #2772 finding 14: the OLD queue must not be shown as the current one while this run
    // is still preparing. Cleared here and republished by `polishAll` from the new split.
    pendingPieces = []
    // The saved words are about to be replaced by different ones.
    forgetSaveOutcome()
    step = .working
    // **An ACTIVE state, not the previous terminal one.** A re-polish left `state` at
    // `.finished` while it awaited `prepareLocalPolish`, so `isRunning` was false during a
    // wait that can take seconds: the sidebar dot stayed dark on a job that was running and
    // Stop could not act on it. The first run has always used `.transcribing` for exactly
    // this window. Found by Codex.
    state = .transcribing(fileName: file?.name ?? "Recording")
    phase = "Preparing cleanup"

    isEngineHeld = true
    runTask = Task { [weak self] in
      defer {
        self?.engineAdmission.release(token)
        self?.finishEngineHold()
      }
      guard let self else { return }
      // #2772: wait for THIS run's polisher before asking it to polish anything. The screen
      // is already on Working, so the wait is behind a progress bar rather than in front of
      // a page that still says Review.
      localPolisherIsReady = await prepareLocalPolish(configuration)
      guard generationAtStart == generation else { return }
      await polishAll(
        TranscriptSplitter.split(rawTranscript), generationAtStart: generationAtStart)
    }
  }

  // MARK: - The run

  private func run(generationAtStart: Int) async {
    // Captured BEFORE the first await (#2809 addendum §3 B4): the success-path release
    // below (`releaseDecodedAudio()`) clears the coordinator's OWN `decodedSamples`, so the
    // speaker step — which runs after that release — must work from its own array, not the
    // coordinator's variable, or it would receive an empty buffer.
    let analysisSamples = decodedSamples
    do {
      let result = try await transcribe(decodedSamples)
      // **The generation guard comes FIRST, before any shared write.** A slow
      // transcription that returns after the user stopped and chose another file
      // belongs to a run nobody is watching; clearing `decodedSamples` on the way
      // out erased the NEW file's audio while its Ready screen stayed up, and the
      // next Start then transcribed an empty buffer. Found by Codex.
      guard generationAtStart == generation else { return }
      // AFTER the guard. It sat one line above it, which predates this chunk and did not
      // matter while nothing persisted it. History does now, so a superseded run could
      // stamp its language onto a row belonging to the file the user replaced. Found by
      // Codex.
      engineReportedLanguage = result.language
      releaseDecodedAudio()
      guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        showRejection(.noSpeechFound)
        return
      }
      rawTranscript = result.text
      // ADDED earlier gate (#2809 addendum §3 B4): the speaker step only ever runs on words
      // already durable. `polishAll`'s own gate at its entry stays — it also protects the
      // re-polish path, which never reaches here.
      guard rawIsSavedToHistory || saveRawToHistory() else {
        finishRun(savingDocument: false)
        return
      }
      // Launched, never awaited here: the speaker step must not add its own deadline
      // (20s minimum, scaling with file length) to every import's polish latency for a
      // dormant limb nothing shows yet — awaiting it before `polishAll` did exactly that
      // (found by cloud review). It runs fully detached from this function and from the
      // engine claim `start()` holds: the step touches no ASR engine, so there is nothing
      // for holding the claim through it to protect. `stop()` cancels it directly; a
      // superseded run's own generation guards inside `runSpeakerStep` discard its result
      // either way.
      speakerStepTask?.cancel()
      // Captured HERE, not re-read later: identifies which DOCUMENT this background pass is
      // for, independent of `generation` — `rePolish()` ("Clean it again") bumps `generation`
      // for the SAME document without restarting speaker analysis, and the OLD generation
      // check alone used to make this pass discard the only analysis this document will ever
      // get (found by cloud review). `choose`/`startOver` still invalidate this correctly:
      // both reset `originalHistoryRow` before any later save gives it a new id.
      let historyIDAtStart = historyID
      // #2811, phase 4: retained for a possible "Try again," a genuinely NEW retention this
      // phase adds — `analysisSamples` itself is a local (freed once this function returns),
      // and `wordTimings`/`wordTimingCoverage` were never stored at all before. Cleared at the
      // points `decodedSamples` itself resets, and once the pass settles on an outcome no
      // retry could change (see the declaration).
      retainedAnalysisSamples = analysisSamples
      retainedWordTimings = result.wordTimings
      retainedWordTimingCoverage = result.wordTimingCoverage
      speakerStepState = .inProgress
      speakerStepTask = Task { [weak self] in
        await self?.runSpeakerStep(
          analysisSamples: analysisSamples, generationAtStart: generationAtStart,
          historyIDAtStart: historyIDAtStart, rawText: result.text,
          wordTimings: result.wordTimings, wordTimingCoverage: result.wordTimingCoverage)
      }
      phase = "Dividing it up to clean"
      await polishAll(
        TranscriptSplitter.split(result.text), generationAtStart: generationAtStart)
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

  /// The phase-2 speaker step, now feeding phase-3 turn assembly and storage (#2810
  /// addendum §3 C-E). Runs the bounded, cancellable analysis on the captured PCM, guards
  /// on DOCUMENT IDENTITY once more before recording anything. `speakerAnalysis` (in-memory,
  /// analyzer-only) is read only by telemetry and the log; `speakerStepState` (#2811, phase 4)
  /// is the UI-facing signal, set to `.finished` here on EVERY exit path via `defer` — success,
  /// an early return, or cancellation — but only for the document this pass was FOR, so a
  /// stale completion can never mark a NEWER document's own in-progress pass as finished.
  private func runSpeakerStep(
    analysisSamples: [Float], generationAtStart: Int, historyIDAtStart: UUID?, rawText: String,
    wordTimings: [ASRWordTiming]?, wordTimingCoverage: ASRWordTimingCoverage?
  ) async {
    defer {
      if historyIDAtStart == historyID {
        speakerStepState = .finished
        releaseRetryInputsIfNoLongerRetryable()
      }
    }
    let durationSeconds = file?.seconds ?? 0
    let analysisStart = CFAbsoluteTimeGetCurrent()
    let outcome = await speakerLabeler(analysisSamples, durationSeconds)
    let analysisMs = Int(((CFAbsoluteTimeGetCurrent() - analysisStart) * 1000).rounded())
    // Gates on the DOCUMENT this pass is for, not on `generation`: `rePolish()` ("Clean it
    // again") bumps `generation` for the SAME document without restarting speaker analysis,
    // and gating on generation alone made a re-polish right after import discard the only
    // analysis this document will ever get (found by cloud review). `choose`/`startOver`
    // still invalidate this correctly — both reset `originalHistoryRow` before any later
    // save gives it a new id. A genuine Stop is caught by `!Task.isCancelled`, since `stop()`
    // does not always bump `generation` either (a direct Stop press after the visible run
    // already finished leaves it untouched).
    guard historyIDAtStart == historyID, !Task.isCancelled else { return }
    speakerAnalysis = outcome
    await AppLogger.shared.log(
      "[SpeakerLabeler] outcome=\(Self.speakerLogOutcome(outcome)) speakers=\(Self.speakerLogCount(outcome)) ms=\(analysisMs)",
      level: .info, category: "FileImportCoordinator")
    // The log line above is itself a suspension point; re-check rather than assume the
    // first guard still holds by the time telemetry fires. Found by Codex.
    guard historyIDAtStart == historyID, !Task.isCancelled else { return }
    emitSpeakerTelemetry(outcome, durationSeconds, analysisMs, wordTimingCoverage)

    await runTurnStorage(
      outcome: outcome, wordTimings: wordTimings, rawText: rawText,
      generationAtStart: generationAtStart, historyIDAtStart: historyIDAtStart)
  }

  /// Phase 3: turn assembly, background turn-safe cleanup, and storage (#2810 addendum §3
  /// C-E, §2.5 item 4). Never awaited by `run()` — reached only from `runSpeakerStep`, itself
  /// already fully detached. Sequenced strictly after the visible document's own cleanup
  /// finishes, and claims the same engine admission the visible run does for its own
  /// duration, exactly as round 2 of the addendum's review settled.
  private func runTurnStorage(
    outcome: SpeakerAnalysis, wordTimings: [ASRWordTiming]?, rawText: String,
    generationAtStart: Int, historyIDAtStart: UUID?
  ) async {
    // NEVER named `historyID` — that would SHADOW the live computed property for the rest of
    // this function, turning every `historyIDAtStart == historyID` guard below into a
    // comparison of two constants that can never diverge, silently neutering the staleness
    // check they exist to perform (found by chunk review, in the sibling `retrySpeakerAnalysis`
    // this pattern was copied into — fixed here too since the class is the same).
    guard let historyIDForWrite = historyID else { return }
    let passStart = CFAbsoluteTimeGetCurrent()

    // Every STALENESS check gates on document identity (see `runSpeakerStep`'s comment):
    // `rePolish()` bumps `generation` for the SAME document without restarting this pass,
    // and gating on generation alone discarded the only analysis a document would ever get
    // (found by cloud review). A genuine Stop is caught by `!Task.isCancelled`, which
    // `stop()`'s unconditional cancel sets regardless of whether it also bumped `generation`.
    guard historyIDAtStart == historyID, !Task.isCancelled else { return }

    guard
      let (assembledTurns, labeledCount) = await assembleTurnsOrPersistTerminal(
        outcome: outcome, wordTimings: wordTimings, historyIDForWrite: historyIDForWrite,
        historyIDAtStart: historyIDAtStart, passStart: passStart)
    else { return }
    guard historyIDAtStart == historyID, !Task.isCancelled else { return }

    // #2851: the turns persist RAW, immediately, so the labels show within seconds of the
    // words; no engine claim, no polisher, no second cleanup. Their cleaned text comes from
    // the one document cleanup by alignment (`refreshTurnTexts`), part by part. The
    // once-per-import `file_import_turns` event is the alignment's to emit, on completion.
    await mergeAndReport(
      historyID: historyIDForWrite, analysis: .labeled(count: labeledCount),
      turns: assembledTurns, outcome: nil, turnCount: assembledTurns.count,
      fallbackTurnCount: 0, passStart: passStart)
    await AppLogger.shared.log(
      "[TurnStorage] raw turns=\(assembledTurns.count) ms=\(Self.elapsedMs(since: passStart))",
      level: .info, category: "FileImportCoordinator")
    guard historyIDAtStart == historyID, !Task.isCancelled else { return }
    await refreshTurnTexts()
  }

  /// The analysis/assembly PREFIX shared by the ordinary post-import pass
  /// (`runTurnStorage`) and a "Try again" retry (#2811 §3 Design: "the two entry points share
  /// the analysis/assembly PREFIX and the persistence step; only the cleanup SUFFIX
  /// differs"). Extracted rather than duplicated, since a future fix to any of these three
  /// branches (non-labeled, missing timings, all-unknown) would otherwise need applying twice.
  ///
  /// `nil` means a terminal outcome was already persisted by THIS call (non-labeled, missing
  /// timings, or all-unknown), or the pass went stale/cancelled mid-assembly — either way the
  /// caller must stop, writing nothing further. Non-nil hands back turns ready for EITHER
  /// cleanup (the ordinary path) or direct persistence (retry, which skips cleanup).
  private func assembleTurnsOrPersistTerminal(
    outcome: SpeakerAnalysis, wordTimings: [ASRWordTiming]?, historyIDForWrite: UUID,
    historyIDAtStart: UUID?, passStart: CFAbsoluteTime
  ) async -> (turns: [Turn], labeledCount: Int)? {
    // `historyIDForWrite`, NEVER `historyID` — that name would SHADOW the live computed
    // property for this whole function, turning every `historyIDAtStart == historyID` guard
    // below into a comparison of two constants that can never diverge (found by chunk review).
    // Non-labeled outcomes map directly through the one exhaustive mapping (chunk 1) and
    // never touch turn assembly. A missing `wordTimings` matters ONLY when assembly is
    // actually needed — checking it before the outcome type would let a merge-input gap
    // silently override a perfectly good `.single`/`.failed`/`.timedOut` result that has
    // nothing to do with timings (found by chunk review).
    guard case .labeled(let labeledCount, let segments) = outcome else {
      // `.single` is the one non-labeled outcome worth a turn-storage telemetry event of
      // its own (there is genuinely nothing to store, by design). `.failed`/`.timedOut`/
      // `.cancelled` are ANALYZER outcomes `emitSpeakerTelemetry` already reported moments
      // earlier — `nil` here means "write silently, do not double-report."
      let turnsOutcome: TelemetryService.FileImportTurnsOutcome? =
        if case .single = outcome { .singleNoTurns } else { nil }
      await mergeAndReport(
        historyID: historyIDForWrite, analysis: outcome.asStorageAnalysis, turns: nil,
        outcome: turnsOutcome, turnCount: nil, fallbackTurnCount: 0, passStart: passStart)
      return nil
    }
    guard let wordTimings else {
      await mergeAndReport(
        historyID: historyIDForWrite, analysis: .failed(.noWordTimings), turns: nil,
        outcome: .noWordTimings, turnCount: nil, fallbackTurnCount: 0, passStart: passStart)
      return nil
    }

    // Off the main actor: a multi-hour, highly segmented recording's O(words × segments)
    // scan would otherwise run synchronously on this MainActor-isolated method and freeze
    // the UI before the background cleanup even claims the engine (found by cloud review).
    // `entries`/`segments`/`Turn` are all `Sendable` value types, so handing the pure
    // computation to a detached task changes nothing about its result.
    //
    // `Task.detached` is UNSTRUCTURED: cancelling THIS task (e.g. `stop()`'s unconditional
    // `speakerStepTask?.cancel()`) would not by itself cancel the detached child, leaving it
    // to run the full scan to completion and this task waiting on it the whole time
    // (found by cloud review). `withTaskCancellationHandler` propagates cancellation into
    // the child explicitly; `TurnAssembler.assemble`'s own loop checks `Task.isCancelled`
    // per entry so the propagated cancellation actually shortens the scan.
    let assemblyTask = Task.detached(priority: .utility) {
      TurnAssembler.assemble(entries: wordTimings, segments: segments)
    }
    let assembledTurns = await withTaskCancellationHandler(
      operation: { await assemblyTask.value },
      onCancel: { assemblyTask.cancel() }
    )
    // A stale/cancelled pass writes NOTHING here, matching every other staleness guard in
    // this file — the caller must not fall through to the all-unknown check below and
    // persist a failure on behalf of a document nobody is watching anymore. Compares against
    // the LIVE `historyID` property, never `historyIDForWrite` — a value captured once at
    // entry cannot detect a document swap that happened during this `await`.
    guard historyIDAtStart == historyID, !Task.isCancelled else { return nil }

    // A space-free script (Chinese, Japanese, ...) makes the production word-timing mapper
    // (`WordTimingRangeMapper`, #2809) return exactly one untimed entry for the whole
    // transcript — there is no whitespace to tokenize on, so no engine word can bind to any
    // text run. Every entry then resolves to "unknown" here, and persisting `.labeled(count:)`
    // alongside turns that are ALL "unknown" would store a self-contradictory row: the
    // analysis claims real speakers while the turns say none were ever found (found by cloud
    // review). Treated the same as `noWordTimings` — from turn assembly's own perspective,
    // timings that never bind to anything are exactly "nothing to merge against," matching
    // that reason's own documented scope. The real fix (a mapper that can tokenize a
    // space-free script) belongs to `WordTimingRangeMapper` itself, out of this phase's scope.
    guard assembledTurns.contains(where: { $0.speakerId != TurnAssembler.unknownSpeakerID })
    else {
      await mergeAndReport(
        historyID: historyIDForWrite, analysis: .failed(.noWordTimings), turns: nil,
        outcome: .noWordTimings, turnCount: nil, fallbackTurnCount: 0, passStart: passStart)
      return nil
    }
    return (assembledTurns, labeledCount)
  }

  /// Why the Done screen should show a speaker-analysis notice right now, if at all (#2811 §4
  /// invariant, refined by chunk review): `.failed` (a real analyzer failure) and
  /// `.unresolved` (admission-refused/polisher-unavailable, which write NOTHING at all,
  /// leaving the row exactly as it was) are DISTINCT stored outcomes and must read as
  /// distinct notices — collapsing them into one generic message is exactly the "success
  /// transitions straight to a silently-unresolved state" gap the §3 Design "failure
  /// authority" correction exists to close. Reads the STORED field via `currentHistoryRow`,
  /// never the in-memory analyzer-only `speakerAnalysis`. `.none` while a pass is
  /// `.inProgress`, and for `.single`/`.labeled`, which have nothing to retry.
  enum SpeakerNoticeReason: Equatable, Sendable { case none, failed, unresolved }

  var speakerNoticeReason: SpeakerNoticeReason {
    // No retained-audio guard here (cloud review of PR #2846): a notice can be owed for an
    // outcome no retry could change, whose audio has already been released. `choose`/
    // `startOver` reset both the step and the document identity, so no notice survives them.
    guard speakerStepState == .finished, let historyID,
      let current = currentHistoryRow(historyID)
    else { return .none }
    switch current.speakerAnalysis {
    case .failed: return .failed
    // `.unanalyzed`/`nil` both mean "no outcome ever landed" — `nil` is a pre-#2810 legacy
    // row's decode default (Transcript.swift's own documented reading), `.unanalyzed` is the
    // enum's own explicit spelling of the same fact; neither is ever chosen over the other by
    // this codebase's own writers, so both read as the same `.unresolved` notice.
    case .unanalyzed, nil: return .unresolved
    case .single, .labeled: return .none
    }
  }

  /// Whether "Try again" should be offered right now: a notice is showing, the audio to run
  /// against is still held, and the stored outcome is one a retry could change. Both notice
  /// reasons are eligible in principle (§4's invariant); the one exception is a
  /// `.noWordTimings` failure whose timing data can never bind a speaker, where a retry
  /// would only reach the same failure again (cloud review of PR #2846).
  var canRetrySpeakerAnalysis: Bool {
    guard speakerNoticeReason != .none, !retainedAnalysisSamples.isEmpty, let historyID,
      let current = currentHistoryRow(historyID)
    else { return false }
    return retryCouldChange(current.speakerAnalysis)
  }

  /// Re-runs speaker analysis and turn assembly from retained state, then PERSISTS that
  /// result and places the cleanup already on disk onto it (#2811 §3 Design "retry must not
  /// silently re-run cleanup, but it MUST still persist its result"; #2851: no cleanup of
  /// its own, the alignment reads the document's). Shares the analysis/assembly PREFIX with
  /// the ordinary pass via `assembleTurnsOrPersistTerminal` and the same persistence step.
  ///
  /// Synchronous and task-owning, matching `rePolish()`'s own shape (found by chunk review:
  /// an `async` entry point that never assigned `speakerStepTask` ran in the CALLER's task,
  /// so `stop()`/`choose()`/`startOver()`'s existing `speakerStepTask?.cancel()` targeted the
  /// PREVIOUS pass and never touched a running retry at all).
  func retrySpeakerAnalysis() {
    guard canRetrySpeakerAnalysis, let historyIDAtStart = historyID else { return }
    let analysisSamples = retainedAnalysisSamples
    let wordTimings = retainedWordTimings
    let wordTimingCoverage = retainedWordTimingCoverage
    speakerStepState = .inProgress
    speakerStepTask = Task { [weak self] in
      await self?.runRetryAnalysis(
        analysisSamples: analysisSamples, wordTimings: wordTimings,
        wordTimingCoverage: wordTimingCoverage, historyIDAtStart: historyIDAtStart)
      // Read AFTER the retry's own write, from the STORED outcome (§3 Design "failure
      // authority" correction) — never the in-memory analyzer-only `speakerAnalysis`, and
      // never assumed from whether `runRetryAnalysis` itself returned normally, since a
      // stale/cancelled retry also returns normally having written nothing. Both staleness
      // signals are required (found by chunk review): Stop cancels this task but leaves
      // `historyID` in place, so the identity check alone would read the untouched failed
      // row as "still failed" and blame the analyzer for a retry the user abandoned.
      guard let self, !Task.isCancelled, historyIDAtStart == self.historyID,
        let current = self.currentHistoryRow(historyIDAtStart)
      else { return }
      switch current.speakerAnalysis {
      // The same two outcomes that clear `speakerNoticeReason`: a one-voice result is a
      // successful analysis too, not a failure the user needs to retry.
      case .single, .labeled: self.emitSpeakerRetryTelemetry(.recovered)
      case .failed, .unanalyzed, nil: self.emitSpeakerRetryTelemetry(.stillFailed)
      }
    }
  }

  private func runRetryAnalysis(
    analysisSamples: [Float], wordTimings: [ASRWordTiming]?,
    wordTimingCoverage: ASRWordTimingCoverage?, historyIDAtStart: UUID
  ) async {
    // Every comparison below reads the LIVE `historyID` property — never a locally-bound
    // value of the same name, which would shadow it and neuter the staleness check (the
    // exact defect found by chunk review in an earlier version of this function).
    defer {
      if historyIDAtStart == historyID {
        speakerStepState = .finished
        releaseRetryInputsIfNoLongerRetryable()
      }
    }
    let durationSeconds = file?.seconds ?? 0
    let analysisStart = CFAbsoluteTimeGetCurrent()
    let outcome = await speakerLabeler(analysisSamples, durationSeconds)
    let analysisMs = Int(((CFAbsoluteTimeGetCurrent() - analysisStart) * 1000).rounded())
    guard historyIDAtStart == historyID, !Task.isCancelled else { return }
    speakerAnalysis = outcome
    await AppLogger.shared.log(
      "[SpeakerLabeler] outcome=\(Self.speakerLogOutcome(outcome)) speakers=\(Self.speakerLogCount(outcome)) ms=\(analysisMs) retry=true",
      level: .info, category: "FileImportCoordinator")
    guard historyIDAtStart == historyID, !Task.isCancelled else { return }
    emitSpeakerTelemetry(outcome, durationSeconds, analysisMs, wordTimingCoverage)
    // A fresh timer for the turn-storage phase, matching `runTurnStorage`'s own two-timer
    // shape (`analysisStart` for the analyzer alone, `passStart` for everything after) — so
    // this pass's `ms=` reads the same way as the ordinary pass's, minus the cleanup it skips.
    let passStart = CFAbsoluteTimeGetCurrent()
    guard let historyIDForWrite = historyID, historyIDForWrite == historyIDAtStart else { return }

    guard
      let (assembledTurns, labeledCount) = await assembleTurnsOrPersistTerminal(
        outcome: outcome, wordTimings: wordTimings, historyIDForWrite: historyIDForWrite,
        historyIDAtStart: historyIDAtStart, passStart: passStart)
    else { return }
    guard historyIDAtStart == historyID, !Task.isCancelled else { return }
    // The assembled turns persist raw, exactly as they came out of analysis, and the one
    // document cleanup already on disk is placed onto them by alignment (#2851): a retry
    // never runs a cleanup of its own.
    await mergeAndReport(
      historyID: historyIDForWrite, analysis: .labeled(count: labeledCount),
      turns: assembledTurns, outcome: nil, turnCount: assembledTurns.count,
      fallbackTurnCount: 0, passStart: passStart)
    guard historyIDAtStart == historyID, !Task.isCancelled else { return }
    await refreshTurnTexts()
  }

  /// Renames a speaker id across every turn showing it (#2811, phase 4 of #2807). Re-fetches
  /// the row's CURRENT analysis and turns TOGETHER, atomically, immediately before writing —
  /// never a value captured when a popover opened, which the plan's own grounded review
  /// found unsafe against a rename or a background turn-storage pass racing this one (§3
  /// Design correction 2). Callable from either screen; both are ordinary, symmetric callers
  /// of the same underlying write.
  func renameSpeaker(id: String, name: String) async -> RenameFailure? {
    guard let historyIDForWrite = historyID, let current = currentHistoryRow(historyIDForWrite),
      current.turns != nil, let analysis = current.speakerAnalysis
    else {
      emitRenameTelemetry(.failed)
      return RenameFailure(message: "Couldn't save the name.", currentName: nil)
    }
    do {
      let saved = try writeExplicitRename(
        historyIDForWrite, analysis, current.turns, (id, name))
      guard saved else {
        emitRenameTelemetry(.failed)
        return RenameFailure(
          message: "This recording was removed from History.", currentName: nil)
      }
      // Neither `turns` nor `speakerNames` below is itself an `@Observable`-tracked stored
      // property — they read through `currentHistoryRow`, a closure Observation cannot see
      // into — so nothing would tell a view to re-render after a successful rename without
      // this. Bumping it is what makes "every turn showing that speaker id re-renders" true.
      speakerFieldsRevision += 1
      emitRenameTelemetry(.saved)
      return nil
    } catch {
      emitRenameTelemetry(.failed)
      return RenameFailure(
        message: "Couldn't save the name.", currentName: current.speakerNames?[id])
    }
  }

  /// The rename popover closed on Escape or a blank name (plan §3d). Telemetry only; nothing
  /// to write and nothing to revert, since neither path ever reached `renameSpeaker`.
  func noteRenameCancelled() {
    emitRenameTelemetry(.cancelled)
  }

  /// The Done step's turn view just appeared for the current document (#2811 §3e). Reported
  /// once per document per launch; a re-appearance for the same row is not a new fact.
  func noteTurnsDisplayed() {
    guard let historyID, displayedTurnHistoryIDs.insert(historyID).inserted else { return }
    emitTurnsDisplayedTelemetry()
  }

  private static func elapsedMs(since start: CFAbsoluteTime) -> Int {
    Int(((CFAbsoluteTimeGetCurrent() - start) * 1000).rounded())
  }

  /// The one place `runTurnStorage` writes and reports telemetry, so every branch — success,
  /// a deleted row, or a save failure — is classified consistently (#2810 addendum §3a: the
  /// metric must never claim persistence that did not happen).
  /// `outcome: nil` means "write silently ON SUCCESS" — used only for `.failed`/`.timedOut`/
  /// `.cancelled` analyzer outcomes, which `emitSpeakerTelemetry` already reported; a
  /// successful write here has nothing new to say. A FAILED write is always new information
  /// (the analyzer's own event says nothing about whether persisting that failure reason
  /// succeeded), so `saveFailed`/`rowDeleted` are reported even when `outcome` is nil —
  /// found by chunk review round 2.
  private func mergeAndReport(
    historyID: UUID, analysis: TranscriptSpeakerAnalysis, turns: [Turn]?,
    outcome: TelemetryService.FileImportTurnsOutcome?, turnCount: Int?, fallbackTurnCount: Int,
    passStart: CFAbsoluteTime
  ) async {
    let saveFailed: Bool
    let rowDeleted: Bool
    do {
      let saved = try mergeSpeakerFields(historyID, analysis, turns)
      saveFailed = false
      rowDeleted = !saved
      // Keeps this coordinator's OWN in-memory snapshot in step with what was just
      // persisted. `withImportResult` (used by a later "Clean it again" / `rePolish`'s
      // `savePolishedToHistory`) never touches the speaker fields, so it PRESERVES
      // whatever `originalHistoryRow` already carries — but only if this write updates
      // that carried value first. Without this, a re-polish after turn storage silently
      // overwrote the just-saved speaker analysis, names and turns back to nil, because
      // `originalHistoryRow` never learned about this write (found by whole-diff review).
      // Guarded by id: `originalHistoryRow` can be nil, or belong to a DIFFERENT file
      // chosen while this background pass was still running.
      //
      // KNOWN LIMIT for phase 4 (second-pass review): this closes the loop for writes THIS
      // coordinator makes, but `originalHistoryRow` is still a private snapshot — an
      // explicit rename (`mergeSpeakerFields`'s `explicitRename:` parameter) applied from
      // anywhere else against the SAME row would not update it, and a later re-polish here
      // would silently revert that rename via `withImportResult`. Not reachable today: no
      // UI calls `explicitRename` yet (phase 4 ships that). Phase 4's rename design should
      // either read the row fresh from History at write time or push its own update through
      // this same path rather than assuming this cache is authoritative.
      if saved, originalHistoryRow?.id == historyID {
        originalHistoryRow = originalHistoryRow?.mergingSpeakerFields(
          analysis: analysis, turns: turns)
      }
    } catch {
      saveFailed = true
      rowDeleted = false
    }
    let reportedOutcome: TelemetryService.FileImportTurnsOutcome? =
      saveFailed ? .saveFailed : (rowDeleted ? .rowDeleted : outcome)
    guard let reportedOutcome else { return }
    let emitted = turnsTelemetryEmittedFor != historyID
    await AppLogger.shared.log(
      "[TurnStorage] outcome=\(reportedOutcome.rawValue) turns=\(turnCount ?? 0) fallback=\(fallbackTurnCount) emitted=\(emitted) ms=\(Self.elapsedMs(since: passStart))",
      level: .info, category: "FileImportCoordinator")
    guard emitted else { return }
    turnsTelemetryEmittedFor = historyID
    emitTurnTelemetry(
      reportedOutcome, reportedOutcome == .stored ? turnCount : nil, fallbackTurnCount)
  }

  private static func speakerLogOutcome(_ analysis: SpeakerAnalysis) -> String {
    switch analysis {
    case .single: return "single"
    case .labeled: return "labeled"
    case .failed(let failure):
      switch failure {
      case .modelsUnavailable: return "failed_models_unavailable"
      case .analyzerThrew: return "failed_analyzer_threw"
      case .noSpeakerSegments: return "failed_no_speaker_segments"
      case .cancelled: return "cancelled"
      }
    case .timedOut: return "timed_out"
    }
  }

  private static func speakerLogCount(_ analysis: SpeakerAnalysis) -> String {
    switch analysis {
    case .single: return "1"
    case .labeled(let count, _): return "\(count)"
    case .failed, .timedOut: return "n/a"
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
    heldOllamaModel = nil
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
    // #2772 finding 14: the queue the Working step renders. Published here, at the one place
    // the split exists, so the rows on screen are the pieces that will actually be cleaned.
    pendingPieces = pieces
    // #2772 finding 11: DURABLE BEFORE THE SLOW HALF, at the one entry both callers pass
    // through. Guarding inside `run` covered only the first transcription; a re-polish
    // reaches the cleanup directly, so a document whose original write was refused could
    // lose everything to a second interrupted cleanup. Found by Codex.
    // A re-polish after the user DELETED the row writes it again under the same id, which is
    // deliberate and not the case the update-only rule exists for. Pressing Clean it again is
    // asking for the work on this document; the rule protects a deletion made while work was
    // already running, where the user is not looking at the page and gets no say.
    guard rawIsSavedToHistory || saveRawToHistory() else {
      finishRun(savingDocument: false)
      return
    }
    guard !pieces.isEmpty else {
      cleanupComplete = true
      finishRun(savingDocument: true)
      return
    }
    // AFTER the durability gate: the words are transcribed and in History before the
    // cleanup is refused, so the refusal costs the cleanup and nothing else.
    guard localPolisherIsReady else {
      showRejection(.polisherNotReady)
      return
    }
    phase = "Cleaning it up"
    state = .polishing(done: 0, total: pieces.count)

    for (index, piece) in pieces.enumerated() {
      if Task.isCancelled || generationAtStart != generation { return }
      do {
        let outcome = try await processPart(piece, engineReportedLanguage)
        // Re-read AFTER the await: a Stop during this part must not write into
        // a run the user has already ended.
        guard generationAtStart == generation else { return }
        parts.append(
          Part(
            id: index, text: outcome.displayText, isUnpolished: outcome.isUnpolished,
            wasPolished: outcome.polishedText != nil))
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
      // #2851: place this part's cleaned words onto the turns, if the turns exist yet.
      // Milliseconds, off-main, single-flight; a stale result is discarded by its input.
      await refreshTurnTexts()
      guard generationAtStart == generation else { return }
    }
    guard generationAtStart == generation else { return }
    // Cleanup complete BEFORE the final alignment is requested, so its commit is the final
    // one (it emits `file_import_turns` once); Done follows that commit, not the model.
    cleanupComplete = true
    await refreshTurnTexts()
    guard generationAtStart == generation else { return }
    finishRun(savingDocument: true)
  }

  /// **The ONE place a run ends.** Three paths reached the terminal before #2772 — an empty
  /// split, the end of the loop, and now a refused History write — and each wrote `phase`,
  /// `state` and `step` itself. Three copies of a terminal is three chances for the next one
  /// to forget the History write, which is precisely the defect this chunk exists to fix.
  ///
  /// `savingDocument` is false on exactly one path: the raw write was REFUSED, so there is no
  /// row to update and retrying here would repeat the write the run just stopped on.
  ///
  /// This REDUCES the direct writers to `step` from eight to seven, so
  /// `FileImportCoordinatorTests.navigationHasOneWriter` is re-frozen deliberately rather
  /// than bumped, per the plan's requirement that the freeze change only on purpose.
  private func finishRun(savingDocument: Bool) {
    if savingDocument { savePolishedToHistory() }
    phase = ""
    state = .finished
    step = .done
  }

  // MARK: - History (#2772 finding 11)

  /// Writes the RAW words. Returns false when the write failed, and the caller must then NOT
  /// polish.
  ///
  /// **Raw first, and that ordering is the whole feature.** Saving only the finished document
  /// loses everything if the app dies during a forty-minute cleanup: the transcription has
  /// already run, the audio has already been released, and there is nothing left to redo it
  /// from. Saving the raw words costs one file write and makes the expensive half durable
  /// before the slow half starts.
  ///
  /// **A failure STOPS the run**, per the approved plan's failure table. Polishing into a
  /// document nobody can save is how a user loses words while watching a progress bar.
  private func saveRawToHistory() -> Bool {
    guard let file, let configuration = runConfiguration else { return false }
    // Built ONCE. Every later write is this row plus what changed, so `createdAt` and the
    // transcription engine describe the recording rather than the moment of the write.
    if originalHistoryRow == nil {
      originalHistoryRow = Transcript(
        text: rawTranscript,
        language: engineReportedLanguage,
        duration: file.seconds,
        backendType: configuration.backendType,
        importedFileName: file.name)
    }
    guard let row = originalHistoryRow else { return false }
    do {
      try saveToHistory(row)
      savedHistoryRow = row
      historySaveFailure = nil
      return true
    } catch {
      historySaveFailure = String(describing: error)
      return false
    }
  }

  /// Updates the SAME row with the cleaned document.
  ///
  /// Best effort, unlike the raw save: by this point the words are already durable, so a
  /// failure costs the cleanup and not the transcript. It records the failure rather than
  /// letting the Done screen claim a write that did not happen.
  private func savePolishedToHistory() {
    guard let originalHistoryRow, rawIsSavedToHistory else { return }
    // Same question the Done header's credit asks, and the same answer: `wasPolished`, not
    // the frozen configuration. A row that credits an engine for a clean that never ran is
    // the on-screen defect, persisted.
    var polished = originalHistoryRow.withImportResult(
      documentText,
      wasPolished: parts.contains(where: \.wasPolished),
      llmProvider: runConfiguration?.polishProvider.rawValue,
      llmModel: runConfiguration?.polishModel)
    // #2811, phase 4: `originalHistoryRow` is this coordinator's own cached snapshot, and
    // `withImportResult` never touches speaker fields — it carries whatever `originalHistoryRow`
    // already had forward VERBATIM. A rename (from either this wizard or History) or a
    // background turn-storage write landing on the live row AFTER this snapshot was taken
    // would otherwise be silently reverted by this write. Re-reading the live row and
    // carrying ITS speaker fields forward instead closes that gap regardless of which surface
    // wrote most recently (§3 Design "revised fix" — a single fix at the one place that
    // performs this write, not a per-writer patch).
    if let historyID, let liveRow = currentHistoryRow(historyID) {
      polished = polished.carryingSpeakerFields(from: liveRow)
    }
    do {
      guard try updateHistoryRow(polished) else {
        // The user deleted this import from History while it was being cleaned. Their
        // deletion stands; the words are still on screen, and Copy and Save still work.
        // Nothing to record: `historyRowWasDeleted` reads History itself.
        return
      }
      savedHistoryRow = polished
      historySaveFailure = nil
    } catch {
      historySaveFailure = String(describing: error)
    }
  }

  /// When this document was made, from the History row the run created. The Done header
  /// dates the RECORDING with it; reading `Date()` there described today, so a transcript
  /// left open overnight relabelled itself. Found by Codex (#2772).
  var documentCreatedAt: Date? { originalHistoryRow?.createdAt }

  /// Whether WHAT IS ON SCREEN reached History.
  ///
  /// Compares the saved row's text to the displayed document rather than asking whether a
  /// write succeeded. Stopping after one cleaned part left both writes reporting success for
  /// a document that no longer matched either of them, and the badge said "Saved to History"
  /// over words that were not. Found by Codex.
  var isSavedToHistory: Bool {
    // A write that succeeded and a row that exists are different facts, and this asks the
    // second. See `historyRowExists`.
    guard let savedHistoryRow, let historyID, historyRowExists(historyID) else { return false }
    // When the screen is showing the raw words the right question is whether THOSE are
    // saved. Comparing display text alone raised a false alarm on a real sequence: finish a
    // cleanup, press Clean it again, stop before the first part. `parts` is empty so the
    // screen falls back to the raw transcript, while the saved row's display text is the
    // PREVIOUS cleaned version — a mismatch over words that are safely stored. Found by
    // Codex. The Show original words toggle is the same question asked by the user.
    if screenShowsRawWords { return savedHistoryRow.text == rawTranscript }
    return savedHistoryRow.displayText == documentText
  }

  /// What to tell the user when the document on screen is not the one in History, or nil when
  /// there is nothing to say.
  ///
  /// **Two different situations, and telling them apart is the point.** With the original
  /// safely stored, only this cleanup is at risk and the words themselves are not. With
  /// nothing stored at all, the words exist only on this screen. A single sentence for both
  /// would alarm the first user and under-warn the second.
  var historySaveNotice: String? {
    guard hasDocument, !isSavedToHistory else { return nil }
    // First, because the two below both tell the user to put something in History and this
    // user just took it out. Repeating "your original words are saved" over a row they
    // deleted would be the page describing what was CONFIGURED rather than what happened.
    if historyRowWasDeleted {
      return
        "You deleted this from History, so it is not saved there. Copy or save it before you leave."
    }
    if rawIsSavedToHistory {
      return """
        Your original words are saved to History. This cleaned version is not. Copy or save \
        it before you leave.
        """
    }
    return """
      These words are not saved to History. Copy or save them before you leave, or press \
      Clean it again to retry.
      """
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
