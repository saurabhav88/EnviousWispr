import CryptoKit
import EnviousWisprCore
import Foundation
import OSLog
import Security

// MARK: - Crash-recovery per-session key store (#1063 PR0)
//
// Each recording gets a fresh AES-256 key. The host generates it, persists it
// here (so it SURVIVES a crash — an ephemeral RAM-only key could never decrypt
// the orphan on the next launch), and hands the bytes to the helper over XPC.
// On a clean stop or after recovery the key is destroyed.
//
// Distinct from `KeychainManager` (which stores customer API-key Strings and
// rejects unknown keys): this stores raw 32-byte key Data keyed by
// `recoverySessionID`, in its OWN keychain service.
//
// Two backends, mirroring `KeychainManager`: the signed release app uses the
// data-protection keychain (`keychain-security.md`), while DEBUG, the `.dev`
// bundle, and any unrecognized build use a 0600 file store. The file backend is
// what unsigned `swift test` and the dev bundle exercise (DP-keychain returns
// errSecMissingEntitlement -34018 without the signed entitlement); the
// DP-keychain wire is proven on signed-release Live UAT.
//
// Off-MainActor by construction (`keychain-not-mainactor`): every method is
// synchronous and the host calls them from a background task.
public struct RecoveryKeyStore: Sendable {
  enum Backend: Sendable {
    case file
    case keychain(service: String)
  }

  private static let productionService = "com.enviouswispr.app.recovery-keys"
  private static let logger = Logger(subsystem: "com.enviouswispr.app", category: "RecoveryKey")

  private let backend: Backend
  private let fileDirectory: URL

  public init() {
    let directory = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".enviouswispr-recovery-keys", isDirectory: true)
    if Self.usesFileBackendForDefaultRuntime {
      self.init(backend: .file, fileDirectory: directory)
    } else {
      self.init(backend: .keychain(service: Self.productionService), fileDirectory: directory)
    }
  }

  init(backend: Backend, fileDirectory: URL) {
    self.backend = backend
    self.fileDirectory = fileDirectory
  }

  /// Generate a fresh 256-bit key.
  public static func makeKey() -> Data {
    SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
  }

  public func store(keyData: Data, for recoverySessionID: String) throws {
    switch backend {
    case .file:
      try fileStore(keyData, account: recoverySessionID)
    case .keychain(let service):
      try keychainStore(keyData, service: service, account: recoverySessionID)
    }
  }

  public func retrieve(for recoverySessionID: String) throws -> Data {
    #if DEBUG
      if let status = DebugRecoveryKeyFaultController.shared.consumeArmedStatus(
        forSessionID: recoverySessionID)
      {
        throw RecoveryKeyStoreError.retrieveFailed(status)
      }
    #endif
    switch backend {
    case .file:
      return try fileRetrieve(account: recoverySessionID)
    case .keychain(let service):
      return try keychainRetrieve(service: service, account: recoverySessionID)
    }
  }

  /// Destroy a session key. Idempotent — a missing key is success.
  public func delete(for recoverySessionID: String) throws {
    switch backend {
    case .file:
      try fileDelete(account: recoverySessionID)
    case .keychain(let service):
      try keychainDelete(service: service, account: recoverySessionID)
    }
  }

  /// Every `recoverySessionID` that currently has a stored key. Lets the launch
  /// purge sweep ORPHAN keys (a key with no spool — e.g. a recording that armed
  /// then aborted before any frame was written), which a spool-only scan misses.
  /// Best-effort: an enumeration failure returns an empty list (the caller is a
  /// purge — failing closed there just defers cleanup to the next launch).
  public func listAccountIDs() -> [String] {
    switch backend {
    case .file:
      return fileListAccounts()
    case .keychain(let service):
      return keychainListAccounts(service: service)
    }
  }

  // MARK: Data-protection keychain backend

  private func baseQuery(service: String, account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
      kSecUseDataProtectionKeychain as String: kCFBooleanTrue as Any,
    ]
  }

  private func keychainStore(_ data: Data, service: String, account: String) throws {
    let query = baseQuery(service: service, account: account)
    let updateStatus = SecItemUpdate(
      query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    switch updateStatus {
    case errSecSuccess:
      return
    case errSecItemNotFound:
      var addQuery = query
      addQuery[kSecValueData as String] = data
      addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
      switch addStatus {
      case errSecSuccess:
        return
      case errSecDuplicateItem:
        // Lost an add/add race; the item now exists — overwrite it.
        let retry = SecItemUpdate(
          query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard retry == errSecSuccess else { throw RecoveryKeyStoreError.storeFailed(retry) }
      case errSecInteractionNotAllowed:
        throw RecoveryKeyStoreError.storeFailed(addStatus)
      default:
        throw RecoveryKeyStoreError.storeFailed(addStatus)
      }
    case errSecInteractionNotAllowed:
      throw RecoveryKeyStoreError.storeFailed(updateStatus)
    default:
      throw RecoveryKeyStoreError.storeFailed(updateStatus)
    }
  }

  private func keychainRetrieve(service: String, account: String) throws -> Data {
    var query = baseQuery(service: service, account: account)
    query[kSecReturnData as String] = kCFBooleanTrue
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      guard let data = result as? Data else { throw RecoveryKeyStoreError.invalidData }
      return data
    case errSecItemNotFound:
      throw RecoveryKeyStoreError.notFound
    case errSecInteractionNotAllowed:
      throw RecoveryKeyStoreError.retrieveFailed(status)
    default:
      throw RecoveryKeyStoreError.retrieveFailed(status)
    }
  }

  private func keychainDelete(service: String, account: String) throws {
    let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    switch status {
    case errSecSuccess, errSecItemNotFound:
      return
    case errSecInteractionNotAllowed:
      throw RecoveryKeyStoreError.deleteFailed(status)
    default:
      throw RecoveryKeyStoreError.deleteFailed(status)
    }
  }

  private func keychainListAccounts(service: String) -> [String] {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecUseDataProtectionKeychain as String: kCFBooleanTrue as Any,
      kSecReturnAttributes as String: kCFBooleanTrue as Any,
      kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
    return items.compactMap { $0[kSecAttrAccount as String] as? String }
  }

  // MARK: File backend (DEBUG / dev / unrecognized build)

  private func fileURL(for account: String) -> URL {
    // recoverySessionID is a UUID string; keep it filesystem-safe regardless.
    let safe = account.replacingOccurrences(of: "/", with: "_")
    return fileDirectory.appendingPathComponent(safe)
  }

  private func ensureFileDirectory() throws {
    let fm = FileManager.default
    if !fm.fileExists(atPath: fileDirectory.path) {
      try fm.createDirectory(at: fileDirectory, withIntermediateDirectories: true)
    }
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fileDirectory.path)
  }

  private func fileStore(_ data: Data, account: String) throws {
    try ensureFileDirectory()
    let url = fileURL(for: account)
    let tmpURL = fileDirectory.appendingPathComponent(".\(account).tmp")
    let fm = FileManager.default
    do {
      let fd = Foundation.open(tmpURL.path, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
      guard fd >= 0 else { throw RecoveryKeyStoreError.storeFailed(errSecIO) }
      let fh = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      try fh.write(contentsOf: data)
      try fh.close()
      if fm.fileExists(atPath: url.path) {
        _ = try fm.replaceItemAt(url, withItemAt: tmpURL)
      } else {
        try fm.moveItem(at: tmpURL, to: url)
      }
    } catch {
      try? fm.removeItem(at: tmpURL)
      throw RecoveryKeyStoreError.storeFailed(errSecIO)
    }
  }

  private func fileRetrieve(account: String) throws -> Data {
    let url = fileURL(for: account)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw RecoveryKeyStoreError.notFound
    }
    do {
      return try Data(contentsOf: url)
    } catch {
      throw RecoveryKeyStoreError.retrieveFailed(errSecIO)
    }
  }

  private func fileDelete(account: String) throws {
    let url = fileURL(for: account)
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else { return }
    do {
      try fm.removeItem(at: url)
    } catch {
      throw RecoveryKeyStoreError.deleteFailed(errSecIO)
    }
  }

  private func fileListAccounts() -> [String] {
    let fm = FileManager.default
    guard
      let entries = try? fm.contentsOfDirectory(at: fileDirectory, includingPropertiesForKeys: nil)
    else { return [] }
    // Skip dotfiles (the `.{account}.tmp` atomic-write temp + `.metadata*`).
    return entries.map { $0.lastPathComponent }.filter { !$0.hasPrefix(".") }
  }

  // MARK: Backend selection (mirrors KeychainManager — fail closed to file)

  private static let productionKeychainBundleIDs: Set<String> = ["com.enviouswispr.app"]

  private static var usesFileBackendForDefaultRuntime: Bool {
    #if DEBUG
      return true
    #else
      guard let bundleID = Bundle.main.bundleIdentifier else { return true }
      return !productionKeychainBundleIDs.contains(bundleID)
    #endif
  }
}

public enum RecoveryKeyStoreError: Error, Equatable {
  case storeFailed(OSStatus)
  case retrieveFailed(OSStatus)
  case deleteFailed(OSStatus)
  case notFound
  case invalidData
}
