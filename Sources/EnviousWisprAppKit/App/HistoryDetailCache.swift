import EnviousWisprCore
import EnviousWisprStorage
import Foundation
import Observation

/// Verified History rows hydrated on demand for the screens that show them (#4586 H2/N5).
///
/// One entry per row id holds everything about that row's payload: the row, the source proof it
/// was verified against, the source revision it was read under, how many on-screen views hold it,
/// and the read in flight. The registry itself is NOT observed; each entry is. A view that reads a
/// row through `TranscriptCoordinator.currentRow(id:)` therefore depends on that row's entry only,
/// so hydrating one row no longer redraws every card that asked about any row.
///
/// Entries keep their identity for the cache's life: eviction and clearing empty an entry rather
/// than remove it, so a view that read an empty entry is still told when that row hydrates later.
/// The cost is one small object per row id read this launch, without its payload.
///
/// The coordinator decides WHEN a row is read and whether it may be shown (removal, visibility,
/// live rows, proofs); this type only keeps what was read.
@MainActor
final class HistoryDetailCache {
  @MainActor @Observable
  final class Entry {
    /// The only observed field: a view redraws when this row's payload arrives or leaves.
    fileprivate(set) var row: Transcript?
    @ObservationIgnored fileprivate(set) var proof: [HistoryCatalog.SourceVersion]?
    /// The source revision the payload was read under; nil when it was unknown.
    @ObservationIgnored fileprivate(set) var version: UInt64?
    /// How many on-screen views hold this payload (`TranscriptCoordinator.holdCatalogDetail`).
    @ObservationIgnored fileprivate(set) var holds = 0
    /// One read per content revision, shared by every caller asking for it meanwhile.
    @ObservationIgnored fileprivate var reads:
      [UInt64: Task<HistoryTransactionExecutor.VerifiedHistoryRow?, Never>] = [:]

    fileprivate init() {}
  }

  private var entries: [UUID: Entry] = [:]
  /// Ids whose entry holds a payload, oldest first.
  private var order: [UUID] = []
  private let limit: Int
  /// Payloads kept past the limit even when no view holds them (the latest dictation).
  var keeps: @MainActor (UUID) -> Bool
  /// Called after payloads leave the cache, so caches derived from them can drop theirs.
  var payloadsDropped: (@MainActor () -> Void)?

  init(limit: Int = 120, keeps: @escaping @MainActor (UUID) -> Bool = { _ in false }) {
    self.limit = limit
    self.keeps = keeps
  }

  /// `id`'s entry, created empty on first use. Creating one changes no observed state.
  func entry(_ id: UUID) -> Entry {
    if let entry = entries[id] { return entry }
    let entry = Entry()
    entries[id] = entry
    return entry
  }

  /// Every payload the cache holds now.
  var payloadRows: [Transcript] { order.compactMap { entries[$0]?.row } }

  /// The read in flight for `id` under content `revision`, or the one `start` makes.
  func read(
    _ id: UUID, revision: UInt64,
    start: () -> Task<HistoryTransactionExecutor.VerifiedHistoryRow?, Never>
  ) -> Task<HistoryTransactionExecutor.VerifiedHistoryRow?, Never> {
    let entry = entry(id)
    if let inFlight = entry.reads[revision] { return inFlight }
    let task = start()
    entry.reads[revision] = task
    return task
  }

  /// Forgets `task` once it finished, unless a newer read replaced it.
  func finishRead(
    _ id: UUID, revision: UInt64,
    _ task: Task<HistoryTransactionExecutor.VerifiedHistoryRow?, Never>
  ) {
    guard let entry = entries[id], entry.reads[revision] == task else { return }
    entry.reads[revision] = nil
  }

  func store(_ id: UUID, row: Transcript, proof: [HistoryCatalog.SourceVersion], version: UInt64?) {
    let entry = entry(id)
    // A payload read again keeps its place in the eviction order, as before #4586.
    if entry.row == nil { order.append(id) }
    entry.proof = proof
    entry.version = version
    entry.row = row
    trim()
  }

  /// Drops `id`'s payload (removed, or replaced by a newer published version). Holds and reads
  /// in flight stay: a held view keeps holding, and every read re-verifies against the source.
  func clear(_ id: UUID) {
    guard let entry = entries[id], entry.row != nil || entry.proof != nil else { return }
    order.removeAll { $0 == id }
    empty(entry)
    payloadsDropped?()
  }

  /// Drops every payload (Delete All), keeping holds and reads as `clear` does.
  func clearAll() {
    guard !order.isEmpty else { return }
    for id in order { if let entry = entries[id] { empty(entry) } }
    order.removeAll()
    payloadsDropped?()
  }

  func acquire(_ id: UUID) {
    entry(id).holds += 1
  }

  func release(_ id: UUID) {
    guard let entry = entries[id], entry.holds > 0 else { return }
    entry.holds -= 1
    if entry.holds == 0 { trim() }
  }

  /// Empties the oldest payloads no view holds, down to the limit. Held payloads and kept ones
  /// stay, so the cache may exceed the limit by what is on screen.
  private func trim() {
    var dropped = false
    while order.count > limit,
      let index = order.firstIndex(where: { id in
        (entries[id]?.holds ?? 0) == 0 && !keeps(id)
      })
    {
      let id = order.remove(at: index)
      if let entry = entries[id] { empty(entry) }
      dropped = true
    }
    if dropped { payloadsDropped?() }
  }

  private func empty(_ entry: Entry) {
    entry.proof = nil
    entry.version = nil
    entry.row = nil
  }

  #if DEBUG
    func entryCountForTesting() -> Int { entries.count }
    func payloadCountForTesting() -> Int { order.count }
  #endif
}
