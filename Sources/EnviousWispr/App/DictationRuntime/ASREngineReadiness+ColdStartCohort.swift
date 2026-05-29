import EnviousWisprPipeline

extension ASREngineReadiness {
  /// PR-7 (#827): stable cold-start cohort token for the `PTT-to-recording`
  /// log line (`engineReadinessAtPTT=`). Exhaustive `switch` (not `rawValue`)
  /// so a new `ASREngineReadiness` case is a compile error here, not a silent
  /// unlabeled cohort that would pollute the §3a cold-start SLO. `ready` = warm
  /// (no load cost this press); `notReady` = cold (full load); `warming` = a
  /// load is in flight (mid-flight, kept distinct so it skews neither cohort).
  /// Lives in the App module (telemetry concern), kept off `RecordingStarter`
  /// so the start-path home stays within its method/line ceilings.
  var coldStartCohortToken: String {
    switch self {
    case .notReady: return "notReady"
    case .warming: return "warming"
    case .ready: return "ready"
    }
  }
}
