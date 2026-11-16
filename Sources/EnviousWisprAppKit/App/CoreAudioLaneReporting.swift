import EnviousWisprAudio
import EnviousWisprCore
import EnviousWisprServices

/// What the shared `CoreAudioQueryLane` reports (#4021): a read that got no answer in time and a
/// read that later recovered go to telemetry; in DEBUG, every read's duration and any armed UAT
/// stall go to the app log. The lane lives in the Audio module and cannot reach these services,
/// so the composition root builds its hooks here.
enum CoreAudioLaneReporting {
  /// Hooks for the production lane. Each hops to the main actor (telemetry) or into the logger
  /// actor; none blocks the lane's queue.
  static func hooks() -> CoreAudioQueryLane.Hooks {
    var hooks = CoreAudioQueryLane.Hooks(
      timedOut: { name, bound in
        Task { @MainActor in report(name: name, phase: .timedOut, bound: bound, returnedAfter: nil)
        }
      },
      abandonedReadReturned: { name, after, bound in
        Task { @MainActor in
          report(name: name, phase: .recovered, bound: bound, returnedAfter: after)
        }
      })
    #if DEBUG
      hooks.completed = { name, duration in
        Task {
          await AppLogger.shared.log(
            "lane read \(name) took \(milliseconds(duration)) ms", level: .debug,
            category: "CoreAudioLane")
        }
      }
      hooks.debugStallFired = { name, stall in
        Task {
          await AppLogger.shared.log(
            "fault fired: lane read \(name) stalled \(milliseconds(stall)) ms", level: .info,
            category: "CoreAudioLane")
        }
      }
    #endif
    return hooks
  }

  /// Maps a lane read name onto the event's closed vocabulary and emits it. An unknown name is
  /// dropped, never sent as free text.
  @MainActor
  static func report(
    name: String, phase: CoreAudioReadTelemetry.Phase, bound: Duration, returnedAfter: Duration?,
    service: TelemetryService = .shared
  ) {
    guard let read = CoreAudioReadTelemetry.Read(rawValue: name) else { return }
    service.coreAudioReadStuck(
      read: read, phase: phase, boundMs: milliseconds(bound),
      returnedAfterMs: returnedAfter.map(milliseconds))
  }

  static func milliseconds(_ duration: Duration) -> Int {
    Int(duration.components.seconds) * 1000
      + Int(duration.components.attoseconds / 1_000_000_000_000_000)
  }
}

/// What the audio-unit lane reports (#4601 §3.8): a job that passed its own operation limit
/// (`timed_out`, the lane is stuck) and such a job that later returned (`recovered`, with how
/// long it took) go to `audio.core_audio_read_stuck`, at most one of each per job. A start
/// refused while the lane is stuck runs no job and sends nothing. In DEBUG, every job's duration
/// and any armed stall go to the app log.
enum AudioUnitLaneReporting {
  /// Every operation name the lane runs, mapped onto the event's closed vocabulary. Explicit
  /// rather than pattern-matched, so a new lane job with no row here is dropped (never sent as
  /// free text) and `CoreAudioReadTelemetryTests.everyLaneJobNameIsMapped` names it.
  static let readForOperation: [String: CoreAudioReadTelemetry.Read] = [
    "microphone_start": .microphoneStart,
    "microphone_release": .microphoneRelease,
    // Every read on the lane checks the microphone or its route.
    "running_probe": .microphoneProbe,
    "warm_bind_check": .microphoneProbe,
    "default_input_uid": .microphoneProbe,
    "native_rate": .microphoneProbe,
    "device_liveness": .microphoneProbe,
    "route_resolve": .microphoneProbe,
  ]

  static func hooks() -> AudioUnitLane.Hooks {
    var hooks = AudioUnitLane.Hooks(
      operationTimedOut: { _, name, limit in
        Task { @MainActor in report(name: name, phase: .timedOut, limit: limit, after: nil) }
      },
      operationRecovered: { _, name, after, limit in
        Task { @MainActor in report(name: name, phase: .recovered, limit: limit, after: after) }
      })
    #if DEBUG
      hooks.completed = { id, name, duration in
        Task {
          await AppLogger.shared.log(
            "unit lane job \(name)#\(id) took \(CoreAudioLaneReporting.milliseconds(duration)) ms",
            level: .debug, category: "AudioUnitLane")
        }
      }
      hooks.debugStallFired = { id, name, stall in
        Task {
          await AppLogger.shared.log(
            "fault fired: unit lane job \(name)#\(id) waits \(CoreAudioLaneReporting.milliseconds(stall)) ms before it runs (pre-operation delay)",
            level: .info, category: "AudioUnitLane")
        }
      }
    #endif
    return hooks
  }

  @MainActor
  static func report(
    name: String, phase: CoreAudioReadTelemetry.Phase, limit: Duration, after: Duration?,
    service: TelemetryService = .shared
  ) {
    guard let read = readForOperation[name] else { return }
    service.coreAudioReadStuck(
      read: read, phase: phase, boundMs: CoreAudioLaneReporting.milliseconds(limit),
      returnedAfterMs: after.map(CoreAudioLaneReporting.milliseconds))
  }
}

/// #4601: the DEBUG `force_core_audio_stall(N,unit:...)` target; nil in Release.
func debugAudioUnitStall(lane: AudioUnitLane) -> ((AudioUnitLane.Operation, Duration) -> Void)? {
  #if DEBUG
    return { lane.armStall(for: $0, $1) }
  #else
    return nil
  #endif
}

/// The DEBUG `force_core_audio_stall` target for the fault endpoint; nil in Release.
func debugCoreAudioStall(lane: CoreAudioQueryLane) -> ((Duration) -> Void)? {
  #if DEBUG
    return { lane.armStallForNextRead($0) }
  #else
    return nil
  #endif
}
