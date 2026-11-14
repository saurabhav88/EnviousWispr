import EnviousWisprCore
import EnviousWisprEG1Engine
import EnviousWisprLLM
import EnviousWisprLocalPolish
import Foundation

/// Lends the bundled EG-1 server to one EnviousMeet summary attempt and gives it back (#4319).
///
/// EG-1 is not kept loaded for summaries (founder 2026-11-01): preparing an attempt loads
/// nothing. When the attempt's first model call is admitted on the local lane, the attempt
/// takes the runtime set's hold (the coordinator closes the server to every other request and
/// drains the admitted ones), then loads EG-1 with that hold's reservation, evicting S1-mini if
/// it is resident. Every call of the attempt reuses the hold. When the attempt ends, however it
/// ends, the hold is released and the settings reconciler puts dictation's engine back (EG-1
/// stays loaded only when it is dictation's engine too).
///
/// It decides nothing about the server's lifetime itself: the coordinator still owns starting
/// and stopping, and `PipelineSettingsSync` still owns what dictation wants running.
@MainActor
final class EGOneSummaryEngine {
  private let runtimes: LocalPolishRuntimeSet
  /// #4473: the EG-1 model a NEW attempt uses. Asked once per attempt, in `prepare`, before the
  /// context window is computed; the attempt keeps that answer through waits, load and calls.
  private let model: @MainActor () -> LocalPolishModelID
  /// The runtime facts of one EG-1 model; nil when this build has none for it.
  private let manifest: (LocalPolishModelID) -> EGOneManifest?
  /// The forced selection reconcile (`retryDeferredEGOneDeactivation(forceReconciliation:)`).
  private let restoreSelection: @MainActor () -> Void
  /// Set when the app starts quitting: no new load, and no restore that could start a server
  /// the quit is about to kill (the child is killed synchronously at quit regardless).
  private(set) var isTerminating = false
  /// The load, the endpoint read and the transport: the runtime's and the helper exchange in the app;
  /// tests answer without a real server.
  private let activate:
    @MainActor (LocalPolishModelID, LocalPolishSummaryReservation) async -> LocalPolishEndpoint?
  private let currentEndpoint: @MainActor (LocalPolishModelID) async -> LocalPolishEndpoint?
  private let send: LocalPolishHelperExchange.Perform

  init(
    runtimes: LocalPolishRuntimeSet, model: @escaping @MainActor () -> LocalPolishModelID,
    manifest: @escaping (LocalPolishModelID) -> EGOneManifest?,
    restoreSelection: @escaping @MainActor () -> Void,
    activate: (
      @MainActor (LocalPolishModelID, LocalPolishSummaryReservation) async -> LocalPolishEndpoint?
    )? = nil,
    currentEndpoint: (@MainActor (LocalPolishModelID) async -> LocalPolishEndpoint?)? = nil,
    send: @escaping LocalPolishHelperExchange.Perform = LocalPolishHelperExchange.perform
  ) {
    self.runtimes = runtimes
    self.model = model
    self.manifest = manifest
    self.restoreSelection = restoreSelection
    // The attempt's own model's runtime, by exact identity: no other size is ever used.
    self.activate =
      activate ?? { [runtimes] model, reservation in
        await runtimes.runtime(for: model)?.activateForSummary(reservation)
      }
    self.currentEndpoint =
      currentEndpoint ?? { [runtimes] model in await runtimes.runtime(for: model)?.activeEndpoint() }
    self.send = send
  }

  func beginTermination() { isTerminating = true }

  /// The weights' revision, for the summary's configuration identity: a new EG-1 makes an
  /// older summary out of date.
  /// #4473: of the model a new attempt would use. The full size reports the bare revision, as
  /// before sizes existed, so no existing summary goes out of date; another size names itself,
  /// so a summary written by one size is out of date for another.
  var artifactRevision: String? { artifactRevision(for: model()) }

  /// The configuration identity of one EG-1 model's weights.
  func artifactRevision(for model: LocalPolishModelID) -> String? {
    guard let version = manifest(model)?.version else { return nil }
    guard let size = model.size, size != .full else { return version }
    return "\(size.rawValue)|\(version)"
  }

  /// A cold attempt: checks EG-1 is installed and has a manifest, and loads nothing.
  func prepare(timeoutSeconds: Double, modelOverride: LocalPolishModelID? = nil) -> Result<
    MeetingSummaryProviders.Prepared, MeetingSummaryProviders.Unavailable
  > {
    // #4473: the model is captured HERE, once, before the context window below is computed.
    let model = modelOverride ?? model()
    guard !isTerminating, let manifest = manifest(model),
      let runtime = runtimes.runtime(for: model), case .installed = runtime.installState
    else { return .failure(.notReady) }
    let attempt = Attempt(engine: self, model: model, timeoutSeconds: timeoutSeconds)
    return .success(
      MeetingSummaryProviders.Prepared(
        execution: .local,
        window: MeetingSummary.Window(
          contextTokens: manifest.contextTokens, outputReserveTokens: MeetingSummary.outputTokens),
        complete: { instructions, prompt in
          try await attempt.complete(instructions: instructions, prompt: prompt)
        },
        finish: { await attempt.finish() },
        borrow: { try await attempt.borrow() },
        // The captured model's revision: the attempt's saved identity names what wrote it.
        artifactRevision: artifactRevision(for: model)))
  }

  /// One prepared attempt's state.
  @MainActor
  final class Attempt {
    private weak var engine: EGOneSummaryEngine?
    /// The model captured when the attempt was prepared. Never read again from Settings.
    private let model: LocalPolishModelID
    private let timeoutSeconds: Double
    private var hold: LocalPolishRuntimeSet.SummaryHold?
    /// Recorded before the load is awaited, so a load that fails or is cancelled still ends in
    /// a restore of dictation's engine.
    private var activationAttempted = false
    private var finished = false

    init(engine: EGOneSummaryEngine, model: LocalPolishModelID, timeoutSeconds: Double) {
      self.engine = engine
      self.model = model
      self.timeoutSeconds = timeoutSeconds
    }

    /// Called after each lane admission, before the call. The first one takes the server and
    /// loads EG-1; later ones find the hold in place. `.retryLater` (a file import holds a
    /// bundled server) holds nothing: the caller gives the lane back and waits for a turn.
    func borrow() async throws -> MeetingSummaryProviders.BorrowOutcome {
      guard let engine, !engine.isTerminating, !finished else { throw CancellationError() }
      if hold != nil { return .ready }
      switch await engine.runtimes.beginSummaryHold(model) {
      case .retryLater:
        return .retryLater
      case .cancelled:
        throw CancellationError()
      case .held(let taken):
        hold = taken
        guard let reservation = engine.runtimes.reservation(for: taken) else {
          throw LLMError.requestFailed("EG-1 summary hold lost")
        }
        activationAttempted = true
        guard !engine.isTerminating else { throw CancellationError() }
        guard await engine.activate(model, reservation) != nil else {
          throw LLMError.requestFailed("EG-1 did not start for the summary")
        }
        return .ready
      }
    }

    /// One call on the server this attempt holds; the endpoint is read again for every call.
    func complete(instructions: String, prompt: String) async throws -> String {
      guard let engine, let hold, engine.runtimes.reservation(for: hold) != nil else {
        throw LLMError.requestFailed("EG-1 summary call without the server")
      }
      guard let endpoint = await engine.currentEndpoint(model) else {
        throw LLMError.requestFailed("EG-1 is not running")
      }
      return try await EGOneSummaryCall.complete(
        endpoint: endpoint, instructions: instructions, prompt: prompt,
        timeoutSeconds: timeoutSeconds, send: engine.send)
    }

    /// Exactly once per attempt, after its last call has ended: the hold goes (projection
    /// first, then the server), then dictation's engine is put back, unless the attempt never
    /// tried to load EG-1 (nothing changed) or the app is quitting.
    func finish() async {
      guard !finished else { return }
      finished = true
      if let hold {
        self.hold = nil
        await engine?.runtimes.endSummaryHold(hold)
      }
      guard activationAttempted, let engine, !engine.isTerminating else { return }
      engine.restoreSelection()
    }
  }
}
