import CryptoKit
import Foundation
import Testing

@testable import EnviousWisprLLM

/// Build-time integrity gates for the shipped classifier artifacts. These lock
/// the committed model + tokenizer + contract so an accidental swap (or a Swift
/// canonicalization that diverges from the Python generator) fails CI rather
/// than silently disabling the classifier at runtime.
@Suite struct OutputClassifierContractTests {

  @Test(
    "Swift contract-hash recompute matches the shipped contractHash (Swift↔Python canonical parity)"
  )
  func recomputeMatchesStored() throws {
    let recomputed = try TokenizerContract.recomputeContractHash(
      contractURL: OutputClassifierTestPaths.contract,
      tokenizerJSONURL: OutputClassifierTestPaths.tokenizerJSON,
      tokenizerConfigURL: OutputClassifierTestPaths.tokenizerConfig)
    let contract = try TokenizerContract.load(from: OutputClassifierTestPaths.contract)
    #expect(recomputed == contract.contractHash)
    #expect(recomputed == OutputClassifierManifest.tokenizerContractSHA256)
  }

  @Test("verify() succeeds on the shipped artifacts")
  func verifySucceeds() throws {
    let digest = try TokenizerContract.verify(
      contractURL: OutputClassifierTestPaths.contract,
      tokenizerJSONURL: OutputClassifierTestPaths.tokenizerJSON,
      tokenizerConfigURL: OutputClassifierTestPaths.tokenizerConfig)
    #expect(digest == OutputClassifierManifest.tokenizerContractSHA256)
  }

  @Test("a tampered contract fails verification (mismatch disables ⇒ fail open)")
  func tamperedContractFailsVerify() throws {
    // Copy the real contract, mutate a field, point the verifier at the copy.
    let temp = FileManager.default.temporaryDirectory.appending(
      path: "tampered-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: temp) }
    let original = try Data(contentsOf: OutputClassifierTestPaths.contract)
    var object = try JSONSerialization.jsonObject(with: original) as! [String: Any]
    object["maxLength"] = 256  // any change to a hashed field
    let mutated = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try mutated.write(to: temp)

    #expect(throws: OutputClassifierError.self) {
      try TokenizerContract.verify(
        contractURL: temp,
        tokenizerJSONURL: OutputClassifierTestPaths.tokenizerJSON,
        tokenizerConfigURL: OutputClassifierTestPaths.tokenizerConfig)
    }
  }

  @Test("a tampered tokenizer file fails verification")
  func tamperedTokenizerFailsVerify() throws {
    let tempTok = FileManager.default.temporaryDirectory.appending(
      path: "tok-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tempTok) }
    var bytes = try Data(contentsOf: OutputClassifierTestPaths.tokenizerJSON)
    bytes.append(0x20)  // one extra byte changes the digest
    try bytes.write(to: tempTok)

    #expect(throws: OutputClassifierError.self) {
      try TokenizerContract.verify(
        contractURL: OutputClassifierTestPaths.contract,
        tokenizerJSONURL: tempTok,
        tokenizerConfigURL: OutputClassifierTestPaths.tokenizerConfig)
    }
  }

  @Test("committed .mlpackage combined SHA matches the manifest constant")
  func mlpackageDigestMatchesManifest() throws {
    let pkg = OutputClassifierTestPaths.mlpackage
    let enumerator = FileManager.default.enumerator(
      at: pkg, includingPropertiesForKeys: [.isRegularFileKey])
    var lines: [String] = []
    while let url = enumerator?.nextObject() as? URL {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey])
      guard values.isRegularFile == true else { continue }
      let rel = url.path.replacingOccurrences(of: pkg.path + "/", with: "")
      let fileDigest = SHA256.hash(data: try Data(contentsOf: url))
        .map { String(format: "%02x", $0) }.joined()
      lines.append("\(rel) \(fileDigest)")
    }
    lines.sort()
    let combined = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8))
      .map { String(format: "%02x", $0) }.joined()
    #expect(combined == OutputClassifierManifest.mlpackageSHA256)
  }
}
