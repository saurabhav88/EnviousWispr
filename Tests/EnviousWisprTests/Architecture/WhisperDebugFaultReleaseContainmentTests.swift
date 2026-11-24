import Foundation
import Testing

@testable import EnviousWisprAppKit
@testable import EnviousWisprPipeline

/// #4896 release containment check: the DEBUG-only `fail_whisper_backend` fault-injection command
/// and its Whisper status-8 helper symbols must never exist in a Release `.app` bundle.
/// Package-only SwiftPM Release runs (`SWIFT_PACKAGE`) build no `.app` bundle, so only Xcode Release
/// app builds compile the unconditional `.app` artifact scan.
#if DEBUG || !SWIFT_PACKAGE
  @Suite("Whisper debug fault release containment (#4896)", .tags(.productOutcome))
  struct WhisperDebugFaultReleaseContainmentTests {

  private final class BundleAnchor {}

  static let forbidden: [String] = [
    "fail_whisper_backend",
    "failWhisperBackendStatus8",
    "shouldForceWhisperStatus8",
    "whisperStatus8Remaining",
  ]

  /// Current build's `EnviousWispr.app` next to the running test bundle (honors custom
  /// `DERIVED_DATA_PATH` and never falls back to stale directories).
  static func currentBuildAppBundle() -> URL? {
    if Bundle.main.bundleURL.pathExtension == "app" {
      return Bundle.main.bundleURL
    }
    let productsDir = Bundle(for: BundleAnchor.self).bundleURL.deletingLastPathComponent()
    let candidate = productsDir.appendingPathComponent("EnviousWispr.app")
    let executable = candidate.appendingPathComponent("Contents/MacOS/EnviousWispr")
    return FileManager.default.fileExists(atPath: executable.path) ? candidate : nil
  }

  private static func scanTargets(in appBundle: URL) -> [URL] {
    var targets = [appBundle.appendingPathComponent("Contents/MacOS/EnviousWispr")]
    let frameworks = appBundle.appendingPathComponent("Contents/Frameworks")
    if let enumerator = FileManager.default.enumerator(
      at: frameworks,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ) {
      for case let url as URL in enumerator {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        if values?.isRegularFile == true, values?.isSymbolicLink != true {
          targets.append(url)
        }
      }
    }
    return targets
  }

  #if DEBUG
    @Test("DEBUG build exercises the status-8 fault controller")
    @MainActor
    func debugBuildProvidesStatus8FaultController() {
      let controller = BatchDecodeFaultController(whisperBackend: nil, asrManager: nil)
      controller.failWhisperBackendStatus8(count: 1)
      #expect(controller.shouldForceWhisperStatus8() == true)
      #expect(controller.shouldForceWhisperStatus8() == false)
    }
  #else
    @Test(
      "the DEBUG-only fail_whisper_backend strings are absent from the current Release app executable and Frameworks"
    )
    func releaseArtifactCarriesNoWhisperFaultSeam() throws {
      let bundle = try #require(
        Self.currentBuildAppBundle(),
        "Release EnviousWispr.app not found beside the current test bundle")
      let targets = Self.scanTargets(in: bundle)
      #expect(!targets.isEmpty)

      for fileURL in targets {
        let data = try Data(contentsOf: fileURL)
        for needle in Self.forbidden {
          #expect(
            !data.contains(Array(needle.utf8)),
            "\(fileURL.path) contains \"\(needle)\" — DEBUG fault seam leaked into Release")
        }
      }
    }
  #endif
}
#endif

extension Data {
  fileprivate func contains(_ pattern: [UInt8]) -> Bool {
    guard !pattern.isEmpty, count >= pattern.count else { return false }
    return withUnsafeBytes { raw -> Bool in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
      let limit = count - pattern.count
      var index = 0
      while index <= limit {
        if base[index] == pattern[0] {
          var matched = true
          for offset in 1..<pattern.count where base[index + offset] != pattern[offset] {
            matched = false
            break
          }
          if matched { return true }
        }
        index += 1
      }
      return false
    }
  }
}
