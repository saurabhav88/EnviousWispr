import EnviousWisprCore
import Foundation

/// #3853: how long the bundled polish helper may sit unused before it frees its model memory.
///
/// The user picks the same choices as the speech model's unload setting (`ModelUnloadPolicy`).
/// Both bundled engines, `llama-server` (S1-mini) and the EnviousDecode helper (EG-1), take the
/// same flag with the same meaning: after that many idle seconds the process drops its model
/// but keeps running, and the next request loads it again. This type is the one place that
/// turns the choice into seconds and into the flag, so the two engines cannot disagree.
public enum LocalPolishSleepIdle {
  /// The flag's name on both engines.
  public static let argumentName = "--sleep-idle-seconds"

  /// "Immediately" is ten seconds, not one: a file import or a meeting summary sends several
  /// requests with short gaps, and a one-second idle time could free the model between parts.
  public static let immediatelySeconds = 10

  /// Idle seconds for a choice, or nil when the model must stay loaded (Never).
  public static func seconds(for policy: ModelUnloadPolicy) -> Int? {
    switch policy {
    case .never: return nil
    case .immediately: return immediatelySeconds
    case .twoMinutes, .fiveMinutes, .tenMinutes, .fifteenMinutes, .sixtyMinutes:
      return policy.interval.map { Int($0) }
    }
  }

  /// The launch arguments for an idle time: none for nil (Never), else the flag and its value.
  public static func arguments(seconds: Int?) -> [String] {
    guard let seconds, seconds > 0 else { return [] }
    return [argumentName, String(seconds)]
  }
}

/// #3853: the idle seconds the launch builders read each time the runtime builds a spec. The
/// settings object lives on the main actor and a launch factory is a plain `@Sendable` closure,
/// so the composition root keeps this one value in step with the setting: it is set once at
/// startup from the saved choice and again by the settings-change route before the runtime is
/// asked to rebuild its spec.
public final class LocalPolishSleepIdleSetting: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Int?

  public init(seconds: Int? = nil) { stored = seconds }

  public var seconds: Int? {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }

  /// Convenience for the launch factories: a closure that reads the current value.
  public var reader: @Sendable () -> Int? { { [self] in seconds } }
}
