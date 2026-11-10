import EnviousWisprCore
import EnviousWisprModelDelivery
import Foundation

/// Builds the launch configuration of one local polish model (#4473).
///
/// Arguments, in order: the logical model, the identity of the admitted artifact, the engine
/// executable, the admitted model file, the context capacity, and the learned-word checker
/// adapter the caller wants loaded (nil for none). The answer says what will really launch: an
/// adapter the engine cannot load is absent from the returned spec.
///
/// The runtime calls this once per launch with its own identity and the delivery adapter's
/// admitted values; the engine that serves the model supplies it. The runtime therefore names
/// no engine's command line and no engine type.
public typealias LocalPolishLaunchConfigurationFactory =
  @Sendable (
    LocalPolishModelID, ModelIdentity, URL, URL, Int, URL?
  ) -> EGOneServerManager.Configuration
