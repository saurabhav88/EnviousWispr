import EnviousWisprCore
import EnviousWisprStorage
import Foundation
import Observation

/// Manages transcript history state, search, and persistence.
@MainActor @Observable
final class TranscriptCoordinator {
  /// The unfiltered store, PRIVATE (#2087).
  ///
  /// Read-time expiry only works if consumers honour it, and every consumer
  /// reading this array directly bypassed it silently — the code compiled, the
  /// list rendered, and the only symptom was a held recovery still reachable
  /// past the 24 hours the user was promised. Three sites did exactly that.
  ///
  /// Guarding it was tried and is not enough: a scanner over the source can
  /// match a name, not a type, so it flags an unrelated `transcripts` elsewhere
  /// and misses a bare access from an extension. The compiler makes the mistake
  /// unavailable instead. Read `visibleTranscripts` or `filteredTranscripts`.
  private var transcripts: [Transcript] = []
  var searchQuery: String = ""
  var selectedTranscriptID: UUID?

  /// Re-render pulse for pending Escape Recovery rows (#2087).
  ///
  /// This type has no clock, and Observation redraws on a STATE change — a
  /// remaining-time computed from `Date()` is not one. Without a pulse a row
  /// would keep showing whatever it said when something else last mutated
  /// state, and an expired row would stay on screen until an unrelated edit
  /// happened to refresh it. Reading this in a view is what subscribes it.
  ///
  /// Only runs while a live pending row exists, so the ordinary case — feature
  /// off, or no recovery held — has no timer at all.
  private(set) var expiryPulse: Int = 0

  private let store: TranscriptStore
  private let pendingPulseInterval: Duration
  private let pendingPulseSleep: @Sendable (Duration) async -> Void
  private var loadTask: Task<Void, Never>?
  private var pulseTask: Task<Void, Never>?

  /// Rows that are still OFFERED, at read time (#2087).
  ///
  /// Read-time expiry is authoritative: a pending row at or past its retention
  /// window is never rendered, searched or counted, whether or not the sweep
  /// that deletes its file has run. The sweep reclaims disk; this decides
  /// visibility. Tying visibility to the sweep would leave an expired row on
  /// screen whenever the sweep failed, threw, or had not run yet.
  var visibleTranscripts: [Transcript] {
    // Reading the pulse HERE is what makes the redraw work, and it is load
    // bearing rather than decorative. Observation invalidates a view when a
    // property the view READ changes; this result depends on `Date()`, which
    // Observation cannot see. Touching `expiryPulse` during the read makes
    // every consumer of this list a subscriber to the pulse automatically,
    // instead of relying on each view to remember to read a counter whose
    // relevance is not obvious from its name.
    _ = expiryPulse
    let now = Date()
    return transcripts.filter { Self.isVisible($0, at: now) }
  }

  var filteredTranscripts: [Transcript] {
    let visible = visibleTranscripts
    guard !searchQuery.isEmpty else { return visible }
    // Pending rows are excluded from search DELIBERATELY: an accidental Escape
    // would otherwise pollute results for 24 hours, and the row is reachable
    // the whole time by scrolling History, which is where the user left it.
    return visible.filter {
      $0.escapeRecoveredAt == nil && $0.displayText.localizedCaseInsensitiveContains(searchQuery)
    }
  }

  /// Completed dictations. A held recovery is an OFFER, not a dictation the
  /// user made — counting it would inflate the stat the moment they cancelled
  /// something, which is the opposite of what cancelling meant.
  var transcriptCount: Int {
    _ = expiryPulse
    let now = Date()
    return transcripts.filter { Self.isVisible($0, at: now) && $0.escapeRecoveredAt == nil }.count
  }

  /// How many rows a Delete All would actually take, from the user's point of
  /// view (#2087).
  ///
  /// Deliberately NOT `transcriptCount`. That one answers "how many dictations
  /// have I made" and excludes held recoveries, which is right for a statistic
  /// and wrong for a destructive confirmation: with only held rows on screen it
  /// reads zero, so the dialog would offer to delete "all 0 transcripts" and
  /// then delete them. A confirmation must count what it is about to destroy.
  var deletableCount: Int { visibleTranscripts.count }

  /// The Delete All confirmation, assembled HERE rather than in the view.
  ///
  /// Not a style preference. While the view interpolated a count of its own
  /// choosing, the correct count and the wrong one were both in scope and
  /// equally easy to type, and nothing a unit test can reach observed which was
  /// picked — a mutation swapping them survived the whole suite. Owning the
  /// sentence removes the choice from the call site and puts the decision
  /// somewhere a test can see it.
  var deleteAllConfirmationMessage: String {
    let count = deletableCount
    // "all 1 transcripts" is what centralising the sentence without reading it
    // produced, and a test then pinned it. One row is not a plural, and "all"
    // reads as boilerplate when there is nothing to be exhaustive about.
    let subject = count == 1 ? "1 transcript" : "all \(count) transcripts"
    return "This will permanently delete \(subject). This action cannot be undone."
  }

  /// Live pending rows, for the pulse's own start/stop decision.
  private var livePendingCount: Int {
    let now = Date()
    return transcripts.filter { $0.escapeRecoveredAt != nil && Self.isVisible($0, at: now) }.count
  }

  /// A held row is visible only while `PendingAdmission` calls it live.
  /// Permanent rows carry no stamp and are always visible.
  ///
  /// Asked through the shared authority rather than re-derived, for the reason
  /// that type's own documentation gives: two copies of the retention
  /// comparison diverge the moment one side gains a condition the other lacks.
  /// An earlier version of this method compared elapsed time directly and so
  /// omitted future-skew rejection — a clock-skewed stamp would have stayed
  /// visible in History indefinitely while the store refused to return it,
  /// recreating precisely the divergence chunk 5 existed to remove.
  private static func isVisible(_ transcript: Transcript, at now: Date) -> Bool {
    guard let stamped = transcript.escapeRecoveredAt else { return true }
    return PendingAdmission.verdict(stampedAt: stamped, now: now) == .live
  }

  /// - Parameters:
  ///   - pendingPulseInterval: how often a held row's countdown and expiry are
  ///     re-evaluated. One minute: the countdown is rendered in hours, so a
  ///     minute bounds staleness three orders of magnitude below the window it
  ///     measures, while costing one wakeup a minute and only while a row is
  ///     actually being held.
  ///   - pendingPulseSleep: the wait between pulses. Injected rather than
  ///     hard-coded so a test drives the loop on a signal instead of a real
  ///     clock — a clock-based test of this would be flaky by construction and
  ///     would take a day to exercise the case that matters.
  init(
    store: TranscriptStore,
    pendingPulseInterval: Duration = .seconds(60),
    pendingPulseSleep: (@Sendable (Duration) async -> Void)? = nil
  ) {
    self.store = store
    self.pendingPulseInterval = pendingPulseInterval
    self.pendingPulseSleep = pendingPulseSleep ?? { try? await Task.sleep(for: $0) }
  }

  // No `deinit` teardown: `deinit` is nonisolated and cannot touch main-actor
  // state, and none is needed — the loop holds `self` weakly, so once this
  // object goes away the next wake finds nothing and returns. Nothing is
  // retained in the meantime.

  func load() {
    loadTask?.cancel()
    loadTask = Task {
      do {
        let diskRows = try await store.loadAll()
        // Phase C union-by-ID merge. Preserve any in-memory rows whose IDs
        // are not yet on disk (append-during-load race window) in their
        // existing order, then append disk rows. Protects the newest-first
        // invariant under multiple concurrent completions while a slow
        // startup load is still running.
        // #2087: pending rows are ADDITIVE and never authoritative. Keep writes
        // the permanent copy before deleting the pending file, so a crash
        // between those two steps leaves the same id in both namespaces — root
        // wins, and the user sees the row they kept exactly once rather than a
        // permanent row shadowed by a copy still counting down.
        let pendingRows = (try? await store.loadPending()) ?? []
        let rootIDs = Set(diskRows.map(\.id))
        let heldRows = pendingRows.filter { !rootIDs.contains($0.id) }
        let knownIDs = rootIDs.union(heldRows.map(\.id))
        let inFlightRows = transcripts.filter { !knownIDs.contains($0.id) }
        // Merged rather than re-sorted: both inputs are already newest-first,
        // and re-sorting the combined list could reorder permanent rows that
        // share a `createdAt`. With no held rows this returns `diskRows`
        // unchanged, which is what makes the chunk inert.
        transcripts = inFlightRows + Self.mergeNewestFirst(heldRows, diskRows)
        startPulseIfNeeded()
      } catch {
        await AppLogger.shared.log(
          "Failed to load transcripts: \(error)",
          level: .info, category: "TranscriptCoordinator"
        )
      }
    }
  }

  // periphery:ignore - test seam
  func waitForLoadForTesting() async {
    await loadTask?.value
  }

  /// Append a just-completed transcript to the in-memory cache.
  ///
  /// Precondition: the transcript has already been persisted by
  /// the finalization `save` closure. This method does no disk I/O. Caller
  /// must not invoke it twice for the same transcript — duplicate-ID
  /// protection would mask heart-path bugs.
  func append(_ transcript: Transcript) {
    transcripts.insert(transcript, at: 0)
    // A held row appended at runtime is the production route once the feature
    // is activated, and it arrives with a countdown already running. Without
    // this the pulse would only ever start at launch, so a recovery held during
    // a session would show a countdown frozen at the value it had when the row
    // appeared. No-op for an ordinary dictation, which carries no stamp.
    startPulseIfNeeded()
  }

  func delete(_ transcript: Transcript) {
    do {
      try store.delete(id: transcript.id)
      transcripts.removeAll { $0.id == transcript.id }
      if selectedTranscriptID == transcript.id {
        selectedTranscriptID = nil
      }
      stopPulseIfIdle()
    } catch {
      Task {
        await AppLogger.shared.log(
          "Failed to delete transcript: \(error)",
          level: .info, category: "TranscriptCoordinator"
        )
      }
    }
  }

  /// Text for a Copy or Paste started from History, or `nil` if the row is no
  /// longer being offered (#2087).
  ///
  /// A view holds the row it was RENDERED with, which is a snapshot. For an
  /// ordinary dictation that is harmless. For a held recovery it is not: the
  /// offer can lapse between the row appearing and the button being pressed, and
  /// pasting from the snapshot would hand back text the user was told had gone —
  /// the one thing the 24-hour promise says will not happen.
  ///
  /// Re-reads by id rather than trusting the caller's copy, so a row deleted in
  /// another pane is also refused. Inert, not merely harmless.
  func textForDelivery(_ transcript: Transcript) -> String? {
    guard transcript.escapeRecoveredAt != nil else { return transcript.displayText }
    let now = Date()
    guard
      let current = transcripts.first(where: { $0.id == transcript.id }),
      Self.isVisible(current, at: now)
    else { return nil }
    return current.displayText
  }

  /// Make a held recovery permanent (#2087).
  ///
  /// Inert, not merely harmless, when the row is no longer offerable: the store
  /// revalidates and silently ignores a row that expired between render and
  /// click, so a Keep press arriving a moment too late writes nothing rather
  /// than resurrecting text the user was told had gone.
  ///
  /// The in-memory row is replaced only after the store call returns, and it is
  /// replaced rather than mutated because `Transcript` is immutable. Idempotent:
  /// a second Keep finds no pending file and changes nothing.
  func keep(_ transcript: Transcript) {
    guard transcript.escapeRecoveredAt != nil else { return }
    do {
      // Only on a CONFIRMED promotion. The store silently ignores a row that
      // expired between render and click, and clearing the stamp anyway would
      // put an expired recovery on screen as permanent History — resurrecting
      // in the UI precisely the text the store just refused to write.
      guard try store.promotePending(id: transcript.id) else { return }
      guard let index = transcripts.firstIndex(where: { $0.id == transcript.id }) else { return }
      transcripts[index] = transcripts[index].promotedFromPending()
      stopPulseIfIdle()
    } catch {
      Task {
        await AppLogger.shared.log(
          "Failed to keep transcript: \(error)",
          level: .info, category: "TranscriptCoordinator"
        )
      }
    }
  }

  func deleteAll() {
    do {
      try store.deleteAll()
      transcripts.removeAll()
      selectedTranscriptID = nil
      stopPulseIfIdle()
    } catch {
      Task {
        await AppLogger.shared.log(
          "Failed to delete all transcripts: \(error)",
          level: .info, category: "TranscriptCoordinator"
        )
      }
    }
  }

  // MARK: - Escape Recovery expiry pulse (#2087)

  /// Interleave two newest-first lists without disturbing either's order.
  ///
  /// On a TIE the permanent row goes first, deliberately: a held row is an
  /// unresolved offer, and an offer should not displace a dictation the user
  /// actually completed at the same instant.
  ///
  /// A plain `sorted` over the concatenation is the obvious alternative and is
  /// rejected for a narrower reason than it first appears. `Array.sorted` is
  /// NOT documented as stable, so its behaviour on tied `createdAt` values is
  /// unspecified — today's implementation happens to preserve input order, and
  /// nothing promises the next toolchain will. That makes the tie case a
  /// silent, toolchain-dependent reordering of shipped History, caused by a
  /// feature that is supposed to be inert. This merge specifies the answer
  /// instead of inheriting it.
  ///
  /// Honest limit: because the current sort IS stable in practice, the two
  /// implementations differ observably only in which row wins a tie — which is
  /// exactly what `heldRowLosesATieWithAPermanentRow` pins.
  private static func mergeNewestFirst(
    _ held: [Transcript], _ permanent: [Transcript]
  ) -> [Transcript] {
    guard !held.isEmpty else { return permanent }
    var result: [Transcript] = []
    result.reserveCapacity(held.count + permanent.count)
    var h = 0
    var p = 0
    while h < held.count, p < permanent.count {
      if held[h].createdAt > permanent[p].createdAt {
        result.append(held[h])
        h += 1
      } else {
        result.append(permanent[p])
        p += 1
      }
    }
    result.append(contentsOf: held[h...])
    result.append(contentsOf: permanent[p...])
    return result
  }

  private func startPulseIfNeeded() {
    guard pulseTask == nil, livePendingCount > 0 else { return }
    pulseTask = Task { [weak self, pendingPulseInterval, pendingPulseSleep] in
      while !Task.isCancelled {
        await pendingPulseSleep(pendingPulseInterval)
        guard let self, !Task.isCancelled else { return }
        // Bumped BEFORE the stop check, so the pulse that carries the last row
        // past its deadline is itself delivered — otherwise the final expiry
        // would stop the timer and never redraw, leaving the expired row on
        // screen until something unrelated moved.
        self.expiryPulse &+= 1
        if self.livePendingCount == 0 {
          self.pulseTask = nil
          return
        }
      }
    }
  }

  private func stopPulseIfIdle() {
    guard livePendingCount == 0 else { return }
    pulseTask?.cancel()
    pulseTask = nil
  }

  #if DEBUG
    // periphery:ignore - test seam
    var hasPendingPulseForTesting: Bool { pulseTask != nil }

    /// Bumps the pulse the way the loop does, so a test can assert that reading
    /// the visible list actually subscribes to it — without driving the loop.
    // periphery:ignore - test seam
    func bumpExpiryPulseForTesting() {
      expiryPulse &+= 1
    }

    /// The unfiltered rows. Only for assertions about state the read-time
    /// filter deliberately HIDES — an expired row that must keep its stamp, for
    /// instance. Anything a user would see is asserted through
    /// `visibleTranscripts`, which is what production reads.
    // periphery:ignore - test seam
    var rawTranscriptsForTesting: [Transcript] { transcripts }

    /// Awaits the pulse loop's own completion — a real signal, so a test never
    /// guesses how long the loop needs. Captured before awaiting because the
    /// loop nils the handle as it exits.
    // periphery:ignore - test seam
    func waitForPulseForTesting() async {
      let running = pulseTask
      await running?.value
    }

    /// The deadline behind `waitForPulseForTesting`. A loop that stopped
    /// honouring its own exit condition would otherwise spin forever and HANG
    /// the suite — no test name, no assertion, just a wedged run — which is
    /// worse than having no test. A test bounds its iterations and calls this,
    /// so the regression fails loudly instead.
    // periphery:ignore - test seam
    func cancelPulseForTesting() {
      pulseTask?.cancel()
      pulseTask = nil
    }

    // periphery:ignore - test seam
    func setTranscriptsForTesting(_ rows: [Transcript]) {
      transcripts = rows
      startPulseIfNeeded()
    }
  #endif
}
