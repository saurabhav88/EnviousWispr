#if DEBUG
  import Foundation

  /// #3765: turns one dev-control request into one call on the owner the UI uses.
  ///
  /// The door hands it an admitted command and its arguments; it returns a result payload
  /// or an error code. Only allowlisted command names exist, so the door can log the
  /// command without logging anything the client wrote.
  @MainActor
  final class DevControlDispatcher {
    enum Command: String, CaseIterable {
      case ping
    }

    enum Result {
      case ok([String: Any])
      case error(code: String, message: String)
    }

    init() {}

    func handle(_ command: Command?, args: [String: Any]) async -> Result {
      guard let command else {
        return .error(code: "unknownCommand", message: "no such command")
      }
      switch command {
      case .ping:
        return .ok(["pong": true])
      }
    }
  }
#endif
