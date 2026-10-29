import EnviousWisprCore
import Foundation

/// A meeting's transcript-commit receipt (#3973 C2, `MeetingTranscriptReplacement`). It sits at
/// the folder root beside `meeting.json`, so Delete audio (segment files and `work/`) keeps it
/// and Delete meeting removes it with the folder.
extension MeetingStore {
  public static let transcriptReplacementFileName = "transcript-replacement.json"

  public enum ReplacementLoad: Sendable {
    case none
    case receipt(MeetingTranscriptReplacement)
    /// Present but not decodable, or another receipt format: kept, never trusted.
    case unusable
  }

  public func transcriptReplacementURL(for id: UUID) -> URL {
    folder(for: id).appendingPathComponent(Self.transcriptReplacementFileName)
  }

  /// Writes the receipt durably (write, `F_FULLFSYNC`, replace, directory sync). Refuses a
  /// meeting whose `meeting.json` is gone, so a late write never recreates a deleted meeting,
  /// and one a newer build wrote.
  public func saveTranscriptReplacement(_ receipt: MeetingTranscriptReplacement) throws {
    let id = receipt.meetingID
    guard FileManager.default.fileExists(atPath: recordURL(for: id).path) else {
      throw StoreError.meetingMissing
    }
    if let header = try? header(id: id), header.formatVersion > MeetingRecord.currentFormatVersion {
      throw StoreError.newerFormat
    }
    try Self.atomicWrite(try Self.encoder.encode(receipt), to: transcriptReplacementURL(for: id))
  }

  public func loadTranscriptReplacement(meeting id: UUID) -> ReplacementLoad {
    let data: Data
    do {
      data = try Data(contentsOf: transcriptReplacementURL(for: id))
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return .none
    } catch {
      return .unusable
    }
    guard
      let receipt = try? Self.decoder.decode(MeetingTranscriptReplacement.self, from: data),
      receipt.formatVersion == MeetingTranscriptReplacement.currentFormatVersion,
      receipt.meetingID == id
    else { return .unusable }
    return .receipt(receipt)
  }

  /// Removes the receipt once its commit is settled. Absent already is success.
  public func clearTranscriptReplacement(meeting id: UUID) throws {
    do {
      try FileManager.default.removeItem(at: transcriptReplacementURL(for: id))
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      return
    }
  }
}
