import EnviousWisprCore
import Foundation

/// #1635: canonical copy for the WhisperKit "Model Setup" row's two settled-ish states.
///
/// The row previously had ONE state and it lied. "Model Ready" is delivery truth — the
/// model is admitted on disk — but the engine then loads into memory for a measured p50 of
/// 27.4s on the engine-swap path (90d production `coldstart.warmup_completed`, WhisperKit,
/// `reason = engine_swap`; p90 44.2s). A press inside that window is correctly refused with
/// the warming pill, so the green tick contradicted the app for roughly half a minute on
/// the exact path a user hits right after downloading.
///
/// **THE DURATION IS HONEST ONLY BECAUSE THE STATE IS NARROW, and that is not an accident.**
/// `warmInFlight` is set solely by `EngineCoordinator.startWarm`, which is the
/// post-switch warm — precisely the `engine_swap` population the 27.4s median describes.
/// The launch preload and the cold-press warm call their drivers directly and never set it,
/// and their medians are 10.1s and 9.0s. If this state is ever widened to cover those
/// paths, "about 30 seconds" becomes wrong and must be re-derived from whatever population
/// it then describes. Do not widen one without the other.
///
/// "usually" is load-bearing: p90 on this path is 44.2s, so a hard promise would be broken
/// for about a quarter of users. A progress percentage is impossible — WhisperKit exposes
/// no load-progress stream (`whisperkit-research.md` FACT: cold-start-warmup-lifecycle).
///
/// Copy frozen by the founder 2026-08-01, who explicitly declined further wordsmithing.
/// `ModelPreparingCopyTests` pins both strings so a change is a conscious act.
/// No em-dashes or en-dashes (brand rule).
enum ModelPreparingCopy {
  /// Shown while the coordinator-owned warm is in flight.
  static let preparing = "Getting the model ready. This usually takes about 30 seconds."
  /// The unchanged settled label.
  static let ready = "Model Ready"

  /// Whether the row should show the preparing state.
  ///
  /// Deliberately takes `warmInFlight` and NOTHING else. It never consults adapter
  /// readiness: a snapshot keyed on readiness at warm-start still reads `.notReady`,
  /// because the adapter does not reach `.warming` until inside the awaited load. That is
  /// exactly how the previous attempt at this issue produced a label that could never
  /// appear.
  ///
  /// `nil` covers both "nothing is warming" and "no coordinator in the environment"
  /// (previews and tests). Both fail toward the copy we have shipped for months; a stale
  /// "ready" is the status quo, whereas a stuck "preparing" would be a NEW lie with no way
  /// out.
  static func isPreparing(warmInFlight: ASRBackendType?) -> Bool {
    warmInFlight == .whisperKit
  }

  /// The label for a given warm state. Convenience over `isPreparing` for the row.
  static func label(warmInFlight: ASRBackendType?) -> String {
    isPreparing(warmInFlight: warmInFlight) ? preparing : ready
  }
}
