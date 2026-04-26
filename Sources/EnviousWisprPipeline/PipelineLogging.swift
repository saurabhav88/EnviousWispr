import EnviousWisprCore
import Foundation

/// Dependency-injection seam for the post-ASR text-processing chain's log sink.
///
/// `TextProcessingRunner` uses this to keep its log calls testable (the
/// production default routes to `AppLogger.shared`; tests pass a recorder that
/// captures entries in memory). Internal to `EnviousWisprPipeline` — there is
/// no cross-module conformer today, so promoting it to `Core` would expand
/// surface area without payoff.
internal protocol PipelineLogging: Sendable {
  func log(_ message: String, level: DebugLogLevel, category: String) async
}

/// Production conformer: routes every call to the existing
/// `AppLogger.shared` actor. Stateless adapter — adding a default-init
/// keeps `TextProcessingRunner.init(logger:)` ergonomic.
internal struct AppLoggerAdapter: PipelineLogging {
  init() {}
  func log(_ message: String, level: DebugLogLevel, category: String) async {
    await AppLogger.shared.log(message, level: level, category: category)
  }
}
