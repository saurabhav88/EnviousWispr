import Foundation

/// One health check of a READY local polish process (#4473): given the live endpoint, ask the
/// model a real question and grade the answer.
///
/// The process manager and the coordinator run this operation without knowing what it sends.
/// The engine that serves the model supplies it, so the code that owns the process holds no
/// prompt, no connector and no model name. It is called only for a ready process; every other
/// state is answered by the manager from the state alone.
public typealias LocalPolishHealthProbe = @Sendable (EGOneEndpoint) async -> EGOneHealth
