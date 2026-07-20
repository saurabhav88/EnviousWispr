#!/usr/bin/env swift

// keychain-verify.swift — Issue #845 UAT helper.
//
// Probes both the macOS Data Protection keychain (DP-scoped query) AND the
// legacy file-based macOS keychain (legacy-scoped query) for EnviousWispr's
// customer API key items. Reports which backend currently holds each item.
//
// Why a Swift CLI and not the `security` shell tool: per Apple TN3137
// ("On Mac keychains"), the `security` tool is primarily file-keychain
// focused and does not reliably distinguish DP-keychain items from
// legacy-keychain items. A direct SecItemCopyMatching call with explicit
// `kSecUseDataProtectionKeychain` is the only reliable probe.
//
// Usage (interactive, founder-driven):
//   swift scripts/uat/keychain-verify.swift                  # check all three keys
//   swift scripts/uat/keychain-verify.swift openai-api-key   # check just one
//
// Output is JSON for easy capture into .validation/runs/<id>/keychain-verify-*.json.

import Foundation
import Security

let productionService = "com.enviouswispr.app.api-keys"
let defaultAccounts = ["openai-api-key", "gemini-api-key", "claude-api-key"]

struct AccountResult: Encodable {
  let account: String
  let dpBackend: String
  let legacyBackend: String
  let interpretation: String
}

struct Output: Encodable {
  let service: String
  let timestamp: String
  let results: [AccountResult]
}

func statusString(_ status: OSStatus) -> String {
  switch status {
  case errSecSuccess: return "errSecSuccess"
  case errSecItemNotFound: return "errSecItemNotFound"
  case errSecMissingEntitlement: return "errSecMissingEntitlement"
  case errSecAuthFailed: return "errSecAuthFailed"
  case errSecInteractionNotAllowed: return "errSecInteractionNotAllowed"
  default: return "OSStatus(\(status))"
  }
}

func probe(service: String, account: String, dataProtection: Bool) -> OSStatus {
  var query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: service,
    kSecAttrAccount as String: account,
    kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
    kSecMatchLimit as String: kSecMatchLimitOne,
  ]
  if dataProtection {
    query[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue
  }
  var result: CFTypeRef?
  return SecItemCopyMatching(query as CFDictionary, &result)
}

func interpret(dpStatus: OSStatus, legacyStatus: OSStatus) -> String {
  switch (dpStatus, legacyStatus) {
  case (errSecSuccess, errSecItemNotFound):
    return "OK: key lives only in Data Protection keychain (post-#845 state, no orphan)"
  case (errSecSuccess, errSecSuccess):
    return
      "OK with orphan: key in DP backend (production reads this), legacy backend also has an item (v2.0.2/v2.0.3 orphan); cleaned next time user clears the key in Settings"
  case (errSecItemNotFound, errSecSuccess):
    return
      "PRE-FIX or PRE-PASTE: key only in legacy backend; production code (post-#845) will NOT see it. Either this is a v2.0.2/v2.0.3 install that has not been upgraded, OR the user has not re-pasted on the fixed build yet."
  case (errSecItemNotFound, errSecItemNotFound):
    return "EMPTY: no key in either backend. Fresh install or fully cleared."
  case (errSecMissingEntitlement, _), (_, errSecMissingEntitlement):
    return
      "ENTITLEMENT MISSING: this Swift CLI cannot read the keychain — run it via a signed wrapper or from inside a signed app context. Try running against a signed EnviousWispr.app instead of via raw `swift scripts/uat/...`."
  default:
    return "UNEXPECTED: dp=\(statusString(dpStatus)) legacy=\(statusString(legacyStatus))"
  }
}

let args = CommandLine.arguments.dropFirst()
let accountsToCheck = args.isEmpty ? defaultAccounts : Array(args)

var results: [AccountResult] = []
for account in accountsToCheck {
  let dpStatus = probe(service: productionService, account: account, dataProtection: true)
  let legacyStatus = probe(service: productionService, account: account, dataProtection: false)
  results.append(
    AccountResult(
      account: account,
      dpBackend: statusString(dpStatus),
      legacyBackend: statusString(legacyStatus),
      interpretation: interpret(dpStatus: dpStatus, legacyStatus: legacyStatus)
    ))
}

let output = Output(
  service: productionService,
  timestamp: ISO8601DateFormatter().string(from: Date()),
  results: results
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let data = try encoder.encode(output)
print(String(data: data, encoding: .utf8)!)
