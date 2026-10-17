import Foundation

/// Owns startup policy; the Apple adapter supplies the actual native resources (#3457).
/// Failed context attachment never reuses an analyzer whose state is unknown.
enum ApplePreviewSessionSetup {
  static func start<Resource: Sendable>(
    phrases: [String],
    isolation: isolated (any Actor)? = #isolation,
    make: () throws -> Resource,
    attach: (Resource, [String]) async throws -> Void,
    start: (Resource) async throws -> Void,
    discard: (Resource) async -> Void,
    isCurrent: () -> Bool,
    contextFailed: (any Error) async -> Void
  ) async throws -> Resource {
    func checkCurrent() throws {
      try Task.checkCancellation()
      guard isCurrent() else { throw LivePreviewError.superseded }
    }

    try checkCurrent()
    var resource = try make()
    if !phrases.isEmpty {
      do {
        try await attach(resource, phrases)
      } catch {
        await discard(resource)
        // Cancellation/supersession is abandonment, never permission for a fallback.
        try checkCurrent()
        if error is CancellationError { throw error }
        await contextFailed(error)
        try checkCurrent()
        resource = try make()
      }
    }

    do {
      try checkCurrent()
      try await start(resource)
      try checkCurrent()
      return resource
    } catch {
      await discard(resource)
      throw error
    }
  }
}
