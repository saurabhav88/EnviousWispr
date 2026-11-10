import EnviousWisprLocalPolish
import Foundation

#if DEBUG
  /// The DEBUG slot read of the bundled `llama-server` (#4319, moved here by #4473).
  ///
  /// The process manager built this request and parsed its answer itself. They are the same
  /// request, status rules and whitelist parser; only their owner changed. The manager keeps
  /// what belongs to the process (is it ready, which launch, was it replaced meanwhile) and
  /// runs the operation this type supplies.
  public enum LlamaServerSlotReader {
    /// A read-only control request: authenticated `GET /slots` on this manager's own ready
    /// server. Takes no lease, no reservation and no admission epoch; starts, probes and stops
    /// nothing. Bounded like the readiness check (`awaitServerUp`, 2 s per request).
    ///
    /// #4473: a transport failure is THROWN to the manager, which reports `transportFailed`;
    /// every answer the server did give comes back as an observation.
    public static func operation(
      send: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
        try await URLSession.shared.data(for: $0)
      }
    ) -> LocalPolishSlotInspection {
      { endpoint, launchGeneration in
        guard let url = URL(string: "http://127.0.0.1:\(endpoint.port)/slots") else {
          return .unavailable
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        request.setValue("Bearer \(endpoint.authToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: break
        case 404, 501: return .unsupported
        default: return .httpStatus(status)
        }
        return parseSlots(data, launchGeneration: launchGeneration)
          .map(EGOneSlotObservation.observed) ?? .malformed
      }
    }

    /// Whitelisted fields only: never the request's params, prompt or generated text.
    static func parseSlots(_ data: Data, launchGeneration: Int) -> EGOneSlotSnapshot? {
      guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
        return nil
      }
      var slots: [EGOneSlotSnapshot.Slot] = []
      for row in rows {
        guard let id = row["id"] as? Int, let processing = row["is_processing"] as? Bool else {
          return nil
        }
        let next = (row["next_token"] as? [[String: Any]])?.first
        slots.append(
          .init(
            id: id, isProcessing: processing, taskID: row["id_task"] as? Int,
            decodedTokens: next?["n_decoded"] as? Int, remainingTokens: next?["n_remain"] as? Int))
      }
      return EGOneSlotSnapshot(launchGeneration: launchGeneration, slots: slots)
    }
  }
#endif
