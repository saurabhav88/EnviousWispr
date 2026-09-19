import EnviousWisprCore
import EnviousWisprPostProcessing
import Foundation

// MARK: - Custom word save helper (#996 §4, F3)
//
// The one App-layer owner of two questions Quick Add answered privately and
// the learn-from-edits coordinator (chunk 5e) must answer the same way:
// WHICH stored word does an accept write into, decided against the library as
// it is NOW, and DID the write land. `quickAddTarget` and `saveAndConfirm` are
// Quick Add's own implementations, moved here verbatim with their reasons;
// `proposalTarget` is the corrected-string entrypoint the proposal card uses
// and Quick Add never calls. Nothing here allocates a word id or writes on its
// own: `saveAndConfirm` is the only write, and it goes through
// `CustomWordsCoordinator`.

@MainActor
enum CustomWordSaveHelper {

  /// What an accept should write INTO, decided against the library as it is NOW.
  enum QuickAddTarget: Equatable {
    /// A pack term, converted to a user-owned override. Nothing in the user library to merge into.
    case override(CustomWord)
    /// A user word still in the library. Carries the CURRENT entry, never the snapshot.
    case live(CustomWord)
    /// It was in the library when the panel was ranked and is not there now.
    case gone
  }

  /// Resolve the merge target from the LIVE library rather than the ranking's snapshot.
  ///
  /// **`candidate.word` is a snapshot taken when the panel was ranked, and the panel is now
  /// persistent.** `windowDidResignKey` is deliberately a no-op — because treating focus loss as a
  /// dismissal cancelled the panel 339 ms after opening — so it can sit open across a visit to
  /// Settings. Appending an alias to that snapshot and handing it to `CustomWordsManager.update`
  /// replaces the WHOLE stored entry, so a canonical, alias, category, strictness or usage change
  /// made in between is silently reverted: a write that reports success while undoing the user's own
  /// edit.
  ///
  /// A third instance of two correct fixes composing into a defect neither had alone. Persistence
  /// was the fix for self-cancellation, and persistence is what gives the snapshot time to go stale.
  ///
  /// `.gone` is the same defect pointing the other way and is why this returns three cases rather
  /// than an optional: writing the snapshot back for a word deleted while the panel sat open would
  /// RESURRECT it, which is a silent undo of a deletion rather than of an edit.
  ///
  /// Scope, stated rather than implied: this reads the in-memory library, which is the one the
  /// editor writes through, so it covers every edit made inside this app. It is not a cross-process
  /// claim, and the app does not support a second instance.
  static func quickAddTarget(
    for candidate: QuickAddRanker.Candidate, in userWords: [CustomWord]
  ) -> QuickAddTarget {
    // ASKED BEFORE THE PACK BRANCH, and the order is the whole point. `ownedByUser()` PRESERVES the
    // id, so a pack term the user overrode while this panel sat open is now a real user entry under
    // that same id — and converting the snapshot again would overwrite the override they just made.
    // A pack candidate that has not been overridden cannot be here: `packTermsNotOverridden` filters
    // the ranking by exactly this id set, so a pack row reaching this line has no live twin.
    if let current = userWords.first(where: { $0.id == candidate.word.id }) {
      return .live(current)
    }
    // **A pack row whose CANONICAL the user already owns under a different id.** `ownedByUser()`
    // keeps the pack's id, and `packTermsNotOverridden` filters the ranking by ID, so a user word
    // called "Codec" and an enabled pack term called "Codec" are two rows with two ids and one name.
    // Converting the pack snapshot then hands `CustomWordsManager.add` a colliding canonical, which
    // it refuses SILENTLY (`guard !words.contains(sameCanonical) else { return }`) — and the
    // post-write confirmation then finds the spelling on the USER word and reports success for an
    // override that was never created.
    //
    // Merging into the user's own entry is not a consolation prize, it is the only action that can
    // succeed: while that canonical is taken, no override under it is writable, and the end state
    // the user asked for — this spelling maps to that word — is exactly what this produces.
    //
    // Scoped to pack rows deliberately. A USER candidate missing by id is `.gone`, which is a
    // deletion the panel must not paper over by matching on a name that happens to be reused.
    if candidate.isPackTerm,
      let sameName = userWords.first(where: {
        $0.canonical.caseInsensitiveCompare(candidate.word.canonical) == .orderedSame
      })
    {
      return .live(sameName)
    }
    // A PACK term cannot be written through the words coordinator: `CustomWordsManager.update` looks
    // the id up in the user library, does not find it, and returns having written NOTHING. Convert
    // to a user-owned override first. The resulting override reaches the polish lane as well as the
    // corrector lane, which the underlying pack term never did.
    guard !candidate.isPackTerm else { return .override(candidate.word.ownedByUser()) }
    return .gone
  }

  /// What a learned correction should write INTO, decided against the library
  /// as it is NOW, from the proposal's immutable corrected spelling (plan §3.1
  /// step 10). The proposal has no ranking snapshot and no candidate id, so
  /// the question is asked of the spelling alone.
  enum ProposalTarget: Equatable {
    /// A user word whose canonical is the corrected spelling. Carries the
    /// CURRENT entry, never anything the proposal remembered.
    case existing(CustomWord)
    /// An enabled pack term whose canonical is the corrected spelling, already
    /// converted to a user-owned override (`ownedByUser()` keeps the pack's
    /// id), exactly as Quick Add's `.override` does.
    case packOverride(CustomWord)
    /// No word carries that canonical: the accept creates a new word.
    case new
  }

  /// Resolve the corrected spelling against the SUPPLIED current values: the
  /// user's words first, then the enabled pack terms. Pure; allocates no id and
  /// writes nothing. Matching uses the same normalisation as the filter that
  /// proposed the card (`CorrectionPairKey.normalise`, NFC + casefold), so the
  /// state assigned at proposal time and the target resolved at Accept agree
  /// on what "the same canonical" means.
  static func proposalTarget(
    for corrected: String, in words: [CustomWord], packTerms: [CustomWord]
  ) -> ProposalTarget {
    let key = CorrectionPairKey.normalise(corrected.trimmingCharacters(in: .whitespaces))
    if let user = words.first(where: { CorrectionPairKey.normalise($0.canonical) == key }) {
      return .existing(user)
    }
    if let pack = packTerms.first(where: { CorrectionPairKey.normalise($0.canonical) == key }) {
      return .packOverride(pack.ownedByUser())
    }
    return .new
  }

  /// Write a word and PROVE the spelling is on it afterwards.
  ///
  /// **A nil return from the words coordinator is not evidence the write happened**, and this is the
  /// third distinct way that has been true in this feature. `add` returns silently for a duplicate
  /// canonical and for a deleted-built-in restore; `update` opens
  /// `guard let index = words.firstIndex(where: { $0.id == word.id }) else { return }`, so a word
  /// another instance removed while this panel was open is written NOWHERE and reported as saved.
  /// The panel then closes on a spelling that was never stored.
  ///
  /// Every one of those is invisible to the caller and all of them have one observable: is the
  /// spelling on the word now. So that is what this asks, instead of asking three questions about
  /// how the write was routed.
  ///
  /// `add` when the word is new to the user library, `update` when it is already there. A converted
  /// pack term is NEW here even though its id is the pack's, which is why the decision is by
  /// membership rather than by `source`.
  static func saveAndConfirm(
    _ word: CustomWord, carrying spelling: String, through customWords: CustomWordsCoordinator
  ) -> String? {
    let existing = customWords.customWords.contains { $0.id == word.id }
    if let message = existing ? customWords.update(word) : customWords.add(word) { return message }

    let wanted = spelling.trimmingCharacters(in: .whitespacesAndNewlines)
    let landed = customWords.customWords.contains { stored in
      stored.canonical.caseInsensitiveCompare(word.canonical) == .orderedSame
        && stored.aliases.contains { $0.caseInsensitiveCompare(wanted) == .orderedSame }
    }
    return landed ? nil : QuickAddPanelCopy.newWordNotSaved
  }
}
