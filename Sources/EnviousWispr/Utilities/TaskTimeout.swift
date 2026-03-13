import Foundation

/// Thrown when a `withThrowingTimeout` call exceeds its deadline.
struct TimeoutError: Error, CustomStringConvertible {
    let seconds: Double
    var description: String { "Task timed out after \(seconds)s" }
}

/// Run an async operation with a timeout. If the operation doesn't complete
/// within `seconds`, the child task is cancelled and `TimeoutError` is thrown.
func withThrowingTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError(seconds: seconds)
        }
        // First to complete wins — the other is cancelled.
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
