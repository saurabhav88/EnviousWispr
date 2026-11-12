import CryptoKit
import EnviousWisprCore
import Foundation
import os

/// The public half of a key that signs Setup rules (#4528 plan §3.2). Production pins one key;
/// tests declare their own throwaway key type, so no runtime switch can replace the pinned key.
package protocol SetupRulesSigningKey: Sendable {
  /// The Ed25519 public key: 32 raw bytes, standard base64.
  static var publicKeyBase64: String { get }
}

/// The key that signs the published `setup-rules.json` (private half in Secret Manager as
/// `setup-rules-signing-key`; signing tool `scripts/setup-rules/sign.py`).
package enum PinnedSetupRulesKey: SetupRulesSigningKey {
  package static let publicKeyBase64 = SetupRulesSignature.pinnedPublicKeyBase64
}

/// How a Setup rules signature is encoded, shared by the app and the signing tool.
///
/// - The signature is Ed25519 (CryptoKit `Curve25519.Signing`) over the EXACT bytes of the
///   published `setup-rules.json`, never over re-encoded JSON.
/// - `setup-rules.json.sig` holds the 64-byte signature as standard base64 text (trailing
///   whitespace ignored).
/// - The public key is the 32 raw bytes, standard base64.
package enum SetupRulesSignature {
  /// The production public key (founder-created 2026-11-12; private half in Secret Manager as
  /// `setup-rules-signing-key`, derived with `sign.py public-key` through `get-key launch`).
  package static let pinnedPublicKeyBase64 = "jRkec6xbPEc82+HCe/G9wJBvRgW7YQRE7J1FQOTJ5ZA="

  package enum Failure: Error, Equatable {
    case badPublicKey
    case badSignatureEncoding
    case signatureMismatch
  }

  /// Verifies `signatureText` (base64) over `payload` with `publicKeyBase64`.
  package static func verify(payload: Data, signatureText: Data, publicKeyBase64: String) throws {
    guard let keyBytes = Data(base64Encoded: publicKeyBase64), keyBytes.count == 32,
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
    else { throw Failure.badPublicKey }
    let text = String(decoding: signatureText, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let signature = Data(base64Encoded: text), signature.count == 64 else {
      throw Failure.badSignatureEncoding
    }
    guard key.isValidSignature(signature, for: payload) else { throw Failure.signatureMismatch }
  }
}

/// The Setup rules as a remote rules document (#4528 plan §3.2, M1): the bundled copy is trusted
/// as shipped; a download or a cached copy is trusted only with a valid signature from `Key`.
package struct SignedSetupRules<Key: SetupRulesSigningKey>: RemoteRulesDocument {
  package let rules: SetupRules
  package let origin: RemoteRulesOrigin
  /// For a validated download: payload and signature as one cache unit.
  package let cacheData: Data?

  package var revision: Int { rules.revision }

  package static var endpoint: URL { SetupRulesEndpoints.rules }
  package static var signatureEndpoint: URL? { SetupRulesEndpoints.signature }
  package static var cacheFileName: String { "setup-rules-signed.json" }
  package static var attemptFileName: String { "setup-rules-attempt.json" }
  /// Rules are a few kilobytes; 64 KB leaves room without allowing anything large.
  package static var maximumBytes: Int { 64 * 1024 }
  /// 64 bytes as base64 is 88 characters; the cap allows a trailing newline.
  package static var maximumSignatureBytes: Int { 256 }
  /// The cache unit holds the payload as base64 (4/3 larger) plus the signature and a few bytes of
  /// JSON, so a payload at `maximumBytes` must still read back after a relaunch.
  package static var maximumCacheBytes: Int { (maximumBytes * 4) / 3 + 4 * 1024 }
  package static var bundledURL: URL? {
    Bundle.module.url(forResource: "setup-rules", withExtension: "json")
  }
  /// Neither the bundle nor the cache held valid rules: B1's compiled copy.
  package static var empty: SignedSetupRules {
    SignedSetupRules(rules: .builtIn, origin: .empty, cacheData: nil)
  }

  private init(rules: SetupRules, origin: RemoteRulesOrigin, cacheData: Data?) {
    self.rules = rules
    self.origin = origin
    self.cacheData = cacheData
  }

  /// The bundled copy is plain rules (signed with the app). A cached copy is a cache unit whose
  /// signature is checked again on every read.
  package init(validating data: Data, origin: RemoteRulesOrigin) throws {
    switch origin {
    case .bundled, .empty:
      self.init(rules: try SetupRules.validated(from: data), origin: origin, cacheData: nil)
    case .cached, .downloaded:
      let unit = try SetupRulesCacheUnit.decode(data)
      try self.init(validating: unit.payload, signature: unit.signature, origin: origin)
    }
  }

  /// A download: verify the signature over the exact payload bytes, then validate the rules.
  package init(validating data: Data, signature: Data?, origin: RemoteRulesOrigin) throws {
    guard origin == .downloaded || origin == .cached else {
      try self.init(validating: data, origin: origin)
      return
    }
    guard let signature else { throw SetupRulesSignature.Failure.badSignatureEncoding }
    try SetupRulesSignature.verify(
      payload: data, signatureText: signature, publicKeyBase64: Key.publicKeyBase64)
    let rules = try SetupRules.validated(from: data)
    self.init(
      rules: rules, origin: origin,
      cacheData: try SetupRulesCacheUnit(payload: data, signature: signature).encoded())
  }
}

/// The published addresses (plan §3.2).
package enum SetupRulesEndpoints {
  // swiftlint:disable force_unwrapping
  package static let rules = URL(string: "https://enviouswispr.com/setup-rules.json")!
  package static let signature = URL(string: "https://enviouswispr.com/setup-rules.json.sig")!
  // swiftlint:enable force_unwrapping
}

/// Payload and signature kept together as one cache file, so a reader can never pair one
/// download's payload with another's signature. JSON with base64 fields.
package struct SetupRulesCacheUnit: Codable, Equatable, Sendable {
  package let format: Int
  package let payload: Data
  package let signature: Data

  package init(payload: Data, signature: Data) {
    self.format = 1
    self.payload = payload
    self.signature = signature
  }

  package func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(self)
  }

  package static func decode(_ data: Data) throws -> SetupRulesCacheUnit {
    let unit = try JSONDecoder().decode(SetupRulesCacheUnit.self, from: data)
    guard unit.format == 1 else { throw SetupRules.ValidationError.unsupportedSchema(unit.format) }
    return unit
  }
}

/// The app's Setup rules store (#4528): the best trusted rules on this Mac, refreshed at most once
/// a day from enviouswispr.com. Offline it answers at once from the higher of the bundled copy and
/// the last good signed download, then B1's compiled copy.
package enum SetupRulesStore {
  package static let live = RemoteRulesStore<SignedSetupRules<PinnedSetupRulesKey>>.live(
    directoryName: "SetupRules")
  /// The rules in force for the app's synchronous readers (`SetupAdvice`).
  package static let inForce = SetupRulesHolder(store: live)
}

/// The Setup rules document in force for synchronous readers (#4528 B2, plan §3.2). Recommendation
/// reads happen on the main actor and at launch, before any async work, so they cannot ask the
/// store actor. The holder seeds once from the store's own local selection (the higher of the
/// bundled copy and the last good signed download, re-verified on that read) and afterwards
/// answers from memory. It only ever moves to a store result with a strictly higher revision, so
/// rules, revision and origin always change together.
package final class SetupRulesHolder<Key: SetupRulesSigningKey>: Sendable {
  private let store: RemoteRulesStore<SignedSetupRules<Key>>
  private let held = OSAllocatedUnfairLock<SignedSetupRules<Key>?>(initialState: nil)

  package init(store: RemoteRulesStore<SignedSetupRules<Key>>) {
    self.store = store
  }

  /// The document in force. The first read loads the local copies; later reads use memory.
  package var document: SignedSetupRules<Key> {
    held.withLock { held in
      if let held { return held }
      let seeded = store.trustedLocalDocument()
      held = seeded
      return seeded
    }
  }

  /// Runs the store's daily refresh over the document in force (its floor), and moves to the
  /// answer when that is newer. A failed or refused refresh answers with the store's baseline,
  /// which is never below the document in force.
  package func refreshIfDue() async {
    adopt(await store.refreshIfDue(floor: document))
  }

  /// Only a store result reaches here: a `SignedSetupRules` exists only as validated bundled
  /// rules, a signature-verified download or cache, or the compiled fallback.
  private func adopt(_ candidate: SignedSetupRules<Key>) {
    held.withLock { held in
      let current = held ?? store.trustedLocalDocument()
      held = candidate.revision > current.revision ? candidate : current
    }
  }
}

extension SignedSetupRules {
  /// Why the rules in force came from where they did, for later telemetry: a bounded label.
  package var loadReason: String {
    switch origin {
    case .bundled: "bundled"
    case .cached: "cached"
    case .downloaded: "downloaded"
    case .empty: "built_in"
    }
  }
}
