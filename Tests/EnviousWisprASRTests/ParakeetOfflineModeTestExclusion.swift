@preconcurrency import FluidAudio

/// Cross-suite exclusion for FluidAudio's process-wide offline-mode switch.
///
/// `.serialized` orders tests only inside one suite. Both the delivery-mode
/// contract and the real-model receipt change this global, so they share this
/// fair FIFO guard and return the switch exactly as they found it.
private actor ParakeetOfflineModeTestExclusion {
  static let shared = ParakeetOfflineModeTestExclusion()

  private var held = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func acquire() async {
    if !held {
      held = true
      return
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      waiters.append(continuation)
    }
  }

  func release() {
    if waiters.isEmpty {
      held = false
    } else {
      waiters.removeFirst().resume()
    }
  }
}

func withParakeetOfflineModeExclusion<T>(
  isolation: isolated (any Actor)? = #isolation,
  _ body: () async throws -> T
) async rethrows -> T {
  await ParakeetOfflineModeTestExclusion.shared.acquire()
  let originalOfflineMode = ModelHub.offlineMode

  @Sendable func restoreAndRelease() async {
    ModelHub.offlineMode = originalOfflineMode
    await ParakeetOfflineModeTestExclusion.shared.release()
  }

  do {
    let value = try await body()
    await restoreAndRelease()
    return value
  } catch {
    await restoreAndRelease()
    throw error
  }
}
