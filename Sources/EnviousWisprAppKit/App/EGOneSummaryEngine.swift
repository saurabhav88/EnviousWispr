import EnviousWisprCore
import EnviousWisprLLM
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
  private let manifest: () -> EGOneManifest?
  /// The forced selection reconcile (`retryDeferredEGOneDeactivation(forceReconciliation:)`).
  private let restoreSelection: @MainActor () -> Void
  /// Set when the app starts quitting: no new load, and no restore that could start a server
  /// the quit is about to kill (the child is killed synchronously at quit regardless).
  private(set) var isTerminating = false
  /// The load, the endpoint read and the transport: the runtime's and `URLSession` in the app;
  /// tests answer without a real server.
  private let activate: @MainActor (LocalPolishSummaryReservation) async -> EGOneEndpoint?
  private let currentEndpoint: @MainActor () async -> EGOneEndpoint?
  private let send: @Sendable (URLRequest) async throws -> (Data, URLResponse)

  init(
    runtimes: LocalPolishRuntimeSet, manifest: @escaping () -> EGOneManifest?,
    restoreSelection: @escaping @MainActor () -> Void,
    activate: (@MainActor (LocalPolishSummaryReservation) async -> EGOneEndpoint?)? = nil,
    currentEndpoint: (@MainActor () async -> EGOneEndpoint?)? = nil,
    send: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
      try await URLSession.shared.data(for: $0)
    }
  ) {
    self.runtimes = runtimes
    self.manifest = manifest
    self.restoreSelection = restoreSelection
    self.activate = activate ?? { [runtimes] in await runtimes.egOne.activateForSummary($0) }
    self.currentEndpoint = currentEndpoint ?? { [runtimes] in await runtimes.egOne.activeEndpoint() }
    self.send = send
  }

  func beginTermination() { isTerminating = true }

  /// The weights' revision, for the summary's configuration identity: a new EG-1 makes an
  /// older summary out of date.
  var artifactRevision: String? { manifest()?.version }

  /// A cold attempt: checks EG-1 is installed and has a manifest, and loads nothing.
  func prepare(timeoutSeconds: Double) -> Result<
    MeetingSummaryProviders.Prepared, MeetingSummaryProviders.Unavailable
  > {
    guard !isTerminating, let manifest = manifest(),
      case .installed = runtimes.egOne.installState
    else { return .failure(.notReady) }
    let attempt = Attempt(engine: self, timeoutSeconds: timeoutSeconds)
    return .success(
      MeetingSummaryProviders.Prepared(
        execution: .local,
        window: MeetingSummary.Window(
          contextTokens: manifest.contextTokens, outputReserveTokens: MeetingSummary.outputTokens),
        complete: { instructions, prompt in
          try await attempt.complete(instructions: instructions, prompt: prompt)
        },
        finish: { await attempt.finish() },
        borrow: { try await attempt.borrow() }))
  }

  /// One prepared attempt's state.
  @MainActor
  final class Attempt {
    private weak var engine: EGOneSummaryEngine?
    private let timeoutSeconds: Double
    private var hold: LocalPolishRuntimeSet.SummaryHold?
    /// Recorded before the load is awaited, so a load that fails or is cancelled still ends in
    /// a restore of dictation's engine.
    private var activationAttempted = false
    private var finished = false

    init(engine: EGOneSummaryEngine, timeoutSeconds: Double) {
      self.engine = engine
      self.timeoutSeconds = timeoutSeconds
    }

    /// Called after each lane admission, before the call. The first one takes the server and
    /// loads EG-1; later ones find the hold in place. `.retryLater` (a file import holds a
    /// bundled server) holds nothing: the caller gives the lane back and waits for a turn.
    func borrow() async throws -> MeetingSummaryProviders.BorrowOutcome {
      guard let engine, !engine.isTerminating, !finished else { throw CancellationError() }
      if hold != nil { return .ready }
      switch await engine.runtimes.beginSummaryHold(.egOne) {
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
        guard await engine.activate(reservation) != nil else {
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
      guard let endpoint = await engine.currentEndpoint() else {
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
