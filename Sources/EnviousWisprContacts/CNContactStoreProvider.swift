@preconcurrency import Contacts
import Foundation

/// Production `ContactNameProvider` backed by `CNContactStore`.
///
/// One-shot reads only: every call constructs a fresh store and releases it,
/// with no `CNContactStoreDidChange` subscription and no retained handle. This
/// is the bounded-window guardrail (bible §2.4 guardrail 3) — the feature reads
/// when the user (or opt-in launch sync) asks, never continuously.
public struct CNContactStoreProvider: ContactNameProvider {
  public init() {}

  public func authorizationStatus() -> ContactsAuthorization {
    switch CNContactStore.authorizationStatus(for: .contacts) {
    case .authorized: return .authorized
    case .denied: return .denied
    case .restricted: return .restricted
    case .notDetermined: return .notDetermined
    // macOS never returns `.limited`; treat any future case as fail-closed.
    @unknown default: return .restricted
    }
  }

  public func requestAccess() async -> Bool {
    let store = CNContactStore()
    do {
      return try await store.requestAccess(for: .contacts)
    } catch {
      return false
    }
  }

  public func fetchCandidateNames() async throws -> [CandidateName] {
    let store = CNContactStore()
    let keys: [CNKeyDescriptor] = [
      CNContactGivenNameKey as CNKeyDescriptor,
      CNContactFamilyNameKey as CNKeyDescriptor,
      CNContactIdentifierKey as CNKeyDescriptor,
    ]
    let request = CNContactFetchRequest(keysToFetch: keys)
    // `enumerateContacts` runs synchronously; this method is `nonisolated async`
    // so the blocking enumeration executes off the main actor.
    var results: [CandidateName] = []
    try store.enumerateContacts(with: request) { contact, _ in
      let given = contact.givenName.trimmingCharacters(in: .whitespacesAndNewlines)
      let family = contact.familyName.trimmingCharacters(in: .whitespacesAndNewlines)
      // Skip phone-only / no-name entries (the "Spam Caller" failure mode).
      guard !given.isEmpty || !family.isEmpty else { return }
      results.append(
        CandidateName(contactID: contact.identifier, given: given, family: family))
    }
    return results
  }
}
