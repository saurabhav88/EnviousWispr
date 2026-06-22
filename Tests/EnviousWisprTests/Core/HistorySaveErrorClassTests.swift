import Foundation
import Testing

@testable import EnviousWisprCore

/// #1167: the history-save error classifier maps storage `Error`s to a
/// normalized, privacy-safe class + user reason shared by the pill and telemetry.
@MainActor
@Suite("HistorySaveErrorClass — classification + reason mapping")
struct HistorySaveErrorClassTests {

  @Test("Cocoa file-write codes map to the right class + reason")
  func cocoaCodesMap() {
    let cases: [(Int, HistorySaveErrorClass, String)] = [
      (NSFileWriteOutOfSpaceError, .fullDisk, "disk is full"),
      (NSFileWriteNoPermissionError, .permissionDenied, "permission denied"),
      (NSFileWriteVolumeReadOnlyError, .readOnly, "the volume is read-only"),
    ]
    for (code, expectedClass, expectedReason) in cases {
      let err = NSError(domain: NSCocoaErrorDomain, code: code)
      let klass = HistorySaveErrorClass(storageError: err)
      #expect(klass == expectedClass, "code \(code) should map to \(expectedClass)")
      #expect(klass.userReason == expectedReason)
    }
  }

  @Test("POSIX errnos map to the right class")
  func posixCodesMap() {
    #expect(
      HistorySaveErrorClass(
        storageError: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))) == .fullDisk)
    #expect(
      HistorySaveErrorClass(
        storageError: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))) == .permissionDenied)
    #expect(
      HistorySaveErrorClass(
        storageError: NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS))) == .readOnly)
  }

  @Test("a Cocoa error wrapping a POSIX errno under NSUnderlyingErrorKey is unwrapped")
  func underlyingPosixErrorUnwrapped() {
    // The FileHandle.write path can surface a generic Cocoa file-write error
    // that carries the real errno as its underlying error (#1167).
    let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
    let wrapper = NSError(
      domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
      userInfo: [NSUnderlyingErrorKey: underlying])
    #expect(HistorySaveErrorClass(storageError: wrapper) == .fullDisk)
  }

  @Test("a bare fileWriteUnknown with no underlying errno falls back to .unknown")
  func cocoaUnknownWithoutUnderlyingIsUnknown() {
    let err = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
    #expect(HistorySaveErrorClass(storageError: err) == .unknown)
  }

  @Test("an unrecognized error falls back to .unknown with a generic reason")
  func unknownFallback() {
    let klass = HistorySaveErrorClass(
      storageError: NSError(domain: "SomethingElse", code: 42))
    #expect(klass == .unknown)
    #expect(klass.userReason == "a storage error")
  }

  @Test("rawValue strings are the telemetry-stable, privacy-safe class names")
  func rawValuesAreStable() {
    #expect(HistorySaveErrorClass.fullDisk.rawValue == "full_disk")
    #expect(HistorySaveErrorClass.permissionDenied.rawValue == "permission_denied")
    #expect(HistorySaveErrorClass.readOnly.rawValue == "read_only")
    #expect(HistorySaveErrorClass.unknown.rawValue == "unknown")
  }
}
