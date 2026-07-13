import Foundation

/// Explicit Sentry wire identity for an error type whose shipped grouping must not
/// depend on Swift enum layout.
///
/// By default `SentryBreadcrumb.structuredDescriptor` derives an error's Sentry
/// identity from its bridged `NSError` — and for a Swift error enum the bridged
/// `code` is the case's DECLARATION ORDINAL. That is compiler/runtime behaviour,
/// not a language guarantee. Adding or removing a case mid-enum renumbers every
/// later case, which silently re-points their shipped Sentry issues: a shifted
/// case inherits its neighbour's fingerprint and its events start landing in that
/// neighbour's issue (#1524 — three live groups, one with 525 events across 160
/// users, would each have begun absorbing a different defect).
///
/// Conforming pins the identity to a value we choose, so cases can be added and
/// removed freely.
///
/// Opt-in by design. A type that does not conform keeps the existing
/// `domain#code` behaviour byte-for-byte. Migrating the remaining error types is
/// tracked in #1525; auditing the wider "incidental value used as a stable
/// identity" class is #1526.
public protocol StableSentryErrorIdentity {
  /// The Sentry grouping key component. **PINNED — once shipped, never change it.**
  /// For an error that already reached production, this must be the exact string it
  /// has been sending (measure it; do not re-derive it), so no issue re-groups.
  var sentryFingerprintDescriptor: String { get }

  /// Human-readable identifier, emitted as the `error.identity` tag. Metadata only:
  /// it never enters the fingerprint, so it is safe to rename.
  var sentrySemanticID: String { get }
}
