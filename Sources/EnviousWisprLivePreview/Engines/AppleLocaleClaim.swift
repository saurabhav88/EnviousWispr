import Foundation

/// Pure decisions about macOS locale claims, with no Speech import and no availability gate.
///
/// Everything here was measured against the real SDK for #2145; the citations are in
/// `docs/feature-requests/issue-2145-2026-08-17-preview-locale-claim.md` §2.5.5. It lives apart from
/// `LocaleClaims` because these are questions with answers, not state — and because the one
/// decision that caused #2145 has to be reachable from a test without Apple's static inventory.
package enum AppleLocaleClaim {

  /// Which `Locale` to hand `AssetInventory.release(reservedLocale:)` for `tag`.
  ///
  /// **`release` matches on `Locale.identifier`, not on the BCP-47 tag, and that one fact is the
  /// whole of #2145.** The inventory stores `en_US`; `Locale(identifier:)` keeps whatever spelling it
  /// is given, so the `Locale(identifier: "en-US")` every call site used to pass matched nothing and
  /// released nothing, for as long as the feature has shipped. Measured, each trial on a clean slate:
  /// `"en-US"` returned false with the claim still held; `"en_US"` and the inventory's own object both
  /// returned true and cleared it.
  ///
  /// Prefer the inventory's OWN object when the claim is visible: it cannot drift from whatever
  /// spelling Apple canonicalises to next, which a hand-built identifier can. Fall back to the ICU
  /// form only when the claim is invisible — a phantom refused by `reserve` but absent from
  /// `reservedLocales` — because there is no object to prefer.
  ///
  /// **On today's macOS that preference is unfalsifiable, and it is kept anyway.** Measured across all
  /// 54 supported locales: the ICU form rebuilt from the BCP-47 tag equals the stored identifier every
  /// time, 0 divergent, so the fallback alone would be correct and no realistic input distinguishes
  /// the two branches. It stays because the failure it guards is SILENT — a spelling the rebuild does
  /// not reproduce sends `release` straight back to returning false and doing nothing. Its test
  /// therefore uses a synthetic divergent object; a realistic one passed with the preference deleted,
  /// which is a guard that looks binding and is not.
  package static func releaseTarget(tag: String, reserved: [Locale]) -> Locale {
    reserved.first { $0.identifier(.bcp47) == tag }
      ?? Locale(identifier: Locale(identifier: tag).identifier(.icu))
  }

  /// What to do after `AssetInventory.reserve` has answered.
  ///
  /// `reserve` returning false is NOT a failure: it means "did not newly claim", which covers the
  /// entirely healthy case where the claim was already held. So the authority is a follow-up read of
  /// `LocaleInventory.reserved`, never the Bool — the same reasoning `performClaim` applies to
  /// `release`.
  package enum ReserveOutcome: Equatable, Sendable {
    /// Claimed, or already held. Nothing more to do.
    case proceed
    /// Refused once while the follow-up authority still reports no claim. Retry `reserve` once, and
    /// never release: another process can claim the tag between our read and our release, and no
    /// lock of ours spans that gap. Measured context: a LIVE holder's claim is always visible, so an
    /// invisible refusing claim belongs to no running process — but "nobody holds it now" is not
    /// "nobody will hold it a microsecond from now", which is why the retry acts and the release
    /// does not.
    case recover
    /// Refused again after recovery. This one is real; let the caller tell the user.
    case refuse
  }

  package static func outcome(
    reserveReturned: Bool, heldAfter: Bool, recoveryAlreadyTried: Bool
  ) -> ReserveOutcome {
    if reserveReturned || heldAfter { return .proceed }
    return recoveryAlreadyTried ? .refuse : .recover
  }

  /// Which claim may be evicted to make room, or nil to leave the table alone.
  ///
  /// **Only ever a claim this process took and no longer needs.** One process can release another
  /// LIVE process's claim, silently — measured: the holder's own next read came back empty. Today
  /// every release in the app is a no-op so that hazard is inert; fixing the release form arms it.
  /// A refused download is a bad outcome, and silently breaking another app's dictation is a worse
  /// one, so when nothing is ours to give up this returns nil and Apple's own refusal surfaces.
  ///
  /// `reserved` order is preserved so the choice is deterministic for a given inventory reading.
  package static func evictionVictim(
    reserved: [String], owned: Set<String>, inUse: Set<String>
  ) -> String? {
    reserved.first { owned.contains($0) && !inUse.contains($0) }
  }
}
