import EnviousWisprCore
import EnviousWisprLocalPolish

/// The bundled `llama-server` as a local polish engine (#4473).
///
/// It adds nothing of its own: each requirement is the value its existing owner already
/// supplies. Launch arguments stay with `LlamaServerLaunchBuilder`, the probe with
/// `LlamaServerHealthProbe`, the DEBUG slot read with `LlamaServerSlotReader`. S1-mini runs on
/// this engine. EG-1 has its own (`EnviousDecodeEngine`).
public struct LlamaServerEngine: LocalPolishEngine {
  /// #3853: idle seconds for the server's own sleep flag, read at each launch so a setting change
  /// reaches the next spec the runtime builds. Nil (the default) means never sleep.
  private let sleepIdleSeconds: @Sendable () -> Int?

  public init(sleepIdleSeconds: @escaping @Sendable () -> Int? = { nil }) {
    self.sleepIdleSeconds = sleepIdleSeconds
  }

  public var makeLaunchConfiguration: LocalPolishLaunchConfigurationFactory {
    let sleepIdleSeconds = sleepIdleSeconds
    return { modelID, identity, binary, model, context, adapter in
      LlamaServerLaunchBuilder.makeConfiguration(
        modelID: modelID, artifactIdentity: identity, serverBinaryURL: binary, modelURL: model,
        contextTokens: context, learnedWordAdapterURL: adapter,
        sleepIdleSeconds: sleepIdleSeconds())
    }
  }

  public var makeHealthProbe:
    @Sendable (LocalPolishModelID, PromptFamily) -> LocalPolishHealthProbe
  {
    LlamaServerHealthProbe.make
  }

  #if DEBUG
    public var inspectSlots: LocalPolishSlotInspection {
      LlamaServerSlotReader.operation()
    }
  #endif
}
