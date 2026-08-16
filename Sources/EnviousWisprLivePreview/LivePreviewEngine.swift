import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation

/// What the live preview needs from a recognizer, and nothing more (#2077).
///
/// The coordinator used to name `ApplePreviewRecognizer` in nine places, which was
/// workable while Apple was the only engine and stops being workable the moment a
/// second one exists. Apple's engine requires macOS 26 and can only transcribe the
/// languages that Mac happens to have installed; a downloadable universal model has
/// neither restriction. Those are different availability rules for the same feature,
/// so availability has to be something an engine ANSWERS rather than something the
/// coordinator assumes.
///
/// Deliberately six members, matching exactly what the coordinator already called.
/// This is a seam, not a design for a future engine: anything an engine needs that
/// the coordinator never asked for belongs on the engine, not here.
///
/// `Sendable` rather than `: Actor`. The one conformer today is an actor and actors
/// are already `Sendable`, so constraining to `Actor` would buy nothing and would
/// forbid a future engine that is a value wrapping someone else's actor.
package protocol LivePreviewEngine: Sendable {

  /// Claim whatever the engine needs and get ready to transcribe. Throwing is the
  /// engine's way of saying "not now"; the coordinator turns that into a sentence
  /// on the pill and retries on a later recording. Never called from the heart.
  ///
  /// May be slow on first use — Apple's engine can download a speech model here —
  /// so the coordinator holds this task outside any one recording.
  func prepare() async throws

  /// Open a session and start delivering text.
  ///
  /// `onText` is called with the whole text the user should now see, already
  /// bounded by the producer, and must be cheap: it is invoked from whatever task
  /// the engine collects on.
  ///
  /// `lookups` is this recording's Custom Words snapshot, passed IN rather than
  /// read from engine state. That is not a style choice — the stored-property
  /// version was racy, and a session opened straight after preparation could
  /// capture `nil` and visibly mangle a user's own names for a whole recording.
  func openSession(
    lookups: WordCorrector.Lookups?,
    onText: @escaping @Sendable (String) -> Void
  ) async throws -> any LivePreviewEngineSession
}

/// One live preview session.
///
/// Separate from the engine because an engine outlives the recordings that use it:
/// the coordinator keeps a prepared engine across presses so the second press does
/// not pay preparation again, while every recording gets its own session.
///
/// **A session owns its own resources and no engine field may be involved.** Three
/// review rounds on #1988 produced seven defects of one shape because the analyzer,
/// continuation and collector lived on the actor: an actor serializes calls but is
/// reentrant at every `await`, so any suspended operation could resume onto fields
/// a newer session had replaced. Whatever conforms here must carry its session's
/// resources with it, so a stale call can only reach resources that are already
/// finished.
package protocol LivePreviewEngineSession: Sendable {

  /// Hand over newly captured 16 kHz mono samples. Called roughly ten times a
  /// second while a recording runs.
  func feed(_ samples: [Float]) async

  /// Finish this session and release everything it holds. Called exactly once, by
  /// whoever opened it.
  ///
  /// Every session MUST reach this. Apple's analyzer retains analysis and model
  /// resources until explicitly ended, and four separate abandonment sites were
  /// found on #1988, three of them only by review.
  func end() async
}

/// An engine that could serve a recording, plus the key that says whether the one
/// already prepared will do.
///
/// The engine is behind a factory rather than built eagerly because resolution runs
/// at the start of every recording while construction should happen only when the
/// key actually changed. Apple's initializer merely stores a locale; an engine that
/// has to open a downloaded model on disk would not be so cheap, and the seam
/// should not depend on that staying true.
package struct LivePreviewEngineCandidate: Sendable {

  /// Identity of "the engine that would serve this recording", compared against the
  /// prepared one to decide whether preparation can be reused.
  package let key: LivePreviewEngineKey

  package let makeEngine: @Sendable () -> any LivePreviewEngine

  package init(
    key: LivePreviewEngineKey, makeEngine: @escaping @Sendable () -> any LivePreviewEngine
  ) {
    self.key = key
    self.makeEngine = makeEngine
  }
}

/// What makes one prepared engine reusable for the next recording.
///
/// Two fields rather than one formatted string, because the identity is genuinely
/// two things — WHICH ENGINE and WHAT IT COMMITTED TO — and a single string would
/// leave each engine to namespace itself by convention. Two engines previewing the
/// same language are not interchangeable, and a struct makes that structural
/// instead of dependent on everyone remembering a prefix.
package struct LivePreviewEngineKey: Equatable, Sendable {

  /// Stable identifier for the engine itself. Set by each engine's own resolver in
  /// one place, so it cannot drift.
  package let engine: String

  /// Whatever the engine committed to for this recording, in the engine's own
  /// terms: a resolved locale for one that must be told the language up front, the
  /// empty string for one that detects language itself and therefore prepares the
  /// same way regardless of the setting.
  package let commitment: String

  package init(engine: String, commitment: String) {
    self.engine = engine
    self.commitment = commitment
  }
}

/// Why an engine cannot serve this recording.
///
/// **A reason, never a sentence.** An earlier draft returned finished user-facing
/// copy from the engine, which put brand-governed strings inside a module that has
/// no business owning them and left two places deciding how a refusal reads. The
/// engine knows WHY; the app shell owns what the user is told. That split is also
/// what lets this module carry no user-facing text at all.
///
/// Cases are added when something can PRODUCE them. A downloadable engine will need
/// "the model is not installed" and "it is installing", and those arrive with the
/// code that can report and act on them — a case nothing produces is a branch no
/// test can reach.
package enum LivePreviewUnavailability: Sendable, Equatable {
  /// This Mac cannot run the engine at all, whatever the language.
  case unsupportedSystem
  /// The engine runs here but cannot transcribe the language that was asked for.
  case unsupportedLanguage
  /// The engine supports this language, but its model is not on this Mac yet.
  ///
  /// **A Bypass, not a Failure.** Nothing is broken and nothing should be retried: the user has
  /// to choose to download it. The associated value is the language's own name, so the message
  /// can say WHICH language rather than the generic sentence that sends people hunting.
  ///
  /// Added in #2080, not #2078, because until the settings page existed nothing could produce
  /// this case and nothing could act on it — a branch no test can reach is where bugs hide.
  case installRequired(languageName: String)

  /// The universal engine's model has not been downloaded to this Mac.
  ///
  /// **A sibling of `installRequired`, not a reuse of it.** That case names a
  /// LANGUAGE, because Apple ships one pack per language and the useful sentence
  /// is "French is not installed". This engine has ONE artifact covering every
  /// language it supports, so there is no language to name and a copy that tried
  /// would have to invent one. Same shape of refusal, different subject.
  ///
  /// A Bypass, not a Failure: nothing is broken and nothing should be retried.
  /// The engine never starts a download on its own — that is the user's decision,
  /// and the door for it arrives with the engine picker (#2077 chunk 5).
  ///
  /// Added in #2108 because this is the chunk where something can finally
  /// produce it, matching this enum's own rule that a case arrives with the code
  /// that can report and act on it.
  case modelNotInstalled

  /// The transcription engine is itself decoding continuously right now, so a
  /// second decoder would contend with the heart for the same silicon.
  ///
  /// **Measured, not precautionary (#2108 Gate C).** Two WhisperKit models
  /// resident together cost the heart nothing (ratio 1.00), but both DECODING
  /// together cost it 50% — 591 ms to 885 ms, far outside the 591-626 ms
  /// repeat-to-repeat envelope. The heart streams throughout a recording when
  /// live transcription is on with a locked language
  /// (`WhisperKitEngineAdapter.startRecording`), which is a continuous overlap
  /// rather than a brief one.
  ///
  /// So the preview REFUSES in that configuration rather than degrading or
  /// racing. It deliberately does not fall back to a lock the heart would await:
  /// a display-only limb must never be able to stall transcription.
  case heartIsStreaming
}

/// Whether a preview can run, and if not, why.
package enum LivePreviewEngineResolution: Sendable {
  case ready(LivePreviewEngineCandidate)
  case blocked(LivePreviewUnavailability)
}

/// One engine, as the app shell selects it: whether this Mac can run it at all, and
/// how to resolve a recording against it.
///
/// The two halves travel together because they must agree. The overlay asks the
/// synchronous half while sizing the pill, where there is nothing to await; the
/// coordinator asks the async half when a recording starts. Splitting them across
/// two injection points is how they would drift, and a pill sized for a preview that
/// then refuses is exactly the "switched on but nothing happens" impression this
/// feature exists to remove.
package struct LivePreviewEngineRoute: Sendable {

  /// Static capability only: does this Mac have what the engine fundamentally
  /// requires. NOT "is it ready right now" — anything that can change while the app
  /// runs, such as whether a model has been downloaded, belongs in `resolve`.
  package let isSupportedOnThisSystem: @Sendable () -> Bool

  package let resolve: LivePreviewEngineResolver

  package init(
    isSupportedOnThisSystem: @escaping @Sendable () -> Bool,
    resolve: @escaping LivePreviewEngineResolver
  ) {
    self.isSupportedOnThisSystem = isSupportedOnThisSystem
    self.resolve = resolve
  }
}

/// Answers "can this be previewed, and by what" for one engine.
///
/// **Takes the user's language SETTING, not a language.** That distinction is the
/// reason this seam exists at all. Apple's engine cannot detect language, so it has
/// to turn Auto into a guess at the system locale and live with being wrong; a
/// model that detects language for itself must not inherit that guess, because
/// guessing would be strictly worse than what it can already do. Handing engines a
/// pre-resolved language would bake one engine's limitation into the feature and
/// silently degrade every engine that does not share it.
///
/// So the split is: WHETHER to preview and what the user asked for are the
/// feature's business; what to do with `.auto`, and which languages are possible at
/// all, belong to the engine.
package typealias LivePreviewEngineResolver =
  @Sendable (LanguageMode) async -> LivePreviewEngineResolution
