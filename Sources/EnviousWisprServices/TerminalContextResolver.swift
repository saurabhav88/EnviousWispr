import ApplicationServices
import Darwin
import EnviousWisprCore
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
  private let now: @Sendable () -> Double

  /// What each bounded step actually cost, for the log line.
  ///
  /// The budget was previously unobservable: it charged itself, tripped the
  /// breaker on exhaustion, and recorded nothing about WHICH step spent the
  /// time or how much. When the breaker fired in the field on 2026-08-04 there
  /// was no way to answer "why did a read that measures ~1 ms take over 100?"
  /// from the logs, and three separate hypotheses had to be tested by hand
  /// against a live machine, all three wrong.
  ///
  /// Metadata only — a label and a duration. Never screen text, a path, or the
  /// derived line, which is the same boundary `TerminalContextRefusal` keeps.
  private let trace = OSAllocatedUnfairLock(
    initialState: [(label: String, seconds: Double, isMark: Bool)]())

  /// `now` reads a monotonic clock in seconds. It exists so `step` can be
  /// tested against a clock the test drives, matching how the resolver already
  /// takes `Dependencies.now` — an assertion about cumulative charging must not
  /// depend on wall time, because a busy-wait guarantees a floor and never a
  /// ceiling (#1893).
  package init(
    total: Double = defaultTotal,
    now: @escaping @Sendable () -> Double = {
      Double(DispatchTime.now().uptimeNanoseconds) / 1e9
    }
  ) {
    self.total = total
    self.now = now
  }

  package var remaining: Double {
    spent.withLock { max(0, total - $0) }
  }

  package var isExhausted: Bool { remaining <= 0 }

  /// Charge the time a step made the caller wait.
  ///
  /// Charging and RECORDING are one call, so a cost cannot reach the budget
  /// without also reaching the trace unless a caller says so explicitly. Cloud
  /// review found exactly that gap: the process scan was charged and recorded
  /// nowhere, so a scan that ate 90 ms printed `total=1.0ms` — the line would
  /// have been at its most misleading in the one case it exists to explain. A
  /// log line carries the same evidence burden as a comment.
  ///
  /// Pass `nil` ONLY where the cost is already recorded by `step`, which is the
  /// screen read: charging it a second time from the caller would double-count
  /// it and halve the effective budget.
  package func charge(_ seconds: Double, label: String?) {
    spent.withLock { $0 += max(0, seconds) }
    guard let label else { return }
    trace.withLock { $0.append((label, max(0, seconds), false)) }
  }

  /// Run one bounded step: apply the remaining budget as the accessibility
  /// messaging timeout, run the call, then charge what it actually took.
  ///
  /// This is what makes the cap CUMULATIVE rather than per-call (founder,
  /// 2026-07-28: "it has to be a 100 ms cap for all the questions"). An earlier
  /// version applied the same bound to each of the five reads, so five could
  /// take five times the cap between them.
  ///
  /// Measured live the same day, which is why this is a FAILURE bound and not a
  /// latency target: all five reads together cost mean 0.78 ms in Ghostty and
  /// 1.79 ms in iTerm2, with the only spikes (19-35 ms) on a cold first call.
  /// The cap is roughly fifty times the typical cost and three times the worst
  /// observed — it exists to bound a wedge, and never bites healthy work.
  /// - Parameter label: names this step in the timing trace. Required rather
  ///   than defaulted, so a new bounded step cannot silently appear in the log
  ///   as an anonymous cost.
  package func step<T>(applying element: AXUIElement, label: String, _ body: () -> T) -> T {
    let application = AXUIElementCreateApplication(processIdentifier(of: element))
    AXUIElementSetMessagingTimeout(application, Float(max(0.005, remaining)))
    let started = now()
    defer {
      // ONE call. `charge` both charges and records, so the separate
      // `trace.append` this used to make alongside it would enter every step
      // twice and double the printed total.
      //
      // Two separate locks inside `charge`, never nested: recording is a plain
      // array append under an uncontended lock with no suspension point, so it
      // cannot widen the window it measures.
      charge(now() - started, label: label)
    }
    return body()
  }

  /// Note a PHASE boundary in the trace. Costs nothing and charges nothing.
  ///
  /// The commit-boundary re-check calls the same read path as the initial
  /// resolution, so its steps carry the same labels and land in the same trace.
  /// Without a separator the line reads as one long run of duplicated names and
  /// the reader cannot tell which phase spent the budget — which matters here
  /// precisely because the re-check runs AFTER the target app is activated and
  /// is the half we could not previously see.
  package func mark(_ label: String) {
    trace.withLock { $0.append((label, 0, true)) }
  }

  /// The per-step costs, for one log line. Empty when no step ran.
  ///
  /// Reads as `focused=0.4ms screen=0.2ms |recheck| focused=97.1ms total=97.7ms`,
  /// which is what makes a trip diagnosable: the total says the cap was hit, the
  /// labels say which call ate it, and the marker says in which phase.
  package var timingDescription: String {
    let samples = trace.withLock { $0 }
    guard samples.contains(where: { !$0.isMark }) else { return "" }
    let parts = samples.map {
      $0.isMark ? "|\($0.label)|" : "\($0.label)=\(String(format: "%.1f", $0.seconds * 1000))ms"
    }
    let total = samples.reduce(0.0) { $0 + $1.seconds }
    return parts.joined(separator: " ") + " total=\(String(format: "%.1f", total * 1000))ms"
  }

  private func processIdentifier(of element: AXUIElement) -> pid_t {
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    return pid
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
  /// - Parameter label: names this cost in the timing trace, or `nil` when the
  ///   cost was already recorded by `budget.step` and charging it again here
  ///   would double-count it.
  static func overspent(
    by elapsed: Double,
    label: String?,
    budget: TerminalResolutionBudget,
    breaker: TerminalCircuitBreaker,
    pid: pid_t
  ) -> Bool {
    budget.charge(elapsed, label: label)
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
    //
    // Timed from out here because the process sweep is NOT an accessibility
    // call, so nothing else charges it. Measured mean 3 ms / p95 7 ms.
    let scanStart = dependencies.now()
    let scan = dependencies.scanProcesses()
    if overspent(
      by: dependencies.now() - scanStart, label: "scan", budget: budget, breaker: breaker,
      pid: targetPID)
    {
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
    //
    // Charged with ZERO here: the read is an accessibility call and already
    // charged itself through `budget.step`, which is what makes the cap
    // cumulative. Timing it again from out here would double-count it and
    // halve the effective budget.
    let tail = dependencies.readScreenTail()
    // `nil` label and zero cost: `budget.step` already recorded the read under
    // `screen`. This call exists only to re-test exhaustion after it.
    if overspent(by: 0, label: nil, budget: budget, breaker: breaker, pid: targetPID) {
      // The evidence may well be complete, and it is discarded anyway. A result
      // that arrived after the deadline is a result the user already waited too
      // long for, and accepting it would make the promised bound meaningless.
      return .refused(.deadline)
    }

    guard let tail else { return .refused(.screenUnreadable) }
    let located: TerminalScreenParser.Located
    switch TerminalScreenParser.locateDetailed(inScreenTail: tail) {
    case .located(let found):
      located = found
    case .refused(let detail):
      // WHICH guard refused. `screenRefused` is one telemetry value covering ten
      // structurally different outcomes, and that collapse is why a live field
      // failure could not be diagnosed on 2026-08-04.
      //
      // Logged rather than threaded into `TerminalContextRefusal`, because that
      // enum's raw values are a shipped closed set read by telemetry, and
      // widening it to carry a parser detail would change what those values
      // mean. Closed-set names only; nothing here can carry screen content.
      Task {
        await AppLogger.shared.log(
          "TERMINAL_PARSE refused codex=\(detail.codex.rawValue) "
            + "boxed=\(detail.boxed.telemetryName)",
          level: .info, category: "TerminalContextResolver")
      }
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
