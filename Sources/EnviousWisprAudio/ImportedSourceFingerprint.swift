import AVFoundation
import EnviousWisprCore
import Foundation

/// Reads an imported file's `ImportedSourceIdentity` (#3147 PR3, plan §17 R2): its size, its
/// container duration and its first and last megabyte. Off the main actor. Never writes.
public enum ImportedSourceFingerprint {
  public enum ReadError: Error, Equatable {
    case notRegularFile
    case unreadable
    /// The file changed size while it was read: no stable identity to report.
    case changedWhileReading
  }

  @concurrent
  public static func read(url: URL) async throws -> ImportedSourceIdentity {
    let before = try regularFileSize(url)
    let durationMs = try await durationMilliseconds(url)
    let (head, tail) = try edges(url, size: before)
    guard try regularFileSize(url) == before else { throw ReadError.changedWhileReading }
    return ImportedSourceIdentity.make(
      byteCount: before, durationMs: durationMs, head: head, tail: tail)
  }

  private static func regularFileSize(_ url: URL) throws -> Int64 {
    let values: URLResourceValues
    do {
      values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    } catch {
      throw ReadError.unreadable
    }
    guard values.isRegularFile == true, let size = values.fileSize else {
      throw ReadError.notRegularFile
    }
    return Int64(size)
  }

  private static func durationMilliseconds(_ url: URL) async throws -> Int64 {
    let duration: CMTime
    do {
      duration = try await AVURLAsset(url: url).load(.duration)
    } catch {
      throw ReadError.unreadable
    }
    guard duration.isNumeric, duration.seconds.isFinite, duration.seconds >= 0 else {
      throw ReadError.unreadable
    }
    return Int64((duration.seconds * 1_000).rounded())
  }

  /// The first and last `min(size, 1 MiB)` bytes; a short read is an error, never padding.
  private static func edges(_ url: URL, size: Int64) throws -> (Data, Data) {
    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: url)
    } catch {
      throw ReadError.unreadable
    }
    defer { try? handle.close() }
    let count = Int(min(size, Int64(ImportedSourceIdentity.edgeBytes)))
    do {
      try handle.seek(toOffset: 0)
      let head = try handle.read(upToCount: count) ?? Data()
      try handle.seek(toOffset: UInt64(size - Int64(count)))
      let tail = try handle.read(upToCount: count) ?? Data()
      guard head.count == count, tail.count == count else { throw ReadError.changedWhileReading }
      return (head, tail)
    } catch let error as ReadError {
      throw error
    } catch {
      throw ReadError.unreadable
    }
  }
}
