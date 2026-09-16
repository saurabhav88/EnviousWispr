import CoreAudio
import EnviousWisprAudio
import EnviousWisprCore
import Foundation

// #1413 — what happens to OTHER audio between recording start and recording end.
//
// Shape mirrors `RecordingSoundCue`: state-gated on entry to `.recording`, released
// on the FIRST published transition away, per backend, so every ending the
// coordinator sees (normal stop, cancel, stall, dead mic, advisory) lands here
// identically. The two endings the coordinator never sees — process death and a
// Cocoa quit — are covered by the on-disk record (`OtherAudioHoldStore`) plus
// `adoptOrphans()` at launch and `finishForTermination()` at quit.
//
// Disposition and retirement rules are the plan's §4 tables (P1-P12, M1-M4,
// R1-R6); the enum cases here ARE that vocabulary. No sentence in this file
// invents a disposition outside it.

/// What the coordinator hands over per transition. Kept minimal so the
/// coordinator's own file gains no import and no collaborator.
enum OtherAudioBackend: Hashable, Sendable {
  case parakeet
  case whisperKit
}

/// The take-level facts the telemetry sink receives once, when the hold's
/// restore has run. Every field is shape, never content; a timing whose
/// operation did not execute is nil and stays absent on the wire.
struct OtherAudioTakeSummary: Equatable, Sendable {
  var mode: String
  var volume: OtherAudioPropertyDisposition
  var mute: OtherAudioPropertyDisposition
  var media: OtherAudioMediaDisposition
  var outputTransport: String?
  var applyMicros: Int?
  var restoreMicros: Int?
  var recordMicros: Int?
  /// Closed operation/reason for a failure that is a CONDITION, not our defect
  /// (`record_failed`, `unsupported_output`, `consent_needed`, ...). nil when none.
  var failure: String?
  /// v1.1: which media route answered (`adapter` / `scripted` / `none`) and the
  /// adapter's bounded failure class when it was tried and failed. nil until
  /// the pause outcome arrives (a late outcome carries them on the settlement).
  var mediaRoute: String? = nil
  var adapterFailure: String? = nil
  /// Local correlation only, so a late media settlement reaches ITS take's row.
  /// Never included in vendor properties.
  var holdID: UUID = UUID()
}

/// Where the hold reports. The live sink folds the summary onto the take's
/// existing `dictation.terminal` row and writes breadcrumbs; `captureDefect` is
/// reserved for established app defects (plan §3.7).
@MainActor
protocol OtherAudioTelemetrySink: AnyObject {
  func recordTakeSummary(_ summary: OtherAudioTakeSummary)
  /// Called once the media half of the same hold settles, possibly after the
  /// summary; the sink updates only the row that hold's summary landed on.
  func recordMediaSettled(
    _ media: OtherAudioMediaDisposition, holdID: UUID, failure: String?, route: String?,
    adapterFailure: String?)
  func breadcrumb(_ message: String, data: [String: String])
  func captureDefect(_ message: String, data: [String: String])
}

@MainActor
final class OtherAudioHold {
  /// Injected so tests run against fakes and a controllable clock; production
  /// values come from `WisprBootstrapper`.
  struct Dependencies {
    var effects: OtherAudioEffects
    /// The current default OUTPUT device id; production reads
    /// `AudioDeviceEnumerator.defaultOutputDeviceID`, the existing authority.
    var defaultOutputDeviceID: () -> AudioDeviceID?
    var store: OtherAudioHoldStore
    var telemetry: any OtherAudioTelemetrySink
    var log: @MainActor (String) -> Void
    /// Monotonic microseconds.
    var nowMicros: () -> Int
    var sleep: @Sendable (TimeInterval) async throws -> Void
    var pid: Int32
    var isProcessAlive: (Int32) -> Bool
  }

  /// Half the slider, not a fifth: the macOS output slider is far from linear to
  /// the ear, and x0.2 read as muted on the built-in speakers (founder, live
  /// test 2026-09-15). Half still clearly "turns down" while staying audible.
  static let turnDownFactor: Float = 0.5
  static let volumeTolerance: Float = 0.01

  private let deps: Dependencies

  private struct Live {
    var record: OtherAudioHoldRecord
    var backend: OtherAudioBackend
    var transport: String
    var applyTask: Task<Void, Never>?
    var applied = false
    var applyMicros: Int?
    var recordMicros: Int?
    /// A media condition that settled during the take (`consent_needed`, ...).
    var failure: String?
    var mediaRoute: String?
    var adapterFailure: String?
  }

  private var live: Live?

  init(dependencies: Dependencies) {
    self.deps = dependencies
  }

  /// Read-only test seam: the delayed apply task, so a test can await its
  /// completion instead of guessing with yields.
  var pendingApplyForTesting: Task<Void, Never>? { live?.applyTask }

  // MARK: - Coordinator entry point

  /// Call on every `PipelineState` transition for one backend, BEFORE the sound
  /// cue's own `handle`: on `.recording` this only schedules the delayed apply, so
  /// the start cue is invoked first; on every other state the restore runs
  /// synchronously, so the stop cue renders at the restored level.
  func handle(
    _ state: PipelineState, backend: OtherAudioBackend,
    mode: OtherAudioWhileDictating, startDelay: TimeInterval
  ) {
    switch state {
    case .recording:
      guard live == nil, mode != .nothing else { return }
      begin(mode: mode, backend: backend, startDelay: startDelay)
    case .idle, .loadingModel, .transcribing, .polishing, .complete, .error, .advisory:
      guard let current = live, current.backend == backend else { return }
      end(reason: "transition")
    }
  }

  // MARK: - Begin (P1, P2 at selection time)

  private func begin(
    mode: OtherAudioWhileDictating, backend: OtherAudioBackend, startDelay: TimeInterval
  ) {
    let volume = deps.effects.volume
    guard let deviceID = deps.defaultOutputDeviceID(), let device = volume.identity(of: deviceID)
    else {
      deps.log("hold skipped mode=\(mode.rawValue) reason=no_output_device")
      deps.telemetry.recordTakeSummary(
        OtherAudioTakeSummary(
          mode: mode.rawValue, volume: .notApplied, mute: .notApplied,
          media: .nothingPaused, outputTransport: nil, failure: "no_output_device"))
      return
    }

    let volumeRead = volume.readVolume(of: device.id)
    let muteRead = volume.readMute(of: device.id)
    let transport =
      AudioDeviceEnumerator.transportLabel(forTransportType: device.transportTypeRaw) ?? "other"
    // A read FAILURE is not "unsupported": the volume-zero fallback is authorised
    // only for a device with no mute control, never for one we could not read.
    let requiredReadFailed: Bool
    switch mode {
    case .turnDown: requiredReadFailed = volumeRead == .unreadable
    case .mute:
      requiredReadFailed =
        muteRead == .unreadable || (muteRead == .unsupported && volumeRead == .unreadable)
    case .nothing, .pauseMusic: requiredReadFailed = false
    }
    if requiredReadFailed {
      deps.log("hold skipped mode=\(mode.rawValue) device=\(device.uid) reason=output_read_failed")
      deps.telemetry.breadcrumb(
        "other_audio skipped", data: ["mode": mode.rawValue, "reason": "output_read_failed"])
      deps.telemetry.recordTakeSummary(
        OtherAudioTakeSummary(
          mode: mode.rawValue, volume: .notApplied, mute: .notApplied, media: .nothingPaused,
          outputTransport: transport, failure: "output_read_failed"))
      return
    }
    var original = OutputVolumeSnapshot(deviceUID: device.uid)
    if case .value(let v) = volumeRead { original.volume = v }
    if case .value(let m) = muteRead { original.muted = m }

    var record = OtherAudioHoldRecord(
      id: UUID(), pid: deps.pid, mode: mode.rawValue, createdAt: Date(),
      original: original, volume: .notApplied, mute: .notApplied, media: .nothingPaused)

    switch mode {
    case .nothing:
      return
    case .turnDown:
      if let v = original.volume {
        record.intendedVolume = v * Self.turnDownFactor
        record.volume = .appliedUnconfirmed
      }
    case .mute:
      if original.muted == true {
        // Already muted by the user: nothing to apply, nothing to restore (P2).
      } else if original.muted == false {
        record.intendedMute = true
        record.mute = .appliedUnconfirmed
      } else if original.volume != nil {
        // No mute control: volume-zero fallback.
        record.intendedVolume = 0
        record.volume = .appliedUnconfirmed
      }
    case .pauseMusic:
      record.media = .pending
    }

    let selectedNothing =
      record.volume == .notApplied && record.mute == .notApplied && record.media != .pending
    if selectedNothing {
      let reason =
        (mode == .mute && original.muted == true) ? "already_muted" : "unsupported_output"
      deps.log("hold skipped mode=\(mode.rawValue) device=\(device.uid) reason=\(reason)")
      deps.telemetry.breadcrumb(
        "other_audio skipped", data: ["mode": mode.rawValue, "reason": reason])
      deps.telemetry.recordTakeSummary(
        OtherAudioTakeSummary(
          mode: mode.rawValue, volume: .notApplied, mute: .notApplied, media: .nothingPaused,
          outputTransport: transport, failure: reason == "already_muted" ? nil : reason))
      return
    }

    // P1: the record is the acknowledgement; no write, no mutation.
    let t0 = deps.nowMicros()
    do {
      try deps.store.write(record)
    } catch {
      deps.log("hold skipped mode=\(mode.rawValue) reason=record_failed")
      deps.telemetry.breadcrumb(
        "other_audio record_failed", data: ["mode": mode.rawValue, "error": Self.errorClass(error)])
      deps.telemetry.recordTakeSummary(
        OtherAudioTakeSummary(
          mode: mode.rawValue, volume: .notApplied, mute: .notApplied, media: .nothingPaused,
          outputTransport: transport, failure: "record_failed"))
      return
    }
    let recordMicros = deps.nowMicros() - t0

    var current = Live(record: record, backend: backend, transport: transport)
    current.recordMicros = recordMicros
    live = current
    deps.log(
      "hold id=\(record.id) opened mode=\(mode.rawValue) device=\(device.uid) record_us=\(recordMicros)"
    )

    if mode == .pauseMusic {
      // No property is selected: nothing to apply, no apply task, no timings.
      startMediaPause(holdID: record.id)
      return
    }

    let holdID = record.id
    let sleep = deps.sleep
    live?.applyTask = Task { @MainActor [weak self] in
      if startDelay > 0 {
        do { try await sleep(startDelay) } catch { return }
      }
      guard let self, let current = self.live, current.record.id == holdID, !Task.isCancelled else {
        return
      }
      self.apply(holdID: holdID)
    }
  }

  // MARK: - Apply (P2, P3, P4)

  private func apply(holdID: UUID) {
    guard var current = live, current.record.id == holdID else { return }
    let volume = deps.effects.volume
    let t0 = deps.nowMicros()
    guard let device = volume.device(forUID: current.record.original.deviceUID) else {
      // The device left before we touched it: nothing was applied (P2 for both).
      if current.record.volume == .appliedUnconfirmed { current.record.volume = .notApplied }
      if current.record.mute == .appliedUnconfirmed { current.record.mute = .notApplied }
      current.applied = true
      live = current
      persist(current.record)
      deps.log("hold id=\(holdID) apply skipped reason=device_gone")
      return
    }

    if current.record.volume == .appliedUnconfirmed, let intended = current.record.intendedVolume {
      // Re-read: a change during the cue delay means the user moved it (P2).
      if case .value(let now) = volume.readVolume(of: device),
        let original = current.record.original.volume,
        abs(now - original) <= Self.volumeTolerance
      {
        if volume.setVolume(intended, of: device) {
          if case .value(let readBack) = volume.readVolume(of: device) {
            current.record.appliedVolume = readBack
            current.record.volume = .applied
          }  // else stays appliedUnconfirmed (P4)
        } else {
          current.record.volume = .notApplied
        }
      } else {
        current.record.volume = .notApplied
      }
    }

    if current.record.mute == .appliedUnconfirmed, let intended = current.record.intendedMute {
      if case .value(let now) = volume.readMute(of: device),
        let original = current.record.original.muted, now == original
      {
        if volume.setMute(intended, of: device) {
          if case .value(let readBack) = volume.readMute(of: device) {
            current.record.appliedMute = readBack
            current.record.mute = .applied
          }
        } else {
          current.record.mute = .notApplied
        }
      } else {
        current.record.mute = .notApplied
      }
    }

    current.applied = true
    live = current
    persist(current.record)
    // The record write is part of what the transition path pays for (plan §8).
    current.applyMicros = deps.nowMicros() - t0 + (current.recordMicros ?? 0)
    live = current
    deps.log(
      "hold id=\(holdID) applied mode=\(current.record.mode) volume=\(current.record.volume.rawValue) "
        + "mute=\(current.record.mute.rawValue) elapsed_us=\(current.applyMicros ?? -1)")
  }

  /// The second and later writes: a failure keeps the live obligation and the
  /// in-memory read-back (R4); only the recovery copy is known stale.
  private func persist(_ record: OtherAudioHoldRecord) {
    do {
      try deps.store.update(id: record.id) { $0 = record }
    } catch {
      deps.log("hold id=\(record.id) record_stale error=\(Self.errorClass(error))")
      deps.telemetry.breadcrumb(
        "other_audio record_stale", data: ["error": Self.errorClass(error)])
    }
  }

  // MARK: - Media (M1-M4)

  private func startMediaPause(holdID: UUID) {
    deps.effects.media.pause(holdID: holdID) { [weak self] outcome in
      guard let self else { return }
      self.noteMediaRoute(holdID, outcome)
      switch outcome.result {
      case .paused(let targets):
        self.mutateRecord(holdID) { $0.pausedTargets = targets }
        self.deps.log(
          "hold id=\(holdID) media paused count=\(targets.count) route=\(outcome.route.rawValue)")
      case .nothingPlaying:
        self.settleMedia(holdID, .nothingPaused, reason: nil)
      case .consentNeeded:
        self.settleMedia(holdID, .nothingPaused, reason: "consent_needed")
      case .consentDenied:
        self.settleMedia(holdID, .nothingPaused, reason: "consent_denied")
      case .failed:
        self.settleMedia(holdID, .nothingPaused, reason: "media_failed")
      }
    }
  }

  /// Keeps the route facts on the live take (the summary carries them) or, for
  /// an outcome that lands after the take ended, on the pending settlement.
  private var lateRoutes: [UUID: (route: String, adapterFailure: String?)] = [:]

  private func noteMediaRoute(_ holdID: UUID, _ outcome: MediaPauseOutcome) {
    let route = outcome.route.rawValue
    if var current = live, current.record.id == holdID {
      current.mediaRoute = route
      current.adapterFailure = outcome.adapterFailure
      live = current
    } else if deps.store.read(id: holdID)?.media == .pending {
      lateRoutes[holdID] = (route, outcome.adapterFailure)
    }
    var data = ["route": route]
    if let failure = outcome.adapterFailure { data["adapter_failure"] = failure }
    deps.telemetry.breadcrumb("other_audio media route", data: data)
    if let failure = outcome.adapterFailure {
      deps.log("hold id=\(holdID) adapter unavailable reason=\(failure) route=\(route)")
    }
  }

  private func settleMedia(
    _ holdID: UUID, _ disposition: OtherAudioMediaDisposition, reason: String?
  ) {
    // Whatever happens below, this hold's late route entry is spent here.
    defer { lateRoutes.removeValue(forKey: holdID) }
    // A hold's media settles ONCE (M1 -> M2/M3/M4). A pause outcome that arrives
    // after the resume already settled it (consent prompt answered minutes
    // later, live UAT 2026-09-15) must not rewrite a final disposition.
    let current = (live?.record.id == holdID) ? live?.record : deps.store.read(id: holdID)
    guard current?.media == .pending else { return }
    mutateRecord(holdID) { $0.media = disposition }
    if let reason {
      deps.telemetry.breadcrumb("other_audio media", data: ["reason": reason])
      if var current = live, current.record.id == holdID {
        current.failure = reason
        live = current
      }
    }
    let late = lateRoutes[holdID]
    let onLive = (live?.record.id == holdID) ? live : nil
    deps.telemetry.recordMediaSettled(
      disposition, holdID: holdID, failure: reason,
      route: onLive?.mediaRoute ?? late?.route,
      adapterFailure: onLive?.adapterFailure ?? late?.adapterFailure)
    deps.log(
      "hold id=\(holdID) media settled disposition=\(disposition.rawValue) reason=\(reason ?? "none")"
    )
    retireIfResolved(holdID)
  }

  /// Mutates the live copy when this hold is still live, and always the record on
  /// disk (a late completion for an ended hold still reaches its own file, R5).
  private func mutateRecord(_ holdID: UUID, _ mutate: (inout OtherAudioHoldRecord) -> Void) {
    if var current = live, current.record.id == holdID {
      mutate(&current.record)
      live = current
      persist(current.record)
      return
    }
    do {
      try deps.store.update(id: holdID, mutate)
    } catch {
      deps.log("hold id=\(holdID) record_stale error=\(Self.errorClass(error))")
    }
  }

  // MARK: - End (P5-P9), retirement (R1-R5)

  private func end(reason: String) {
    guard var current = live else { return }
    current.applyTask?.cancel()
    current.applyTask = nil
    let holdID = current.record.id

    if !current.applied {
      // Nothing was written; the selected properties were never applied (P2).
      if current.record.volume == .appliedUnconfirmed { current.record.volume = .notApplied }
      if current.record.mute == .appliedUnconfirmed { current.record.mute = .notApplied }
    }

    let hasPropertyObligation =
      current.record.volume.blocksRetirement || current.record.mute.blocksRetirement
    let t0 = deps.nowMicros()
    restoreProperties(&current.record)

    live = nil
    // The route facts outlive the live take: the media half settles after it.
    if current.record.media == .pending, let route = current.mediaRoute {
      lateRoutes[holdID] = (route, current.adapterFailure)
    }
    persist(current.record)
    let restoreMicros = hasPropertyObligation ? deps.nowMicros() - t0 : nil

    deps.log(
      "hold id=\(holdID) restored reason=\(reason) volume=\(current.record.volume.rawValue) "
        + "mute=\(current.record.mute.rawValue) media=\(current.record.media.rawValue) "
        + "elapsed_us=\(restoreMicros ?? -1)")
    deps.telemetry.breadcrumb(
      "other_audio restored",
      data: [
        "mode": current.record.mode, "volume": current.record.volume.rawValue,
        "mute": current.record.mute.rawValue, "media": current.record.media.rawValue,
      ])
    deps.telemetry.recordTakeSummary(
      OtherAudioTakeSummary(
        mode: current.record.mode, volume: current.record.volume, mute: current.record.mute,
        media: current.record.media, outputTransport: current.transport,
        applyMicros: current.applyMicros, restoreMicros: restoreMicros,
        recordMicros: current.recordMicros,
        failure: current.failure
          ?? ((current.record.volume == .unresolved || current.record.mute == .unresolved)
            ? "restore_failed" : nil),
        mediaRoute: current.mediaRoute, adapterFailure: current.adapterFailure,
        holdID: holdID))

    if current.record.media == .pending {
      deps.effects.media.resume(holdID: holdID) { [weak self] outcome in
        guard let self else { return }
        switch outcome {
        case .resumed: self.settleMedia(holdID, .resumed, reason: nil)
        case .nothingToResume: self.settleMedia(holdID, .nothingPaused, reason: nil)
        case .sourceChanged: self.settleMedia(holdID, .sourceChanged, reason: nil)
        case .failed: self.settleMedia(holdID, .resumeFailed, reason: "resume_failed")
        }
      }
    }
    retireIfResolved(holdID)
  }

  /// P5-P9 over one record, against the device it names. Mutates dispositions
  /// in place; never reports `restored` for a write that did not succeed.
  private func restoreProperties(_ record: inout OtherAudioHoldRecord) {
    let volume = deps.effects.volume
    let needsDevice = record.volume.blocksRetirement || record.mute.blocksRetirement
    guard needsDevice else { return }
    guard let device = volume.device(forUID: record.original.deviceUID) else {
      if record.volume.blocksRetirement { record.volume = .skippedDeviceGone }
      if record.mute.blocksRetirement { record.mute = .skippedDeviceGone }
      return
    }

    switch record.volume {
    case .applied:
      guard record.appliedVolume != nil else {
        // `applied` is only ever written together with its read-back (P3); a
        // record without one is our own invariant broken, not a device condition.
        deps.telemetry.captureDefect("applied volume without read-back", data: ["property": "volume"])
        record.volume = .unresolved
        break
      }
      if case .value(let now) = volume.readVolume(of: device), let applied = record.appliedVolume {
        if abs(now - applied) <= Self.volumeTolerance {
          if let original = record.original.volume, volume.setVolume(original, of: device) {
            record.volume = .restored
          } else {
            record.volume = .unresolved
          }
        } else {
          record.volume = .skippedUserChanged
        }
      } else {
        record.volume = .unresolved
      }
    case .appliedUnconfirmed:
      record.volume = .unresolved
    default:
      break
    }

    switch record.mute {
    case .applied:
      guard record.appliedMute != nil else {
        deps.telemetry.captureDefect("applied mute without read-back", data: ["property": "mute"])
        record.mute = .unresolved
        break
      }
      if case .value(let now) = volume.readMute(of: device), let applied = record.appliedMute {
        if now == applied {
          if let original = record.original.muted, volume.setMute(original, of: device) {
            record.mute = .restored
          } else {
            record.mute = .unresolved
          }
        } else {
          record.mute = .skippedUserChanged
        }
      } else {
        record.mute = .unresolved
      }
    case .appliedUnconfirmed:
      record.mute = .unresolved
    default:
      break
    }
  }

  /// R1 against the PERSISTED copy (R4): a final update that failed to reach disk
  /// leaves the record for the next launch rather than deleting it on an
  /// in-memory verdict nothing recorded.
  private func retireIfResolved(_ holdID: UUID) {
    if deps.store.removeIfResolved(id: holdID) {
      deps.log("record retired id=\(holdID)")
    }
  }

  // MARK: - Settings page reads

  /// Whether the CURRENT default output can carry this mode: `turnDown` needs a
  /// settable volume, `mute` a settable mute or the volume fallback. Reads only;
  /// `pauseMusic` and `nothing` are always available.
  func isModeAvailable(_ mode: OtherAudioWhileDictating) -> Bool {
    switch mode {
    case .nothing, .pauseMusic:
      return true
    case .turnDown, .mute:
      guard let deviceID = deps.defaultOutputDeviceID() else { return false }
      // A read FAILURE does not prove the device lacks the capability.
      let volumeRead = deps.effects.volume.readVolume(of: deviceID)
      if mode == .turnDown { return volumeRead != .unsupported }
      let muteRead = deps.effects.volume.readMute(of: deviceID)
      return muteRead != .unsupported || volumeRead != .unsupported
    }
  }

  /// Probes the adapter off the main actor and, only when it cannot answer on
  /// this Mac, raises the Automation prompt for running players so it lands
  /// when the user picks `Pause music` rather than mid-take. `completion`
  /// reports whether "pause anything" is available here.
  func preflightConsent(completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
    deps.effects.media.preflightConsent(completion: completion)
  }

  // MARK: - Launch and quit

  /// Adopt every record left by a dead process (P10-P12, M1-M4), synchronously,
  /// BEFORE any take can start. A record whose pid is alive is another running
  /// build's live hold and is left alone.
  func adoptOrphans() {
    let records = deps.store.readAll(rejected: { [deps] name in
      deps.log("record rejected name=\(name)")
      deps.telemetry.breadcrumb("other_audio record_rejected", data: [:])
    })
    for var record in records {
      if record.pid != deps.pid, deps.isProcessAlive(record.pid) {
        deps.log("record left alone id=\(record.id) live_pid=\(record.pid)")
        continue
      }
      deps.log("orphan adopted id=\(record.id) mode=\(record.mode)")
      adoptProperties(&record)
      persist(record)
      deps.telemetry.breadcrumb(
        "other_audio orphan adopted",
        data: [
          "mode": record.mode, "volume": record.volume.rawValue, "mute": record.mute.rawValue,
        ])
      if record.media == .pending, !record.pausedTargets.isEmpty {
        let holdID = record.id
        deps.effects.media.resumeOrphan(holdID: holdID, targets: record.pausedTargets) {
          [weak self] outcome in
          guard let self else { return }
          switch outcome {
          case .resumed: self.settleMedia(holdID, .resumed, reason: nil)
          case .nothingToResume: self.settleMedia(holdID, .nothingPaused, reason: nil)
          case .sourceChanged: self.settleMedia(holdID, .sourceChanged, reason: nil)
          case .failed: self.settleMedia(holdID, .resumeFailed, reason: "resume_failed")
          }
        }
      } else {
        if record.media == .pending {
          record.media = .nothingPaused
          persist(record)
        }
        retireIfResolved(record.id)
      }
    }
  }

  /// P10 (applied: compare against the confirmed read-back), P11 (unconfirmed:
  /// compare against the intended value), P12 (anything else: leave alone).
  private func adoptProperties(_ record: inout OtherAudioHoldRecord) {
    let volume = deps.effects.volume
    let needsDevice = record.volume.blocksRetirement || record.mute.blocksRetirement
    guard needsDevice else { return }
    guard let device = volume.device(forUID: record.original.deviceUID) else {
      if record.volume.blocksRetirement { record.volume = .skippedDeviceGone }
      if record.mute.blocksRetirement { record.mute = .skippedDeviceGone }
      return
    }
    if record.volume.blocksRetirement {
      let reference = record.volume == .applied ? record.appliedVolume : record.intendedVolume
      if case .value(let now) = volume.readVolume(of: device), let reference {
        if abs(now - reference) <= Self.volumeTolerance {
          if let original = record.original.volume, volume.setVolume(original, of: device) {
            record.volume = .restored
          } else {
            record.volume = .unresolved
          }
        } else {
          record.volume = .skippedUserChanged
        }
      } else {
        record.volume = .unresolved
      }
    }
    if record.mute.blocksRetirement {
      let reference = record.mute == .applied ? record.appliedMute : record.intendedMute
      if case .value(let now) = volume.readMute(of: device), let reference {
        if now == reference {
          if let original = record.original.muted, volume.setMute(original, of: device) {
            record.mute = .restored
          } else {
            record.mute = .unresolved
          }
        } else {
          record.mute = .skippedUserChanged
        }
      } else {
        record.mute = .unresolved
      }
    }
  }

  /// A Cocoa quit: finish the LIVE hold from memory (never from the recovery
  /// copy), synchronously for the property half; the media half is enqueued
  /// best-effort and, if it cannot settle before exit, is adopted next launch.
  func finishForTermination() {
    guard live != nil else { return }
    end(reason: "terminate")
  }

  private static func errorClass(_ error: any Error) -> String {
    let ns = error as NSError
    return "\(ns.domain)#\(ns.code)"
  }
}
