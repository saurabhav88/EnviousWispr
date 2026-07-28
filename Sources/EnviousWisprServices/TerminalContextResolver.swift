import Darwin
import Foundation
import os

// MARK: - Evidence

/// Everything the three gates agreed on, as ONE opaque token.
///
/// No caller may validate it in parts. At every route's last boundary before a
/// write the gates re-run and the COMPLETE token must match — the raw screen
/// tail included, because a screen-derived context has no selection offsets to
/// compare and the tail is the only identity it has.
package struct TerminalEvidence: Equatable, Sendable {
  package let surface: TerminalSurface
  /// The supported CLIs that satisfied the veto, sorted so that equality does
  /// not depend on the order the kernel happened to enumerate processes in.
  package let runningCLIs: [RunningTerminalCLI]
  /// The raw screen tail the input line was derived from.
  package let screenTail: String
  package let located: TerminalScreenParser.Located

  package init(
    surface: TerminalSurface, runningCLIs: [RunningTerminalCLI], screenTail: String,
    located: TerminalScreenParser.Located
  ) {
    self.surface = surface
    self.runningCLIs = runningCLIs.sorted { $0.processIdentifier < $1.processIdentifier }
    self.screenTail = screenTail
    self.located = located
  }
}

/// Why a terminal read was refused. Recorded as telemetry; metadata only, never
/// a path, a window title, screen text or the derived line.
package enum TerminalContextRefusal: String, Equatable, Sendable {
  case surfaceIneligible = "terminal_surface_refused"
  case noSupportedCLI = "terminal_no_supported_cli"
  case processScanUnavailable = "terminal_process_scan_unavailable"
  case screenUnreadable = "terminal_screen_unreadable"
  case screenRefused = "terminal_screen_refused"
  case deadline = "terminal_deadline"
  case breakerOpen = "terminal_breaker_open"
  case staleAtCommit = "terminal_stale_at_commit"
}

package enum TerminalContextResult: Equatable, Sendable {
  case resolved(TerminalEvidence)
  case refused(TerminalContextRefusal)

  package var evidence: TerminalEvidence? {
    if case .resolved(let evidence) = self { return evidence }
    return nil
  }
}

// MARK: - Budget

/// ONE cumulative time budget per delivery, shared by the initial resolution and
/// every later commit revalidation.
///
/// The accessibility messaging timeout is 0.5 s PER CALL, and a full resolution
/// plus revalidation is several calls — up to seconds before raw text reaches
/// the user, on the heart path. A per-CALL limit would not bound that; only a
/// cumulative one does. No call, route, retry or revalidation resets it.
package final class TerminalResolutionBudget: Sendable {
  package static let defaultTotal: Double = 0.100

  private let total: Double
  private let spent = OSAllocatedUnfairLock(initialState: 0.0)

  package init(total: Double = defaultTotal) {
    self.total = total
  }

  package var remaining: Double {
    spent.withLock { max(0, total - $0) }
  }

  package var isExhausted: Bool { remaining <= 0 }

  /// Charge the time a step made the caller wait.
  package func charge(_ seconds: Double) {
    spent.withLock { $0 += max(0, seconds) }
  }
}

// MARK: - Circuit breaker

/// Latches a wedged terminal off for the rest of the process's life.
///
/// Without this, repeated dictations against one wedged terminal each start
/// another blocked read: `withDeadline` resumes the caller at the deadline but
/// CANNOT preempt a blocked thread, so the abandoned reads accumulate. Precedent
/// is the oracle deadline, which already latches its failing dependency off.
///
/// Keyed by PID **and process start time**, so a relaunched terminal starts
/// closed and PID REUSE cannot inherit a latch.
///
/// Cloud review found the gap: the latch lasts the whole process lifetime and
/// nothing ever cleared it, so once macOS recycled that PID an unrelated
/// terminal would be refused forever with no way back. Identity, not a number.
package final class TerminalCircuitBreaker: Sendable {
  package static let shared = TerminalCircuitBreaker()

  /// A process, not merely a PID.
  struct Key: Hashable {
    let pid: pid_t
    /// Nil when the start time is unreadable — which cannot be conflated with a
    /// known one, so an unreadable process gets its own distinct key.
    let startedAt: UInt64?
  }

  private let open = OSAllocatedUnfairLock(initialState: Set<Key>())

  package init() {}

  private func key(_ pid: pid_t) -> Key {
    Key(pid: pid, startedAt: TerminalProcessScanner.startTime(of: pid))
  }

  package func isOpen(for pid: pid_t) -> Bool {
    let key = key(pid)
    return open.withLock { $0.contains(key) }
  }

  package func trip(for pid: pid_t) {
    let key = key(pid)
    open.withLock { _ = $0.insert(key) }
  }

  package func resetAll() {
    open.withLock { $0.removeAll() }
  }
}

// MARK: - Resolver

/// The single owner of the complete terminal decision: surface eligibility, the
/// running-CLI veto, screen-line location, and commit revalidation.
///
/// The alternative — several private helpers on `PasteService` — would make the
/// central paste type the owner of both delivery AND terminal-session discovery,
/// which is two concerns.
package enum TerminalContextResolver {

  /// Everything the resolver touches from the outside world, injected so the
  /// decision logic is testable without a terminal, a process table or an
  /// accessibility connection.
  /// Deliberately NOT `Sendable`: resolution is synchronous and single-threaded
  /// per delivery, and the accessibility element these closures read is not
  /// Sendable either. Marking them `@Sendable` would force the caller to smuggle
  /// a foreign app's accessibility handle across an isolation boundary, which is
  /// the opposite of what this type is for.
  package struct Dependencies {
    /// Bundle identifier of the app being pasted into.
    package let bundleIdentifier: () -> String?
    /// Every readable process, or `.unavailable`.
    package let scanProcesses: () -> TerminalProcessScan
    /// The bounded tail of the focused tab's rendered screen, or nil.
    package let readScreenTail: () -> String?
    /// Seconds elapsed, for charging the budget.
    package let now: () -> Double

    package init(
      bundleIdentifier: @escaping () -> String?,
      scanProcesses: @escaping () -> TerminalProcessScan,
      readScreenTail: @escaping () -> String?,
      now: @escaping () -> Double = { Date().timeIntervalSinceReferenceDate }
    ) {
      self.bundleIdentifier = bundleIdentifier
      self.scanProcesses = scanProcesses
      self.readScreenTail = readScreenTail
      self.now = now
    }
  }

  /// Charge a step, and decide whether the budget is now spent.
  ///
  /// Tripping the breaker HERE is what arms it. Whole-diff review found that
  /// nothing in production ever called `trip`, so the breaker was tested,
  /// documented, and inert — a wedged terminal would have repeated its delay on
  /// every single dictation forever. Tests that only trip it by hand cannot
  /// catch that; this is the one place the product itself does.
  static func overspent(
    by elapsed: Double,
    budget: TerminalResolutionBudget,
    breaker: TerminalCircuitBreaker,
    pid: pid_t
  ) -> Bool {
    budget.charge(elapsed)
    guard budget.isExhausted else { return false }
    breaker.trip(for: pid)
    return true
  }

  /// Run all three gates.
  ///
  /// Order is deliberate and is a cost decision as much as a safety one: the
  /// cheapest, most decisive gate runs first, so an ineligible app never reaches
  /// a process scan and a terminal with nothing running never reaches a screen
  /// read.
  package static func resolve(
    targetPID: pid_t,
    budget: TerminalResolutionBudget,
    breaker: TerminalCircuitBreaker = .shared,
    dependencies: Dependencies
  ) -> TerminalContextResult {
    if breaker.isOpen(for: targetPID) { return .refused(.breakerOpen) }
    if budget.isExhausted { return .refused(.deadline) }

    // Gate 0 — terminal surface. Cheapest, and it licenses everything after it.
    guard
      let identifier = dependencies.bundleIdentifier(),
      let surface = TerminalSurface(bundleIdentifier: identifier)
    else { return .refused(.surfaceIneligible) }

    // Gate 1 — the veto. An unreadable process list is NOT "nothing is
    // running": both refuse, but they are different facts, and the typed scan
    // result is what keeps them apart.
    let scanStart = dependencies.now()
    let scan = dependencies.scanProcesses()
    if overspent(by: dependencies.now() - scanStart, budget: budget, breaker: breaker, pid: targetPID) {
      return .refused(.deadline)
    }

    let running: [RunningTerminalCLI]
    switch scan {
    case .unavailable:
      return .refused(.processScanUnavailable)
    case .available(let snapshots):
      running = TerminalProcessScanner.supportedCLIs(in: snapshots, hostedBy: surface)
    }
    guard !running.isEmpty else { return .refused(.noSupportedCLI) }

    // Gate 2 — WHERE the line is. Never whether.
    let readStart = dependencies.now()
    let tail = dependencies.readScreenTail()
    if overspent(by: dependencies.now() - readStart, budget: budget, breaker: breaker, pid: targetPID) {
      // The evidence may well be complete, and it is discarded anyway. A result
      // that arrived after the deadline is a result the user already waited too
      // long for, and accepting it would make the promised bound meaningless.
      return .refused(.deadline)
    }

    guard let tail else { return .refused(.screenUnreadable) }
    guard let located = TerminalScreenParser.locate(inScreenTail: tail) else {
      return .refused(.screenRefused)
    }

    return .resolved(
      TerminalEvidence(
        surface: surface, runningCLIs: running, screenTail: tail, located: located))
  }

  /// Re-run every gate at a write boundary and require the COMPLETE token to
  /// match.
  ///
  /// Process exit, focus change, a scroll, an edit, or any value becoming
  /// unreadable all select today's payload. Partial validation is not offered:
  /// the token is opaque by design, because a caller checking only the derived
  /// line would miss the buffer moving underneath it.
  package static func revalidate(
    _ captured: TerminalEvidence,
    targetPID: pid_t,
    budget: TerminalResolutionBudget,
    breaker: TerminalCircuitBreaker = .shared,
    dependencies: Dependencies
  ) -> TerminalContextResult {
    let fresh = resolve(
      targetPID: targetPID, budget: budget, breaker: breaker, dependencies: dependencies)
    guard let evidence = fresh.evidence else {
      // Carry the specific refusal through rather than flattening it: a
      // deadline at commit and a changed screen are different facts.
      return fresh
    }
    guard evidence == captured else { return .refused(.staleAtCommit) }
    return .resolved(evidence)
  }
}
