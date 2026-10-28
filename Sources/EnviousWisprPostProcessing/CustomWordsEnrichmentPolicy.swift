import EnviousWisprCore
import Foundation

/// Bulk-import enrichment policy for the dictionary (#4086): repairing the durable
/// progress total, applying a checkpoint of generated aliases, and the durable
/// Cancel sweep. Extracted verbatim from `CustomWordsManager`. Each transform runs
/// inside `CustomWordsFileStore.performLockedTransaction` against the freshly
/// loaded file and returns that transaction's `(value, shouldSave)`; nothing here
/// touches the disk. Alias ownership is `WordCorrector`'s, and the storable-value,
/// persistence-key and merge rules are `CustomWordsMutationPolicy`'s.
enum CustomWordsEnrichmentPolicy {
  typealias File = CustomWordsFileStore.CustomWordsFile

  static func repairPendingTotal(in file: inout File) -> (value: Int?, shouldSave: Bool) {
    let livePendingCount = file.words.filter(\.enrichmentPending).count
    if livePendingCount == 0 {
      guard file.pendingEnrichmentBatchTotal != nil else { return (nil, false) }
      file.pendingEnrichmentBatchTotal = nil
      return (nil, true)
    }
    guard file.pendingEnrichmentBatchTotal == nil else {
      return (file.pendingEnrichmentBatchTotal, false)
    }
    file.pendingEnrichmentBatchTotal = livePendingCount
    return (livePendingCount, true)
  }

  static func applyResults(
    _ results: [CustomWordEnrichmentResult], to file: inout File, builtins: [BuiltinWord]
  ) -> (value: CustomWordsEnrichmentCheckpointOutcome, shouldSave: Bool) {
    var touchedIDs: [UUID] = []
    var candidatesByID: [UUID: [String]] = [:]

    for result in results {
      guard let idx = file.words.firstIndex(where: { $0.id == result.id }) else { continue }
      guard file.words[idx].enrichmentPending else { continue }
      let existingKeys = Set(file.words[idx].aliases.map(CustomWordsMutationPolicy.importPersistenceKey))
      var seenThisWord = existingKeys
      var candidates: [String] = []
      for alias in CustomWordsMutationPolicy.sanitizeAliases(result.generatedAliases) {
        let key = CustomWordsMutationPolicy.importPersistenceKey(alias)
        guard !key.isEmpty, !seenThisWord.contains(key) else { continue }
        candidates.append(alias)
        seenThisWord.insert(key)
      }
      file.words[idx].enrichmentPending = false
      touchedIDs.append(result.id)
      candidatesByID[result.id] = candidates
    }

    // Ownership seeded from the CURRENT, untouched library — every alias
    // any word holds right now, whether or not that word is touched, is a
    // real existing claim a new guess must respect. Never stripped and
    // never replayed: only the newly generated candidates below are ever
    // validated or gap-filled.
    var index = WordCorrector.buildExactTriggerIndex(words: CustomWordsMutationPolicy.mergedWords(file: file, builtins: builtins))
    var applied: [CustomWordEnrichmentResult] = []
    for id in touchedIDs {
      guard let idx = file.words.firstIndex(where: { $0.id == id }) else {
        applied.append(CustomWordEnrichmentResult(id: id, generatedAliases: []))
        continue
      }
      let canonical = file.words[idx].canonical
      let canonicalKey = CustomWordsMutationPolicy.importPersistenceKey(canonical)
      var accepted: [String] = []
      for alias in candidatesByID[id] ?? [] {
        // Redundant with the word's OWN canonical: silently dropped, same
        // as `enforceAliases` (Codex Chunk 2 review round 3 finding 1 — the
        // per-word ownership check excludes the word's own existing
        // claims, so without this a generated "Kubernetes" could land on
        // canonical "Kubernetes" itself).
        if CustomWordsMutationPolicy.importPersistenceKey(alias) == canonicalKey { continue }
        // Mirrors `enforceAliases`'s own three-way branch exactly — a
        // generated guess earns no different treatment than an imported
        // one. `.noClaims` (the alias produces no real trigger claim at
        // all) is dropped, same as there.
        switch index.resolveAliasOwnership(for: alias, excludingOwnerID: id) {
        case .noClaims, .blocked:
          continue
        case .available(let claims):
          index.gapFill(
            claims,
            owner: WordCorrector.TriggerOwner(wordID: id, canonical: canonical, isPack: false))
          accepted.append(alias)
        }
      }
      file.words[idx].aliases.append(contentsOf: accepted)
      applied.append(CustomWordEnrichmentResult(id: id, generatedAliases: accepted))
    }

    let changed = !touchedIDs.isEmpty
    let stillPending = file.words.contains(where: \.enrichmentPending)
    var totalChanged = false
    if file.pendingEnrichmentBatchTotal != nil, !stillPending {
      file.pendingEnrichmentBatchTotal = nil
      totalChanged = true
    }

    return (
      CustomWordsEnrichmentCheckpointOutcome(
        snapshot: CustomWordsLibrarySnapshot(
          words: CustomWordsMutationPolicy.mergedWords(file: file, builtins: builtins),
          pendingEnrichmentBatchTotal: file.pendingEnrichmentBatchTotal),
        applied: applied),
      changed || totalChanged
    )
  }

  static func cancel(
    in file: inout File, builtins: [BuiltinWord]
  ) -> (value: CustomWordsLibrarySnapshot, shouldSave: Bool) {
    var changed = false
    for idx in file.words.indices where file.words[idx].enrichmentPending {
      file.words[idx].enrichmentPending = false
      changed = true
    }
    if file.pendingEnrichmentBatchTotal != nil {
      file.pendingEnrichmentBatchTotal = nil
      changed = true
    }
    return (
      CustomWordsLibrarySnapshot(
        words: CustomWordsMutationPolicy.mergedWords(file: file, builtins: builtins),
        pendingEnrichmentBatchTotal: file.pendingEnrichmentBatchTotal),
      changed
    )
  }
}
