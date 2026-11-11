import EnviousWisprCore
import EnviousWisprLocalPolish

/// The bundled `llama-server` as a local polish engine (#4473).
///
/// It adds nothing of its own: each requirement is the value its existing owner already
/// supplies. Launch arguments stay with `LlamaServerLaunchBuilder`, the probe with
/// `LlamaServerHealthProbe`, the DEBUG slot read with `LlamaServerSlotReader`. S1-mini runs on
/// this engine. EG-1 has its own (`EnviousDecodeEngine`).
public struct LlamaServerEngine: LocalPolishEngine {
  public init() {}

  public var makeLaunchConfiguration: LocalPolishLaunchConfigurationFactory {
    LlamaServerLaunchBuilder.makeConfiguration
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
