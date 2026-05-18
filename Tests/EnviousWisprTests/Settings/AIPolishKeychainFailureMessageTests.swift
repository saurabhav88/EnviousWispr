import Foundation
import Security
import Testing

@testable import EnviousWispr
@testable import EnviousWisprLLM

/// Regression tests for #724 — keychain failure → user-facing message mapping.
///
/// The previous behavior surfaced raw `OSStatus` codes like `"Failed: Key delete
/// failed: -25291"` directly in the validation badge. After the fix, the badge
/// shows a short action-oriented sentence and never includes a numeric code.
@Suite("AIPolishKeychainFailureMessage")
struct AIPolishKeychainFailureMessageTests {

  // MARK: - Known OSStatus mappings

  @Test("errSecUserCanceled maps to Cancelled")
  func userCanceledMapsToCancelled() {
    let result = AIPolishKeychainFailureMessage.text(
      for: KeyStoreError.deleteFailed(errSecUserCanceled),
      action: .clear
    )
    #expect(result == "Failed: Cancelled.")
  }

  @Test("errSecAuthFailed gives Keychain Access guidance")
  func authFailedGivesKeychainAccessGuidance() {
    let result = AIPolishKeychainFailureMessage.text(
      for: KeyStoreError.storeFailed(errSecAuthFailed),
      action: .save
    )
    #expect(result.hasPrefix("Failed: "))
    #expect(result.contains("Keychain Access"))
    #expect(!result.contains("-"))  // no negative numeric codes leaked
  }

  @Test("errSecInteractionNotAllowed prompts unlock")
  func interactionNotAllowedPromptsUnlock() {
    let result = AIPolishKeychainFailureMessage.text(
      for: KeyStoreError.deleteFailed(errSecInteractionNotAllowed),
      action: .clear
    )
    #expect(result.contains("locked"))
    #expect(!result.contains("-25308"))
  }

  @Test("errSecMissingEntitlement suggests reinstall")
  func missingEntitlementSuggestsReinstall() {
    let result = AIPolishKeychainFailureMessage.text(
      for: KeyStoreError.storeFailed(errSecMissingEntitlement),
      action: .save
    )
    #expect(result.contains("entitlement") || result.contains("Reinstall"))
    #expect(!result.contains("-34018"))
  }

  @Test("errSecItemNotFound on save reads as Key not found")
  func itemNotFoundOnSaveReadsAsKeyNotFound() {
    let result = AIPolishKeychainFailureMessage.text(
      for: KeyStoreError.retrieveFailed(errSecItemNotFound),
      action: .save
    )
    #expect(result.contains("Key not found") || result.contains("not found"))
  }

  @Test("errSecNotAvailable maps to restart prompt")
  func notAvailableMapsToRestart() {
    let result = AIPolishKeychainFailureMessage.text(
      for: KeyStoreError.storeFailed(errSecNotAvailable),
      action: .save
    )
    #expect(result.contains("unavailable") || result.contains("Restart"))
    #expect(!result.contains("-25291"))
  }

  @Test("errSecInteractionRequired prompts unlock (same as errSecInteractionNotAllowed)")
  func interactionRequiredPromptsUnlock() {
    let result = AIPolishKeychainFailureMessage.text(
      for: KeyStoreError.storeFailed(errSecInteractionRequired),
      action: .save
    )
    #expect(result.contains("locked"))
  }

  // MARK: - rollbackFailed case (no numeric code)

  @Test("rollbackFailed reads as restart-and-try-again")
  func rollbackFailedReadsAsRestart() {
    let inner = NSError(
      domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "fake-cleanup-error"])
    let outer = NSError(
      domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "fake-rollback-error"])
    let result = AIPolishKeychainFailureMessage.text(
      for: KeyStoreError.rollbackFailed(cleanup: inner, rollback: outer),
      action: .save
    )
    #expect(result.contains("Restart"))
    #expect(!result.contains("fake-cleanup-error"))  // engineering details not leaked
    #expect(!result.contains("fake-rollback-error"))
  }

  // MARK: - Unknown OSStatus falls back, no numeric leak

  @Test("unknown OSStatus on save falls back to generic save copy")
  func unknownStatusOnSaveFallsBackToGenericSaveCopy() {
    let bogus: OSStatus = -99999
    let result = AIPolishKeychainFailureMessage.text(
      for: KeyStoreError.storeFailed(bogus),
      action: .save
    )
    #expect(result.contains("save"))
    #expect(!result.contains("99999"))
    #expect(!result.contains("-99999"))
  }

  @Test("unknown OSStatus on clear falls back to generic clear copy")
  func unknownStatusOnClearFallsBackToGenericClearCopy() {
    let bogus: OSStatus = -99999
    let result = AIPolishKeychainFailureMessage.text(
      for: KeyStoreError.deleteFailed(bogus),
      action: .clear
    )
    #expect(result.contains("clear"))
    #expect(!result.contains("99999"))
  }

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
