import Foundation
import Testing

@testable import EnviousWisprASR

@Suite("WhisperKitBackend partial-download guard (issue #329)")
struct WhisperKitBackendArtifactsTests {

  private func makeTempModelFolder() -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("whisperkit-329-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  /// Create a complete artifact (dir + inner `coremldata.bin` marker).
  private func createArtifact(_ name: String, in folder: URL, complete: Bool = true) {
    let path = folder.appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    if complete {
      let marker = path.appendingPathComponent(WhisperKitBackend.artifactCompletionMarker)
      FileManager.default.createFile(atPath: marker.path, contents: Data())
    }
  }

  @Test("All four required artifacts complete → returns true")
  func allFourComplete() {
    let folder = makeTempModelFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in WhisperKitBackend.requiredArtifacts {
      createArtifact(name, in: folder, complete: true)
    }
    #expect(WhisperKitBackend.hasRequiredArtifacts(at: folder.path) == true)
  }

  @Test("Any single artifact directory missing entirely → returns false")
  func partialDownloadOuterMissing() {
    for missing in WhisperKitBackend.requiredArtifacts {
      let folder = makeTempModelFolder()
      defer { try? FileManager.default.removeItem(at: folder) }
      for name in WhisperKitBackend.requiredArtifacts where name != missing {
        createArtifact(name, in: folder, complete: true)
      }
      #expect(
        WhisperKitBackend.hasRequiredArtifacts(at: folder.path) == false,
        "Expected false when \(missing) is absent")
    }
  }

  @Test("Outer artifact dirs present but inner coremldata.bin missing → returns false")
  func partialDownloadInnerMissing() {
    // Simulates mid-download interrupt where HF created the .mlmodelc dirs but
    // hadn't yet written their inner files.
    for halfBaked in WhisperKitBackend.requiredArtifacts {
      let folder = makeTempModelFolder()
      defer { try? FileManager.default.removeItem(at: folder) }
      for name in WhisperKitBackend.requiredArtifacts {
        createArtifact(name, in: folder, complete: name != halfBaked)
      }
      #expect(
        WhisperKitBackend.hasRequiredArtifacts(at: folder.path) == false,
        "Expected false when \(halfBaked) is an empty shell (coremldata.bin missing)")
    }
  }

  @Test("Empty folder → returns false")
  func emptyFolder() {
    let folder = makeTempModelFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(WhisperKitBackend.hasRequiredArtifacts(at: folder.path) == false)
  }

  @Test("Non-existent folder → returns false (does not throw)")
  func nonexistentFolder() {
    let ghost = FileManager.default.temporaryDirectory
      .appendingPathComponent("whisperkit-329-nonexistent-\(UUID().uuidString)").path
    #expect(WhisperKitBackend.hasRequiredArtifacts(at: ghost) == false)
  }

  @Test("Required artifact list matches WhisperKit.loadModels hard-required set")
  func requiredArtifactsCoverage() {
    // WhisperKit.swift:372-381 only throws when these three are missing;
    // TextDecoderContextPrefill is loaded conditionally and must NOT be
    // in the required set (would over-reject otherwise-valid caches).
    let expected: Set<String> = [
      "AudioEncoder.mlmodelc",
      "MelSpectrogram.mlmodelc",
      "TextDecoder.mlmodelc",
    ]
    #expect(Set(WhisperKitBackend.requiredArtifacts) == expected)
  }

  @Test("Prefill artifact absent is acceptable (matches WhisperKit contract)")
  func prefillOptional() {
    let folder = makeTempModelFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in WhisperKitBackend.requiredArtifacts {
      createArtifact(name, in: folder, complete: true)
    }
    // Do NOT create TextDecoderContextPrefill.mlmodelc. Upstream tolerates.
    #expect(WhisperKitBackend.hasRequiredArtifacts(at: folder.path) == true)
  }
}
