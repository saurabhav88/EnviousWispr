---
name: validate-keychain-usage
description: "Use when implementing or reviewing KeychainManager, adding new secret storage requirements, or auditing that no raw SecItem APIs are called outside of KeychainManager in EnviousWispr."
---

# Validate Keychain Usage

## KeychainManager Implementation Checklist

File: `Sources/EnviousWispr/LLM/KeychainManager.swift`

### Required attributes for every SecItemAdd call
```swift
var query: [CFString: Any] = [
    kSecClass:            kSecClassGenericPassword,
    kSecAttrService:      "com.enviouswispr.api-keys",
    kSecAttrAccount:      key,                               // e.g. "openai-api-key"
    kSecAttrAccessible:   kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    kSecValueData:        value.data(using: .utf8)!
]
```

### Delete-before-store pattern (prevents errSecDuplicateItem)
```swift
func store(key: String, value: String) {
    delete(key: key)          // must come first
    let query = buildQuery(key: key, value: value)
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
        // log OSStatus, not the value
        return
    }
}
```

### Load implementation
```swift
func retrieve(key: String) -> String? {
    var query: [CFString: Any] = [
        kSecClass:            kSecClassGenericPassword,
        kSecAttrService:      "com.enviouswispr.api-keys",
        kSecAttrAccount:      key,
        kSecReturnData:       true,
        kSecMatchLimit:       kSecMatchLimitOne
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else { return nil }
    return String(data: data, encoding: .utf8)
}
```

### Error handling requirements
- Check `OSStatus` after every `SecItem*` call.
- Log the numeric status code only (e.g., `"Keychain save failed: \(status)"`).
- Never log the key value or the secret being stored.
- Return `nil` / `false` rather than crashing on failure.

## Call-Site Audit

```bash
# All SecItem calls must be inside KeychainManager — zero results expected elsewhere
grep -rn "SecItemAdd\|SecItemCopyMatching\|SecItemUpdate\|SecItemDelete" \
  Sources/EnviousWispr/ | grep -v "KeychainManager"
```

## Accessibility Attribute

`kSecAttrAccessibleWhenUnlockedThisDeviceOnly` is the correct choice because:
- Keys are not needed when the device is locked.
- `ThisDeviceOnly` prevents iCloud Keychain sync (keys are device-bound secrets).

Do not use `kSecAttrAccessibleAlways`, `kSecAttrAccessibleAfterFirstUnlock`, or any variant without `ThisDeviceOnly`.

## Pass Criteria

- Zero raw `SecItem*` calls outside `KeychainManager`.
- Delete-before-store present in `store`.
- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` on all writes.
- OSStatus checked and logged (numeric only) on all operations.
