import EnviousWisprLLM
import EnviousWisprLocalPolish

/// The connectors of the two bundled local polish models, handed to the pipeline (#4473).
///
/// The polish step used to build `EGOneConnector` and `S1MiniConnector` itself, so the
/// pipeline named the engine that serves each model. The composition root now supplies both
/// factories and every path that constructs a polish step passes them on: live dictation,
/// crash recovery and file import. Both are REQUIRED and there is no default, so no path can
/// construct a step that quietly falls back to a connector nobody chose.
///
/// Two closures and nothing else: which model a take uses, and whether its server is ready,
/// stay decided by the step from the provider and the runtime handles. Two factories rather
/// than one that switches on the provider, for the reason the step records: the connectors
/// differ in what an empty answer MEANS, and that decision belongs to the connector.
public struct BundledLocalPolisherFactories {
  public typealias Factory = @MainActor (EGOneEndpoint) -> any TranscriptPolisher

  public let egOne: Factory
  public let s1Mini: Factory

  public init(egOne: @escaping Factory, s1Mini: @escaping Factory) {
    self.egOne = egOne
    self.s1Mini = s1Mini
  }
}
