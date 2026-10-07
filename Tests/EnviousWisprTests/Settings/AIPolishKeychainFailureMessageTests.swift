import Foundation
import Security
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprLLM

/// Regression tests for #724 — keychain failure → user-facing message mapping.
///
/// The previous behavior surfaced raw `OSStatus` codes like `"Failed: Key delete
/// failed: -25291"` directly in the validation badge. After the fix, the badge
/// shows a short action-oriented sentence and never includes a numeric code.
@Suite("AIPolishKeychainFailureMessage")
struct AIPolishKeychainFailureMessageTests {

  // MARK: - Known OSStatus mappings

  // MARK: - rollbackFailed case (no numeric code)

  // MARK: - Unknown OSStatus falls back, no numeric leak

  // MARK: - Non-KeyStoreError fallback

  @Test("non-KeyStoreError falls back to generic action-specific copy")
  func nonKeyStoreErrorFallsBack() {
    struct WeirdError: Error {}
    let result = AIPolishKeychainFailureMessage.text(
      for: WeirdError(),
      action: .clear
    )
    #expect(result.hasPrefix("Failed: "))
    #expect(result.contains("clear"))
  }

  // MARK: - Every sentence's English, whole (#3142)

  /// Each message is one localizable sentence including its "Failed: " opening, so the
  /// English is pinned whole here. Unit tests run outside the app bundle and see English.
  @Test("every failure sentence keeps its exact English")
  func everyFailureSentenceKeepsItsExactEnglish() {
    let cases: [(any Error, AIPolishKeychainFailureMessage.Action, String)] = [
      (KeyStoreError.deleteFailed(errSecUserCanceled), .clear, "Failed: Cancelled."),
      (
        KeyStoreError.storeFailed(errSecAuthFailed), .save,
        "Failed: Could not access the Keychain. Unlock it from Keychain Access and try again."
      ),
      (
        KeyStoreError.storeFailed(errSecInteractionNotAllowed), .save,
        "Failed: Keychain is locked. Unlock it and try again."
      ),
      (
        KeyStoreError.deleteFailed(errSecInteractionRequired), .clear,
        "Failed: Keychain is locked. Unlock it and try again."
      ),
      (
        KeyStoreError.storeFailed(errSecMissingEntitlement), .save,
        "Failed: EnviousWispr is missing Keychain entitlements. Reinstall the app."
      ),
      (
        KeyStoreError.storeFailed(errSecNotAvailable), .save,
        "Failed: Keychain is unavailable. Restart EnviousWispr and try again."
      ),
      (
        KeyStoreError.retrieveFailed(errSecItemNotFound), .save, "Failed: Key not found. Try again."
      ),
      (
        KeyStoreError.storeFailed(errSecDuplicateItem), .save,
        "Failed: A duplicate key is already saved. Clear it and try again."
      ),
      (
        KeyStoreError.storeFailed(-99999), .save,
        "Failed: Could not save the key. Try again, or restart the app."
      ),
      (
        KeyStoreError.deleteFailed(-99999), .clear,
        "Failed: Could not clear the saved key. Try again, or restart the app."
      ),
      (
        KeyStoreError.unsupportedKey("other"), .save,
        "Failed: This key store item is not supported. Please contact support."
      ),
      (
        KeyStoreError.rollbackFailed(
          cleanup: NSError(domain: "test", code: 1), rollback: NSError(domain: "test", code: 2)),
        .save,
        "Failed: We could not finish saving. Restart EnviousWispr and try again."
      ),
    ]
    for (error, action, expected) in cases {
      #expect(AIPolishKeychainFailureMessage.text(for: error, action: action) == expected)
    }
  }

  // MARK: - No raw OSStatus ever appears in output

  @Test("no message includes a raw negative number for any known code")
  func noMessageIncludesRawNegativeNumberForKnownCodes() {
    let knownStatuses: [OSStatus] = [
      errSecUserCanceled,
      errSecAuthFailed,
      errSecInteractionNotAllowed,
      errSecInteractionRequired,
      errSecMissingEntitlement,
      errSecNotAvailable,
      errSecItemNotFound,
      errSecDuplicateItem,
    ]
    for status in knownStatuses {
      for action in [AIPolishKeychainFailureMessage.Action.save, .clear] {
        let result = AIPolishKeychainFailureMessage.text(
          for: KeyStoreError.storeFailed(status),
          action: action
        )
        #expect(
          !result.contains("\(status)"),
          "OSStatus \(status) leaked into message: \(result)"
        )
      }
    }
  }
}
