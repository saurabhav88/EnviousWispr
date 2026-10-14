import Foundation

/// Observed exit facts, not a diagnosis of the underlying fault (#3685).
/// No command, path, output or environment can enter this value.
public struct ChildProcessFailure: Error, Sendable, Equatable, StableSentryErrorIdentity {
  public enum Role: String, Sendable { case server = "local_polish_server", sweep = "orphan_sweep" }
  public enum Phase: String, Sendable { case starting, ready, cleanup }
  public enum Termination: String, Sendable { case exit, signal }

  public let role: Role
  public let provider: LLMProvider?
  public let generation: Int?
  /// Last lifecycle phase published by the owner before observation.
  public let phase: Phase
  public let termination: Termination?
  public let status: Int32?
  public let pid: Int32?
  public let launchErrorCode: Int?

  public init(
    role: Role, provider: LLMProvider?, generation: Int?, phase: Phase,
    termination: Termination? = nil, status: Int32? = nil, pid: Int32? = nil,
    launchErrorCode: Int? = nil
  ) {
    self.role = role
    self.provider = provider
    self.generation = generation
    self.phase = phase
    self.termination = termination
    self.status = termination == nil ? nil : status
    self.pid = pid.flatMap { $0 > 0 ? $0 : nil }
    self.launchErrorCode = termination == nil ? launchErrorCode : nil
  }

  public var sentryFingerprintDescriptor: String { "OwnedChildProcessFailure#1" }
  public var sentrySemanticID: String { "owned_child_process_failure" }
  public var groupingDetail: String { "\(role.rawValue):\(provider?.rawValue ?? "unknown")" }

  public var stringProperties: [String: String] {
    var result = [
      "role": role.rawValue, "phase": phase.rawValue, "cause": "unknown",
      "failure_kind": termination == nil ? "launch_failed" : "unexpected_exit",
      "native_stack": "not_captured",
    ]
    if let provider {
      result[role == .server ? "owning_provider" : "cleanup_initiator"] = provider.rawValue
    }
    if let termination { result["termination_reason"] = termination.rawValue }
    return result
  }

  public var integerProperties: [String: Int] {
    var result: [String: Int] = [:]
    if let generation { result["generation"] = generation }
    if let status { result["termination_status"] = Int(status) }
    if let pid { result["process_id"] = Int(pid) }
    if let launchErrorCode { result["launch_error_code"] = launchErrorCode }
    return result
  }
}
