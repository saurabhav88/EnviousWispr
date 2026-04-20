import Foundation

/// Coarse-grained activity projection shared by every backend's state enum.
///
/// Used for CONTROL FLOW ONLY (is-active, warning gating, telemetry routing).
/// User-visible labels come from each pipeline's own `overlayIntent`, not from
/// this projection — collapsing "Starting..." and "Loading model..." into a
/// shared `.preparing` bucket would silently flatten visible labels.
public enum PipelineActivity: Equatable, Sendable {
  case idle
  case preparing
  case recording
  case processing
  case complete
  case error(String)
}

/// Narrow protocol the planner / handler consume. Backends' concrete enums
/// conform by extension; the planner never inspects their specific cases.
public protocol PipelineStateProtocol: Equatable, Sendable {
  var activity: PipelineActivity { get }
  var isActive: Bool { get }
  var errorReason: String? { get }
}

// MARK: - Parakeet (PipelineState) conformance

extension PipelineState: PipelineStateProtocol {
  public var activity: PipelineActivity {
    switch self {
    case .idle: return .idle
    case .loadingModel: return .preparing
    case .recording: return .recording
    case .transcribing, .polishing: return .processing
    case .complete: return .complete
    case .error(let msg): return .error(msg)
    }
  }

  public var errorReason: String? {
    if case .error(let msg) = self { return msg }
    return nil
  }
}
