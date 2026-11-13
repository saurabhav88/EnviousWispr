import AVFoundation
import EnviousWisprAppKitTestSupport
import EnviousWisprAudio
import EnviousWisprCore
import Foundation
import Testing

/// Reading an imported file's identity (#3147 PR3): the real file's size and duration, the
/// same answer twice, a different answer after one byte changes, and a refusal for something
/// that is not a regular file. The reader never writes.
/// Class: `.productOutcome` — whether History refuses a different file at the original's path.
@Suite("Imported source fingerprint reader (#3147 PR3)", .tags(.productOutcome))
struct ImportedSourceFingerprintTests {

  /// Half a second of 16 kHz mono silence written as a WAV file.
  private func writeClip() throws -> URL {
    let url = TestTemporaryDirectory.url
      .appendingPathComponent("ew-3147-fp-\(UUID().uuidString).wav")
    let format = try #require(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
    buffer.frameLength = 8_000
    try file.write(from: buffer)
    return url
  }

  @Test("a real file's identity: its size, its duration, the same twice, different after one byte")
  func readsStableIdentity() async throws {
    let url = try writeClip()
    defer { try? FileManager.default.removeItem(at: url) }
    let size = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    let before = try Data(contentsOf: url)

    let first = try await ImportedSourceFingerprint.read(url: url)
    let second = try await ImportedSourceFingerprint.read(url: url)
    #expect(first == second)
    #expect(first.byteCount == Int64(size))
    #expect(abs(first.durationMs - 500) <= 5, "\(first.durationMs) ms")
    #expect(try Data(contentsOf: url) == before, "reading never writes")

    var bytes = before
    bytes[bytes.count - 1] ^= 0xFF
    try bytes.write(to: url)
    let changed = try await ImportedSourceFingerprint.read(url: url)
    #expect(changed.digest != first.digest)
  }

  @Test("a folder is not a source file")
  func refusesDirectory() async {
    await #expect(throws: ImportedSourceFingerprint.ReadError.notRegularFile) {
      _ = try await ImportedSourceFingerprint.read(url: TestTemporaryDirectory.url)
    }
  }
}
