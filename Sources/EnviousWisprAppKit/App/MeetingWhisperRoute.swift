import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprPipeline
import Foundation

/// The engine dependencies one EnviousMeet final pass decodes through (#3973 C3): the
/// Parakeet route or the Whisper route, chosen by the pass's resolved engine.
@MainActor
protocol MeetingFinalEngineRoute: AnyObject {
  func acquire() async throws
  func loadEngine() async throws
  func transcribe(_ samples: [Float], language: String?) async throws -> ASRResult
  func unloadEngine() async
  func endModelUse() async
  func waitForEngineAvailability() async throws
  var engineIdentity: String? { get }
  func beginPass(meetingID: UUID?, meetingSeconds: Int)
  /// The pass holds its own copy of its engine (dictation runs the other one).
  var isOwnModelResident: Bool { get }
  var onWaitingForDictation: (@MainActor (Bool) -> Void)? { get set }
}

extension MeetingParakeetRoute: MeetingFinalEngineRoute {
  var isOwnModelResident: Bool { isOwnParakeetResident }
}

/// Which Whisper one EnviousMeet final-pass engine operation decodes on (#3973 C3), and the
/// acquisition and release that choice needs. Built per pass by `MeetingWiring.makeJob` when
/// the pass resolved to Whisper.
///
/// **Same engine, one copy (decision 11).** When dictation's active engine is Whisper, the
/// operation decodes on dictation's loaded Whisper Large v3 Turbo at PREVIEW priority: a
/// dictation meanwhile preempts it at once (the executor aborts the meeting run), and the
/// meeting runs the operation again afterwards (`MeetingEngineYield`). No lease is held, so a
/// dictation press never waits for a meeting decode. When dictation runs Parakeet, the
/// operation loads the meeting's own Turbo copy (preview priority too) and unloads it at the
/// end of the operation, so a switch of dictation into Whisper (gate 6d) waits for one
/// operation, never the whole pass.
///
/// Like the Parakeet route, every wait runs with nothing held, and a new operation starts only
/// when no dictation runs or waits for its turn (#3973 C1).
@MainActor
final class MeetingWhisperRoute: MeetingFinalEngineRoute {
  enum Route: Equatable {
    case shared
    case own
  }

  struct Dependencies {
    /// The final-pass admission (`MeetingWiring.admission`).
    var isAdmitted: @MainActor () -> Bool
    var isDictationIdle: @MainActor () -> Bool
    var isSwitchSettled: @MainActor () -> Bool
    var activeBackend: @MainActor () -> ASRBackendType
    var wakes: MeetingWakeSignal
    /// The shared engine lease, read only: a meeting operation starts when no one holds it and
    /// no dictation waits for its turn.
    var admission: EngineAdmissionAccess
    /// Dictation's readiness drive: loads dictation's Whisper when it is the active engine.
    var ensureDictationReady: @MainActor () async -> MeetingParakeetRoute.Readiness
    /// The admitted Turbo model file, or nil when it is not downloaded or not admitted now
    /// (read live, never cached). The pass never downloads.
    var modelPath: @MainActor () async -> String?
    /// Model name and revision of the admitted Turbo, for checkpoint identity.
    var modelIdentity: @MainActor () -> String?
    var transcribeShared:
      @MainActor (_ samples: [Float], _ language: String?) async throws -> ASRResult
    var disarmEngineTimers: @MainActor () -> Void
    var rearmEngineTimers: @MainActor () -> Void
    var ownLoad: @MainActor (_ modelPath: String) async throws -> Void
    var ownTranscribe:
      @MainActor (_ samples: [Float], _ language: String?) async throws -> ASRResult
    var ownUnload: @MainActor () async -> Void
    /// Told when the own copy is gone, so a switch it held can proceed.
    var ownResidencyEnded: @MainActor () -> Void
    var log: @MainActor (String) -> Void
  }

  private let deps: Dependencies
  private(set) var route: Route?
  /// From the moment this pass chooses its own Turbo until that copy is unloaded.
  private var ownActive = false
  private var sharedTimersDisarmed = false
  private var meetingID = "-"
  private var reportingDictationWait = false

  var onWaitingForDictation: (@MainActor (Bool) -> Void)?

  init(dependencies: Dependencies) {
    deps = dependencies
  }

  func beginPass(meetingID: UUID?, meetingSeconds: Int) {
    self.meetingID = meetingID?.uuidString ?? "-"
  }

  var isOwnModelResident: Bool { ownActive }

  var engineIdentity: String? { route == nil ? nil : deps.modelIdentity() }

  // MARK: - Job dependencies

  /// The job's `beginModelUse`. Throws only `CancellationError` or `JobError.engineUnavailable`.
  func acquire() async throws {
    while true {
      let ready: @MainActor () -> Bool = {
        [isAdmitted = deps.isAdmitted, holder = deps.admission.currentHolder,
        reserved = deps.admission.hasPendingReservation, settled = deps.isSwitchSettled] in
        isAdmitted() && holder() == nil && !reserved() && settled()
      }
      try await wait(until: ready)
      guard await deps.modelPath() != nil else {
        throw MeetingTranscriptionJob.JobError.engineUnavailable("model_not_installed")
      }
      if deps.activeBackend() == .whisper {
        switch try await readinessUnlessCancelled() {
        case .ready: break
        case .notInstalled:
          throw MeetingTranscriptionJob.JobError.engineUnavailable("model_not_installed")
        case .notReady:
          throw MeetingTranscriptionJob.JobError.engineUnavailable("model_not_ready")
        }
        try Task.checkCancellation()
        // Re-checked in the same main-actor step that takes the route.
        guard ready(), deps.activeBackend() == .whisper else { continue }
        route = .shared
        deps.disarmEngineTimers()
        sharedTimersDisarmed = true
        deps.log("meeting engine route=whisper_shared claimed meeting=\(meetingID)")
        return
      }
      ownActive = true
      guard ready(), deps.activeBackend() != .whisper else {
        ownActive = false
        deps.ownResidencyEnded()
        continue
      }
      route = .own
      deps.log("meeting engine route=whisper_own meeting=\(meetingID)")
      return
    }
  }

  func loadEngine() async throws {
    switch route {
    case .shared: break
    case .own:
      guard let path = await deps.modelPath() else {
        throw MeetingTranscriptionJob.JobError.engineUnavailable("model_not_installed")
      }
      try await deps.ownLoad(path)
    case nil:
      throw MeetingWiringError.noModelClaim
    }
  }

  func transcribe(_ samples: [Float], language: String?) async throws -> ASRResult {
    switch route {
    case .shared: try await deps.transcribeShared(samples, language)
    case .own: try await deps.ownTranscribe(samples, language)
    case nil: throw MeetingWiringError.noModelClaim
    }
  }

  func unloadEngine() async {
    switch route {
    case .shared: releaseShared()
    case .own: await deps.ownUnload()
    case nil: break
    }
  }

  /// Idempotent; also reached without `unloadEngine` when a load fails.
  func endModelUse() async {
    switch route {
    case .shared:
      releaseShared()
      deps.log("meeting engine route=whisper_shared released meeting=\(meetingID)")
    case .own:
      await deps.ownUnload()
      ownActive = false
      deps.ownResidencyEnded()
      deps.log("meeting engine route=whisper_own released meeting=\(meetingID)")
    case nil: break
    }
    route = nil
  }

  /// After a load or decode gave way to dictation: waits, holding nothing, until dictation is
  /// idle.
  func waitForEngineAvailability() async throws {
    let isDictationIdle = deps.isDictationIdle
    try await wait(until: { isDictationIdle() })
  }

  // MARK: - Internals

  private func releaseShared() {
    guard sharedTimersDisarmed else { return }
    sharedTimersDisarmed = false
    // A dictation waiting for its turn keeps the timers off; it re-arms them itself.
    if !deps.admission.hasPendingReservation() { deps.rearmEngineTimers() }
  }

  /// Dictation's readiness drive, but a cancelled pass stops waiting at once (the drive can be
  /// dictation's own model load, which finishes by itself; its answer is then dropped).
  private func readinessUnlessCancelled() async throws -> MeetingParakeetRoute.Readiness {
    try Task.checkCancellation()
    let ensure = deps.ensureDictationReady
    let slot = OnceSlot<MeetingParakeetRoute.Readiness?>()
    let answer = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        slot.arm(continuation)
        Task { @MainActor in slot.resolve(await ensure()) }
      }
    } onCancel: {
      slot.resolve(nil)
    }
    guard let answer else { throw CancellationError() }
    return answer
  }

  /// Waits, with nothing held, until `condition` holds, reporting "Paused while you dictate"
  /// while the wait is for a dictation.
  private func wait(until condition: @escaping @MainActor () -> Bool) async throws {
    defer { reportDictationWait(false) }
    while !condition() {
      let dictating = !deps.isDictationIdle()
      reportDictationWait(dictating)
      let isDictationIdle = deps.isDictationIdle
      await MeetingWorkAdmission.waitUntil(
        { condition() || isDictationIdle() == dictating }, wakes: deps.wakes)
      try Task.checkCancellation()
    }
    try Task.checkCancellation()
  }

  private func reportDictationWait(_ waiting: Bool) {
    guard waiting != reportingDictationWait else { return }
    reportingDictationWait = waiting
    onWaitingForDictation?(waiting)
  }
}
