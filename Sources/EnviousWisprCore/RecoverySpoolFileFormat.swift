import Foundation

// MARK: - Crash-recovery spool file framing (#1063 PR0)
//
// A `.ewrec` file is:
//
//   [magic        : 6 bytes "EWREC1"]
//   [headerLength : UInt32 big-endian]
//   [header JSON  : headerLength bytes]   (RecoverySpoolHeader)
//   [frame][frame]...                     (RecoverySpoolCipher frames)
//
// The header carries provenance + the ENCRYPTED settings block; it is NOT a
// required index. As long as the 10-byte magic+length prefix is intact, frames
// are locatable even if the header JSON itself is unreadable (a damaged or
// undecryptable settings block still yields audio — recovery then replays under
// current settings). Both the helper-side writer and the host-side store share
// this framing, which is why it lives in Core.

/// File-level (not frame-level) framing errors.
public enum RecoverySpoolFileError: Error, Equatable {
  /// The file does not begin with the spool magic — not a spool file.
  case notASpool
  /// The header length prefix is unreadable or claims more bytes than exist.
  case malformedHeader
}

public enum RecoverySpoolFileFormat {
  /// 6-byte format identifier (also encodes the format generation).
  public static let magic = Data("EWREC1".utf8)

  /// Serialize the file's leading bytes: magic + length-prefixed header JSON.
  /// Frames are appended after this by the writer.
  public static func encodeHeader(_ header: RecoverySpoolHeader) throws -> Data {
    let json = try JSONEncoder().encode(header)
    var data = Data(capacity: magic.count + 4 + json.count)
    data.append(magic)
    let length = UInt32(json.count)
    var bigEndian = length.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    data.append(json)
    return data
  }

  /// Locate the frames and (best-effort) decode the header. A readable
  /// magic+length prefix yields `framesOffset` even when the header JSON fails
  /// to decode (in which case `header` is nil and recovery uses current
  /// settings). Throws only when the file is not a spool or the prefix itself
  /// is corrupt.
  public static func decodeHeader(from data: Data) throws -> (
    header: RecoverySpoolHeader?, framesOffset: Int
  ) {
    let base = data.startIndex
    guard data.count >= magic.count + 4 else { throw RecoverySpoolFileError.notASpool }
    guard data.subdata(in: base..<base + magic.count) == magic else {
      throw RecoverySpoolFileError.notASpool
    }

    let lengthStart = base + magic.count
    var headerLength: UInt32 = 0
    for offset in 0..<4 {
      headerLength = (headerLength << 8) | UInt32(data[lengthStart + offset])
    }

    let jsonStart = lengthStart + 4
    let framesOffset = magic.count + 4 + Int(headerLength)
    guard jsonStart + Int(headerLength) <= data.endIndex else {
      throw RecoverySpoolFileError.malformedHeader
    }

    let json = data.subdata(in: jsonStart..<jsonStart + Int(headerLength))
    let header = try? JSONDecoder().decode(RecoverySpoolHeader.self, from: json)
    return (header, framesOffset)
  }
}
