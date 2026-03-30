import Foundation

/// True async mutex for serializing all operations on the non-actor AsrManager.
///
/// An actor wrapper does NOT work here: actor methods are reentrant across `await`
/// suspension points. If `configureVocabularyBoosting` suspends, the actor can accept
/// another call to `transcribe`, causing interleaving on the non-thread-safe AsrManager.
///
/// This mutex uses a serial DispatchQueue to guarantee that only one async operation
/// runs at a time, even across suspension points.
final class AsrManagerMutex: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.enviouswispr.asr-manager-mutex")

    /// Execute an async operation with exclusive access.
    /// Only one operation runs at a time, even if the operation contains `await` points.
    func run<T: Sendable>(_ op: @Sendable @escaping () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let semaphore = DispatchSemaphore(value: 0)
                nonisolated(unsafe) var result: Result<T, any Error>!
                Task {
                    do {
                        result = .success(try await op())
                    } catch {
                        result = .failure(error)
                    }
                    semaphore.signal()
                }
                semaphore.wait()
                continuation.resume(with: result)
            }
        }
    }

    /// Non-throwing variant for operations that cannot fail.
    func run<T: Sendable>(_ op: @Sendable @escaping () async -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                let semaphore = DispatchSemaphore(value: 0)
                nonisolated(unsafe) var value: T!
                Task {
                    value = await op()
                    semaphore.signal()
                }
                semaphore.wait()
                continuation.resume(returning: value)
            }
        }
    }
}
