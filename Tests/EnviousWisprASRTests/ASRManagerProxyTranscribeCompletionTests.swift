import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprASR

/// #1755 §3.4 prerequisite — the pending batch-transcribe completion contract.
///
/// Same production defect class as #1388's load contract: a helper death
/// mid-decode left `transcribe(audioSamples:)`'s continuation suspended
/// forever, because the per-call XPC error handler is not guaranteed to fire
/// for a pending reply and the death handlers could reach only
/// `pendingLoadCompletion`. These tests pin the registry lifecycle — register
/// → (reply | proxy error | current-era death) → exactly one resume →
/// exact-key removal — through `awaitTranscribeReply`, the SINGLE
/// implementation production's `transcribe(audioSamples:)` runs, so the tests
/// exercise production's real registration/cleanup, not a copy. Death-handler
/// waits use the factories' explicit `didFinishForTesting` completion signal
/// (no clocks, no scheduling assumptions). The full integration (kill the
/// real helper during a real decode) is runtime-only and lives in the #1755
/// Live UAT Fork-2 legs.
@MainActor
@Suite("ASRManagerProxy — #1755 transcribe completion contract")
struct ASRManagerProxyTranscribeCompletionTests {

  private static func makeProxy() -> ASRManagerProxy {
    ASRManagerProxy(engineMutationScope: .alwaysAllowedForTesting, connectionPreflight: { _ in })
  }

  /// A dummy connection used ONLY as an era-identity token; never resumed.
  private static func dummyConnection() -> NSXPCConnection {
    NSXPCConnection(serviceName: "com.enviouswispr.test.nonexistent")
  }

  /// Starts a REAL pending reply through the production helper: the returned
  /// task is suspended inside `awaitTranscribeReply`, and this function
  /// returns only after the registration is VISIBLE on the proxy (the helper
  /// hands its guard to `start` synchronously after registering — that
  /// hand-off is the signal).
  private static func startPendingReply(
    on proxy: ASRManagerProxy
  ) async -> (
    task: Task<Result<(Data?, NSError?), any Error>, Never>,
    guard_: OneShotContinuationASR<(Data?, NSError?)>
  ) {
    var handed: CheckedContinuation<OneShotContinuationASR<(Data?, NSError?)>, Never>?
    let task = Task { @MainActor in
      do {
        let value = try await proxy.awaitTranscribeReply { completion in
          handed?.resume(returning: completion)
        }
        return Result<(Data?, NSError?), any Error>.success(value)
      } catch {
        return Result<(Data?, NSError?), any Error>.failure(error)
      }
    }
    // MainActor FIFO: the spawned task cannot run until this body suspends
    // below, and the suspension body installs `handed` first.
    let guard_ = await withCheckedContinuation {
      (c: CheckedContinuation<OneShotContinuationASR<(Data?, NSError?)>, Never>) in
      handed = c
    }
    return (task, guard_)
  }

  /// Fires a death handler built with the explicit completion signal and
  /// suspends until its `@MainActor` task has fully finished.
  private static func fireAndAwait(
    _ make: (ASRManagerProxy, NSXPCConnection, (@MainActor @Sendable () -> Void)?)
      -> @Sendable () -> Void,
    proxy: ASRManagerProxy, connection: NSXPCConnection
  ) async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
      nonisolated(unsafe) let doneBox = done
      make(proxy, connection) { doneBox.resume() }()
    }
  }

  // MARK: - Registration lifecycle through the production helper

  @Test("normal reply completes exactly once and clears its registration")
  func normalReplyClearsRegistration() async throws {
    let proxy = Self.makeProxy()
    let expected = Data([1, 2, 3])
    let result = try await proxy.awaitTranscribeReply { completion in
      completion.resume(returning: (expected, nil))
    }
    #expect(result.0 == expected)
    #expect(result.1 == nil)
    #expect(proxy.pendingTranscribeCountForTesting == 0)
  }

  @Test("per-call proxy error completes exactly once and clears its registration")
  func proxyErrorExitClearsRegistration() async {
    // No-op preflight → nil connection → the real `serviceProxy` nil branch
    // fires `onProxyError` → serviceUnreachable, through the REAL
    // `transcribe(audioSamples:)` entry point.
    let proxy = Self.makeProxy()
    do {
      _ = try await proxy.transcribe(audioSamples: [0.1, 0.2], options: TranscriptionOptions())
      Issue.record("transcribe must throw with no connection")
    } catch {
      #expect(error as? XPCASRTransportError == .serviceUnreachable)
    }
    #expect(proxy.pendingTranscribeCountForTesting == 0)
  }

  @Test("exact-key removal spares a concurrent pending operation")
  func exactKeyRemovalSparesBystander() async throws {
    let proxy = Self.makeProxy()
    let bystander = await Self.startPendingReply(on: proxy)
    #expect(proxy.pendingTranscribeCountForTesting == 1)
    // A second operation completes normally; only ITS key is removed.
    _ = try await proxy.awaitTranscribeReply { completion in
      completion.resume(returning: (nil, nil))
    }
    #expect(proxy.pendingTranscribeCountForTesting == 1, "bystander registration must survive")
    bystander.guard_.resume(throwing: XPCASRTransportError.serviceUnreachable)
    let outcome = await bystander.task.value
    guard case .failure(let error) = outcome else {
      Issue.record("bystander should conclude with the thrown error")
      return
    }
    #expect(error as? XPCASRTransportError == .serviceUnreachable)
    #expect(proxy.pendingTranscribeCountForTesting == 0)
  }

  // MARK: - Current-era death drains

  @Test("current-era interruption fails ALL registered transcriptions with serviceUnreachable")
  func interruptionDrainsAllPending() async {
    let proxy = Self.makeProxy()
    let a = await Self.startPendingReply(on: proxy)
    let b = await Self.startPendingReply(on: proxy)
    let c = await Self.startPendingReply(on: proxy)
    #expect(proxy.pendingTranscribeCountForTesting == 3)
    // proxy.connection is nil → currentEraID == nil → the guard admits the
    // handler (the "cleared with no successor" era case).
    await Self.fireAndAwait(
      {
        ASRManagerProxy.makeInterruptionHandler(proxy: $0, connection: $1, didFinishForTesting: $2)
      },
      proxy: proxy, connection: Self.dummyConnection())
    for pending in [a, b, c] {
      let outcome = await pending.task.value
      guard case .failure(let error) = outcome else {
        Issue.record("expected serviceUnreachable, got a value")
        continue
      }
      #expect(error as? XPCASRTransportError == .serviceUnreachable)
    }
    #expect(proxy.pendingTranscribeCountForTesting == 0)
  }

  @Test("current-era invalidation fails ALL registered transcriptions with serviceUnreachable")
  func invalidationDrainsAllPending() async {
    let proxy = Self.makeProxy()
    let a = await Self.startPendingReply(on: proxy)
    let b = await Self.startPendingReply(on: proxy)
    #expect(proxy.pendingTranscribeCountForTesting == 2)
    await Self.fireAndAwait(
      {
        ASRManagerProxy.makeInvalidationHandler(proxy: $0, connection: $1, didFinishForTesting: $2)
      },
      proxy: proxy, connection: Self.dummyConnection())
    for pending in [a, b] {
      let outcome = await pending.task.value
      guard case .failure(let error) = outcome else {
        Issue.record("expected serviceUnreachable, got a value")
        continue
      }
      #expect(error as? XPCASRTransportError == .serviceUnreachable)
    }
    #expect(proxy.pendingTranscribeCountForTesting == 0)
  }

  // MARK: - Late replies after a death resume

  @Test("late reply after interruption drain is dropped by the one-shot guard")
  func lateReplyAfterInterruptionIgnored() async {
    let proxy = Self.makeProxy()
    let pending = await Self.startPendingReply(on: proxy)
    await Self.fireAndAwait(
      {
        ASRManagerProxy.makeInterruptionHandler(proxy: $0, connection: $1, didFinishForTesting: $2)
      },
      proxy: proxy, connection: Self.dummyConnection())
    let outcome = await pending.task.value
    // The helper's reply arrives late; the one-shot guard must drop it.
    pending.guard_.resume(returning: (Data(), nil))
    guard case .failure(let error) = outcome else {
      Issue.record("the death cause must win; the late reply must be dropped")
      return
    }
    #expect(error as? XPCASRTransportError == .serviceUnreachable)
    #expect(proxy.pendingTranscribeCountForTesting == 0)
  }

  @Test("late error after invalidation drain is dropped by the one-shot guard")
  func lateReplyAfterInvalidationIgnored() async {
    let proxy = Self.makeProxy()
    let pending = await Self.startPendingReply(on: proxy)
    await Self.fireAndAwait(
      {
        ASRManagerProxy.makeInvalidationHandler(proxy: $0, connection: $1, didFinishForTesting: $2)
      },
      proxy: proxy, connection: Self.dummyConnection())
    let outcome = await pending.task.value
    pending.guard_.resume(throwing: CancellationError())
    guard case .failure(let error) = outcome else {
      Issue.record("the death cause must win; the late error must be dropped")
      return
    }
    #expect(error as? XPCASRTransportError == .serviceUnreachable)
    #expect(proxy.pendingTranscribeCountForTesting == 0)
  }

  // MARK: - Era guard: retired handlers cannot touch a successor

  @Test("a retired connection's interruption handler does not drain successor operations")
  func retiredInterruptionCannotDrainSuccessor() async {
    let proxy = Self.makeProxy()
    let retired = Self.dummyConnection()
    let successor = Self.dummyConnection()
    proxy.setConnectionForTesting(successor)
    defer { proxy.setConnectionForTesting(nil) }
    let survivor = await Self.startPendingReply(on: proxy)
    // Fire the RETIRED era's handler and wait for its task to fully finish;
    // the era guard must reject the whole body.
    await Self.fireAndAwait(
      {
        ASRManagerProxy.makeInterruptionHandler(proxy: $0, connection: $1, didFinishForTesting: $2)
      },
      proxy: proxy, connection: retired)
    #expect(proxy.pendingTranscribeCountForTesting == 1, "successor operation must survive")
    // Now the CURRENT era dies: the successor's own handler drains it.
    await Self.fireAndAwait(
      {
        ASRManagerProxy.makeInvalidationHandler(proxy: $0, connection: $1, didFinishForTesting: $2)
      },
      proxy: proxy, connection: successor)
    let outcome = await survivor.task.value
    guard case .failure(let error) = outcome else {
      Issue.record("expected serviceUnreachable after the current era died")
      return
    }
    #expect(error as? XPCASRTransportError == .serviceUnreachable)
    #expect(proxy.pendingTranscribeCountForTesting == 0)
  }

  @Test("a retired connection's invalidation handler does not drain successor operations")
  func retiredInvalidationCannotDrainSuccessor() async {
    let proxy = Self.makeProxy()
    let retired = Self.dummyConnection()
    let successor = Self.dummyConnection()
    proxy.setConnectionForTesting(successor)
    defer { proxy.setConnectionForTesting(nil) }
    let survivor = await Self.startPendingReply(on: proxy)
    await Self.fireAndAwait(
      {
        ASRManagerProxy.makeInvalidationHandler(proxy: $0, connection: $1, didFinishForTesting: $2)
      },
      proxy: proxy, connection: retired)
    #expect(proxy.pendingTranscribeCountForTesting == 1, "successor operation must survive")
    await Self.fireAndAwait(
      {
        ASRManagerProxy.makeInterruptionHandler(proxy: $0, connection: $1, didFinishForTesting: $2)
      },
      proxy: proxy, connection: successor)
    let outcome = await survivor.task.value
    guard case .failure(let error) = outcome else {
      Issue.record("expected serviceUnreachable after the current era died")
      return
    }
    #expect(error as? XPCASRTransportError == .serviceUnreachable)
    #expect(proxy.pendingTranscribeCountForTesting == 0)
  }

  // MARK: - Load contract untouched

  @Test("a death drain leaves the pending-load contract state untouched when no load is pending")
  func drainWithNoPendingLoadIsSafe() async {
    let proxy = Self.makeProxy()
    let pending = await Self.startPendingReply(on: proxy)
    #expect(proxy.hasPendingLoadCompletionForTesting == false)
    await Self.fireAndAwait(
      {
        ASRManagerProxy.makeInterruptionHandler(proxy: $0, connection: $1, didFinishForTesting: $2)
      },
      proxy: proxy, connection: Self.dummyConnection())
    _ = await pending.task.value
    #expect(proxy.hasPendingLoadCompletionForTesting == false)
    #expect(proxy.pendingTranscribeCountForTesting == 0)
  }
}
