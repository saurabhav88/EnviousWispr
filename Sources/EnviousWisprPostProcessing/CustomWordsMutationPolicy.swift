import EnviousWisprCore
import Foundation

/// Ordinary authoring policy for the dictionary (#4086): what Add, Add-many,
/// Delete, Delete-many, Edit, Edit-many and the learn/Undo built-in moves do to
/// the on-disk file, plus the storable-value and persisted-provenance rules every
/// whole-word write shares. Extracted verbatim from `CustomWordsManager`. Each
/// transform runs inside `CustomWordsFileStore.performLockedTransaction` against
/// the freshly loaded file and returns that transaction's `(value, shouldSave)`;
/// nothing here touches the disk or the caller's in-memory list. Built-ins are
/// passed in so their identities stay the manager's single shipped table.
enum CustomWordsMutationPolicy {
  typealias File = CustomWordsFileStore.CustomWordsFile

  static func add(
    word: CustomWord, trimmed: String, to file: inout File, builtins: [BuiltinWord]
  ) -> (value: [CustomWord], shouldSave: Bool) {
    // If this matches a deleted built-in, restore it instead of adding a user word
    if let builtin = builtins.first(where: {
      $0.word.canonical.caseInsensitiveCompare(trimmed) == .orderedSame
    }) {
      file.deletedBuiltinIds.removeAll { $0 == builtin.id }
      return (mergedWords(file: file, builtins: builtins), true)
    }

    // Re-check uniqueness against the FRESH file, not just the caller's
    // possibly-stale in-memory snapshot above (#1690 cloud review): another
    // process's write can land between that check and this lock actually
    // being acquired. Skipping here — rather than appending a duplicate —
    // matches the pre-lock check's existing no-op contract, and refreshes
    // the caller's `words` to the word the other process already added.
    guard
      !file.words.contains(where: {
        $0.canonical.caseInsensitiveCompare(trimmed) == .orderedSame
      })
    else {
      return (mergedWords(file: file, builtins: builtins), false)
    }

    var sanitized = Self.sanitizeForPersistence(word)
    sanitized.canonical = trimmed
    file.words.append(sanitized)
    return (mergedWords(file: file, builtins: builtins), true)
  }

  static func addBatch(
    _ incoming: [CustomWord], existing words: [CustomWord], to file: inout File,
    builtins: [BuiltinWord]
  ) -> (value: ([UUID], [CustomWord]), shouldSave: Bool) {
    // Seed dedupe from BOTH the in-memory merged list and the on-disk file so a
    // stale `words` snapshot can't produce a duplicate at batch scale.
    var seen = Set(words.map { $0.canonical.lowercased() })
    seen.formUnion(file.words.map { $0.canonical.lowercased() })
    var createdIDs: [UUID] = []

    for word in incoming {
      let trimmed = word.canonical.trimmingCharacters(in: .whitespacesAndNewlines)
      guard Self.isStorable(trimmed) else { continue }
      let key = trimmed.lowercased()
      guard !seen.contains(key) else { continue }

      // Tombstoned-built-in restore (mirrors the built-in branch of add(word:)).
      // A LIVE built-in is already in `seen` (it is in merged `words`), so a
      // built-in match here means it was tombstoned: un-delete it instead of
      // adding a duplicate user word. Restored built-ins are not in createdIDs.
      if let builtin = builtins.first(where: {
        $0.word.canonical.caseInsensitiveCompare(trimmed) == .orderedSame
      }) {
        file.deletedBuiltinIds.removeAll { $0 == builtin.id }
        seen.insert(key)
        continue
      }

      var sanitized = Self.sanitizeForPersistence(word)
      sanitized.canonical = trimmed
      file.words.append(sanitized)
      createdIDs.append(sanitized.id)
      seen.insert(key)
    }

    return ((createdIDs, mergedWords(file: file, builtins: builtins)), true)
  }

  /// One delete is a batch of one (#4086): the single and bulk doors share this rule.
  static func removeBatch(
    ids: [UUID], idSet: Set<UUID>, existing words: [CustomWord], from file: inout File,
    builtins: [BuiltinWord]
  ) -> (value: [CustomWord], shouldSave: Bool) {
    // Tombstone any built-ins whose canonical matches a removed word (mirror
    // remove(id:)). Import-created words are user words, so this is normally
    // inert for the import path, but keeps batch semantics identical to single.
    for id in ids {
      guard let word = words.first(where: { $0.id == id }) else { continue }
      if let builtin = builtins.first(where: {
        $0.word.canonical.lowercased() == word.canonical.lowercased()
      }), !file.deletedBuiltinIds.contains(builtin.id) {
        file.deletedBuiltinIds.append(builtin.id)
      }
    }

    file.words.removeAll { idSet.contains($0.id) }
    return (mergedWords(file: file, builtins: builtins), true)
  }

  static func restoreBuiltinAndLearn(
    trimmedCanonical: String, trimmedAlias: String, in file: inout File,
    builtins: [BuiltinWord]
  ) throws -> (value: RestoredBuiltinLearnOutcome, shouldSave: Bool) {
    guard
      let builtin = builtins.first(where: {
        $0.word.canonical.caseInsensitiveCompare(trimmedCanonical) == .orderedSame
      }), file.deletedBuiltinIds.contains(builtin.id),
      !file.words.contains(where: {
        $0.canonical.caseInsensitiveCompare(trimmedCanonical) == .orderedSame
      })
    else { throw CustomWordsPersistenceError.noRestorableBuiltin }
    var override = builtin.word.ownedByUser()
    let aliasKey = Self.importPersistenceKey(trimmedAlias)
    if !override.aliases.contains(where: { Self.importPersistenceKey($0) == aliasKey }) {
      override.aliases.append(trimmedAlias)
    }
    override.learnedAliases.append(trimmedAlias)
    let persisted = Self.sanitizeForPersistence(override)
    file.deletedBuiltinIds.removeAll { $0 == builtin.id }
    file.words.append(persisted)
    return (
      RestoredBuiltinLearnOutcome(
        preState: .deletedBuiltin(id: builtin.word.id), word: persisted,
        words: mergedWords(file: file, builtins: builtins)),
      true
    )
  }

  static func removeUserOverride(
    id: UUID, from file: inout File, builtins: [BuiltinWord]
  ) -> (value: [CustomWord], shouldSave: Bool) {
    // Only an override of a SHIPPED built-in (same UUID): an ordinary user
    // word is not this method's to remove, whatever the caller believed.
    guard builtins.contains(where: { $0.word.id == id }),
      file.words.contains(where: { $0.id == id })
    else {
      return (mergedWords(file: file, builtins: builtins), false)
    }
    file.words.removeAll { $0.id == id }
    return (mergedWords(file: file, builtins: builtins), true)
  }

  static func redeleteRestoredBuiltin(
    id: UUID, in file: inout File, builtins: [BuiltinWord]
  ) -> (value: [CustomWord], shouldSave: Bool) {
    guard let builtin = builtins.first(where: { $0.word.id == id }) else {
      return (mergedWords(file: file, builtins: builtins), false)
    }
    var changed = false
    if file.words.contains(where: { $0.id == id }) {
      file.words.removeAll { $0.id == id }
      changed = true
    }
    if !file.deletedBuiltinIds.contains(builtin.id) {
      file.deletedBuiltinIds.append(builtin.id)
      changed = true
    }
    return (mergedWords(file: file, builtins: builtins), changed)
  }

  static func update(
    word: CustomWord, sanitized: CustomWord, previousCanonical: String, in file: inout File,
    builtins: [BuiltinWord]
  ) -> (value: [CustomWord], shouldSave: Bool) {
    let existingIdx = file.words.firstIndex(where: { $0.id == word.id })

    // A missing id means one of two things: this is a built-in being
    // overridden for the first time (expected, append it), or a sibling
    // process deleted this exact user word while this edit was in flight
    // (#1690 cloud review). Absence alone cannot distinguish them — only a
    // real match against this process's own built-in ids can. Silently
    // resurrecting a word the user, via the other window, already removed
    // is wrong; drop the stale edit instead and publish the fresh state so
    // the caller's view self-heals to reflect the deletion.
    guard
      existingIdx != nil
        || builtins.contains(where: { $0.word.id == word.id })
    else {
      return (mergedWords(file: file, builtins: builtins), false)
    }

    if let builtin = builtins.first(where: {
      $0.word.canonical.lowercased() == previousCanonical.lowercased()
    }),
      builtin.word.canonical.lowercased() != sanitized.canonical.lowercased(),
      !file.deletedBuiltinIds.contains(builtin.id)
    {
      file.deletedBuiltinIds.append(builtin.id)
    }

    // Check if this is a built-in word being edited — store as user override
    if let existingIdx {
      file.words[existingIdx] = sanitized
    } else {
      // Editing a built-in: add as user word (overrides built-in by canonical match).
      file.words.append(sanitized)
    }
    return (mergedWords(file: file, builtins: builtins), true)
  }

  /// Contacts alias enrichment (#636 follow-up), narrowed in #4086: each proposal only
  /// fills an empty alias list on the word it was generated for. Under the lock the
  /// word must still exist, still carry the canonical the aliases were generated from,
  /// still be a person, and still have no aliases; otherwise the proposal is stale and
  /// is skipped. Every other field stays exactly as the file has it, so an edit made
  /// while the aliases were being generated is never overwritten. A missing word is
  /// never resurrected.
  static func applyGeneratedAliases(
    _ proposals: [GeneratedAliasProposal], in file: inout File, builtins: [BuiltinWord]
  ) -> (value: [CustomWord]?, shouldSave: Bool) {
    var changed = false
    for proposal in proposals {
      guard let idx = file.words.firstIndex(where: { $0.id == proposal.id }),
        file.words[idx].canonical == proposal.canonical,
        file.words[idx].category == .person,
        file.words[idx].aliases.isEmpty
      else { continue }
      let aliases = Self.sanitizeAliases(proposal.aliases)
      guard !aliases.isEmpty else { continue }
      file.words[idx].aliases = aliases
      changed = true
    }
    guard changed else { return (nil, false) }
    return (mergedWords(file: file, builtins: builtins), true)
  }

  // MARK: - Storable values and persisted provenance

  /// This type's own dedup rule, named so the import path cannot accidentally
  /// reach for the compare engine's stronger matching key (PR-F2a).
  static func importPersistenceKey(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  /// The ONE rule for valid persisted learned provenance (#996 §3c): aliases
  /// are sanitized first (trimmed, unstorable dropped), then `learnedAliases`
  /// is reduced to the stored aliases it names, in alias order, with no
  /// duplicates. A learned mark written as `" alias "` keeps its mark once the
  /// alias is stored as `"alias"`, and an alias the user removed by hand takes
  /// its mark with it. Marks match aliases by the manager's own persistence
  /// key (trimmed, lowercased), the same rule that decides which spellings
  /// are one alias, so `"Twist"` keeps a mark written as `"twist"` and the
  /// stored spelling is the one that wins. Every whole-word persistence site
  /// calls this; nothing else validates provenance, so a caller cannot store
  /// a mark for a sound-alike the word does not have. Every other field
  /// passes through.
  static func sanitizeForPersistence(_ word: CustomWord) -> CustomWord {
    var out = word
    out.aliases = sanitizeAliases(word.aliases)
    let learnedKeys = Set(sanitizeAliases(word.learnedAliases).map(Self.importPersistenceKey))
    var seen = Set<String>()
    out.learnedAliases = out.aliases.filter {
      let key = Self.importPersistenceKey($0)
      return learnedKeys.contains(key) && seen.insert(key).inserted
    }
    return out
  }

  /// Whether a value may enter the library AT ALL, from any authoring path.
  ///
  /// The same question importing asks, asked here — because "what may be
  /// stored" is one rule and the library is what it protects. Applying only
  /// PART of it here (length, but not the character policy) let the editor
  /// author a word that export then refused, which is the round-trip
  /// asymmetry again with authoring as the door (cloud review, #1683).
  static func isStorable(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      trimmed.unicodeScalars.count <= CustomWordsImportLimits.maximumStoredValueScalars
    else { return false }
    return CustomWordsImportTextPolicy.isAcceptableStoredValue(trimmed)
  }

  /// True when every alias the user actually authored can be stored.
  ///
  /// Blank aliases are not a refusal — the editor leaves empty rows behind and
  /// dropping those is ordinary trimming, not a lost edit. A NON-blank alias
  /// that the policy refuses is the lie this catches: `sanitizeAliases` would
  /// filter it out and the save would report success without it.
  static func everyAliasIsStorable(_ aliases: [String]) -> Bool {
    aliases
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .allSatisfy { isStorable($0) }
  }

  static func sanitizeAliases(_ aliases: [String]) -> [String] {
    aliases
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      // The whole rule, not a piece of it: an alias the app stores but cannot
      // export breaks the round trip just as thoroughly as a canonical does.
      .filter { isStorable($0) }
  }

  // MARK: - Runtime Merge

  /// Merge built-in defaults with user words. Built-ins not tombstoned and not
  /// overridden by a user word (same canonical, case-insensitive) are included.
  static func mergedWords(file: File, builtins: [BuiltinWord]) -> [CustomWord] {
    let tombstones = Set(file.deletedBuiltinIds)
    let activeBuiltins =
      builtins
      .filter { !tombstones.contains($0.id) }
      .map(\.word)

    let userCanonicals = Set(file.words.map { $0.canonical.lowercased() })
    let nonOverriddenBuiltins = activeBuiltins.filter {
      !userCanonicals.contains($0.canonical.lowercased())
    }

    return nonOverriddenBuiltins + file.words
  }
}
