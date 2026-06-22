import Foundation

/// #1167: normalized classification of a history-save failure
/// (`TranscriptStore.save` throwing on a full disk / unwritable volume).
///
/// Lives in Core so the user-facing pill and the `dictation.completed`
/// telemetry derive the SAME class from one place — no raw error strings or
/// filesystem paths cross the telemetry-privacy boundary. The save is
/// best-effort: a throw is recorded as one of these classes, delivery still
/// proceeds, and the crash-recovery spool self-heals History on next launch.
public enum HistorySaveErrorClass: String, Sendable {
  case fullDisk = "full_disk"
  case permissionDenied = "permission_denied"
  case readOnly = "read_only"
  case unknown = "unknown"

  /// Map a storage `Error` to a normalized class. `TranscriptStore.save` can
  /// surface the failure three ways: a raw POSIX errno (the `open` temp-file
  /// guard, #1167), a Cocoa file-write error with a specific code, or a Cocoa
  /// error that wraps the real errno under `NSUnderlyingErrorKey` (the
  /// `FileHandle.write` path). Check the top-level error, then its underlying.
  public init(storageError: Error) {
    let ns = storageError as NSError
    if let cls = Self.classify(ns) {
      self = cls
      return
    }
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
      let cls = Self.classify(underlying)
    {
      self = cls
      return
    }
    self = .unknown
  }

  /// Classify a single `NSError` by domain + code; `nil` when it carries no
  /// recognizable storage failure (so the caller can fall through to the
  /// underlying error or `.unknown`).
  private static func classify(_ ns: NSError) -> HistorySaveErrorClass? {
    switch ns.domain {
    case NSCocoaErrorDomain:
      switch ns.code {
      case NSFileWriteOutOfSpaceError: return .fullDisk
      case NSFileWriteNoPermissionError: return .permissionDenied
      case NSFileWriteVolumeReadOnlyError: return .readOnly
      default: return nil
      }
    case NSPOSIXErrorDomain:
      switch Int32(ns.code) {
      case ENOSPC: return .fullDisk
      case EACCES, EPERM: return .permissionDenied
      case EROFS: return .readOnly
      default: return nil
      }
    default:
      return nil
    }
  }

  /// Privacy-safe, human-readable reason for the user pill — no paths, no
  /// usernames. Rendered as "Couldn't save to history: <userReason>".
  public var userReason: String {
    switch self {
    case .fullDisk: return "disk is full"
    case .permissionDenied: return "permission denied"
    case .readOnly: return "the volume is read-only"
    case .unknown: return "a storage error"
    }
  }
}
