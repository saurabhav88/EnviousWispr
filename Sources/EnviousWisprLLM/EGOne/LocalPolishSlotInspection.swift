import Foundation

#if DEBUG
  // MARK: - #4319: DEBUG slot observation (Live UAT evidence only)

  /// What the bundled server's slots were doing, content-free: only slot numbers, whether each
  /// is generating, and how far, so a test can see a cancelled summary stop and free its slot.
  public struct EGOneSlotSnapshot: Sendable, Equatable {
    public struct Slot: Sendable, Equatable {
      public let id: Int
      public let isProcessing: Bool
      public let taskID: Int?
      public let decodedTokens: Int?
      public let remainingTokens: Int?

      /// #4473: explicit and `package`, so the engine that reads the server's answer can
      /// build a slot from another module. Same parameters as the memberwise init it replaces.
      package init(
        id: Int, isProcessing: Bool, taskID: Int?, decodedTokens: Int?, remainingTokens: Int?
      ) {
        self.id = id
        self.isProcessing = isProcessing
        self.taskID = taskID
        self.decodedTokens = decodedTokens
        self.remainingTokens = remainingTokens
      }
    }
    /// Which launch of the server this describes (not a secret; the bearer never leaves).
    public let launchGeneration: Int
    public let slots: [Slot]

    /// #4473: explicit and `package`, for the same reason as `Slot`'s.
    package init(launchGeneration: Int, slots: [Slot]) {
      self.launchGeneration = launchGeneration
      self.slots = slots
    }
  }

  public enum EGOneSlotObservation: Sendable, Equatable {
    case observed(EGOneSlotSnapshot)
    /// No ready server of the asked model.
    case unavailable
    /// The server answered that it has no slots endpoint.
    case unsupported
    case httpStatus(Int)
    case transportFailed
    case malformed
    /// The server was replaced while the request was out: the answer is not about it.
    case replaced
  }

  /// One read of a ready local polish server's slots (#4473): given the live endpoint and the
  /// launch generation it belongs to, ask the server and report what it said.
  ///
  /// The process manager runs this operation without knowing the request or the answer's
  /// shape; the engine that serves the model supplies it. It THROWS for a transport failure
  /// (the manager reports `transportFailed`) and returns an observation for everything the
  /// server did answer. It is called only for a ready server.
  public typealias LocalPolishSlotInspection =
    @Sendable (EGOneEndpoint, Int) async throws -> EGOneSlotObservation
#endif
