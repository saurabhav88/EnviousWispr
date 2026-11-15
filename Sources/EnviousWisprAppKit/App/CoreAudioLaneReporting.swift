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

/// The DEBUG `force_core_audio_stall` target for the fault endpoint; nil in Release.
func debugCoreAudioStall(lane: CoreAudioQueryLane) -> ((Duration) -> Void)? {
  #if DEBUG
    return { lane.armStallForNextRead($0) }
  #else
    return nil
  #endif
}
