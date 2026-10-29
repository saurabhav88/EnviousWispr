import Foundation

/// #3973 C3: a meeting final-transcript engine operation gave way to dictation (its run was
/// preempted or refused because dictation's engine work came first, or the shared model was
/// unloaded under it). Not a decode failure: the job waits and runs the same operation again,
/// with no gap and no progress change.
public struct MeetingEngineYield: Error, Equatable, Sendable {
  public init() {}
}
