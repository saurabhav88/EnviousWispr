import Foundation

/// macOS Contacts authorization state, framework-agnostic so callers outside
/// this module never import Contacts.
///
/// macOS authorization is all-or-nothing: there is NO `.limited` case (that is
/// iOS 18+ only). This corrects the bible §12.6 assumption.
public enum ContactsAuthorization: Sendable, Equatable {
  case notDetermined
  case authorized
  case denied
  case restricted
}

/// One real, named contact reduced to only the fields this feature reads.
///
/// `contactID` is `CNContact.identifier` — opaque, stable across launches, and
/// the dedupe / re-scan key. No phone, email, photo, note, or organization is
/// ever carried (names-only, bible §12). `given` / `family` are already
/// whitespace-trimmed by the provider; at least one is non-empty.
public struct CandidateName: Sendable, Equatable {
  public let contactID: String
  public let given: String
  public let family: String

  public init(contactID: String, given: String, family: String) {
    self.contactID = contactID
    self.given = given
    self.family = family
  }
}

/// A read-only, on-device source of contact names. The production conformer
/// (`CNContactStoreProvider`) wraps `CNContactStore`; tests use a fake.
///
/// Invariants the caller MUST uphold:
/// - `NSContactsUsageDescription` is present in the app's Info.plist before any
///   method that touches `CNContactStore` runs — Apple aborts the process
///   otherwise.
/// - `fetchCandidateNames()` is not called when status is `.denied` /
///   `.restricted`.
public protocol ContactNameProvider: Sendable {
  /// Current authorization without prompting.
  func authorizationStatus() -> ContactsAuthorization
  /// Prompt for access if `.notDetermined`; returns whether access is granted.
  func requestAccess() async -> Bool
  /// One-shot read of every real, named contact. No persistent observer.
  func fetchCandidateNames() async throws -> [CandidateName]
}
