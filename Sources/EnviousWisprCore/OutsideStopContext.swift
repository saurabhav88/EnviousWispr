import Foundation

/// A bundled polish server that was READY was stopped from outside the app
/// (#3988): a clean exit or a stop signal, not a crash. Content-free: no
/// command, path, output or text can enter this value.
public struct OutsideStopContext: Sendable, Hashable {
  /// Memory pressure the app observed when it handled the stop. Context, never
  /// a proven cause: the app sees the termination, not who sent it.
  public enum MemoryPressure: String, Sendable, Hashable {
    case normal, warning, critical
  }

  public let provider: LLMProvider
  /// Launch generation of the child that stopped, never its replacement's.
  /// Together with `provider` this is the stop's identity.
  public let generation: Int
  /// Nil means unknown. It is never read as normal.
  public let memoryPressure: MemoryPressure?

  public init(provider: LLMProvider, generation: Int, memoryPressure: MemoryPressure?) {
    self.provider = provider
    self.generation = generation
    self.memoryPressure = memoryPressure
  }
}
