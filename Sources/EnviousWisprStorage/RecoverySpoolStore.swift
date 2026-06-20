import EnviousWisprCore
import Foundation

/// The host-side reader/janitor for crash-recovery audio spools (#1063).
///
/// The helper-side `RecoverySpoolWriter` produces encrypted, append-only
/// `.ewrec` files while recording; this store owns the directory and the
/// read/scan/delete side the host needs on launch: find orphans, reconstruct
/// the valid continuous prefix from a spool, and delete a spool once its
/// transcript is durably saved.
///
/// Privacy posture mirrors `TranscriptStore` (V3 audit #561/#562) and adds
/// backup exclusion: directory 0700, `.metadata_never_index` so Spotlight does
/// not index it, and `isExcludedFromBackup` so spools never land in Time
/// Machine / iCloud backups.
///
/// Not `@MainActor`: decoding a 60-minute spool is ~230 MB of work the caller
/// runs on a background task. Synchronous, `Sendable`, holds only a URL.
public struct RecoverySpoolStore: Sendable {
  private let directory: URL

  public init() {
    directory = AppConstants.appSupportURL
      .appendingPathComponent(RecoveryConstants.spoolDirectoryName, isDirectory: true)
    Self.prepareDirectory(at: directory)
  }

  // Tests inject a private directory. Public so `import EnviousWisprStorage`
  // tests can point the store at a temp dir without `@testable`.
  public init(directory: URL) {
    self.directory = directory
    Self.prepareDirectory(at: directory)
  }

  public var directoryURL: URL { directory }

  /// Absolute path the host hands the helper for a session's spool.
  public func spoolURL(for recoverySessionID: String) -> URL {
    directory.appendingPathComponent("\(recoverySessionID).\(RecoveryConstants.fileExtension)")
  }

  /// The `recoverySessionID`s of every spool file currently on disk.
  public func listSpoolSessionIDs() throws -> [String] {
    let fm = FileManager.default
    guard fm.fileExists(atPath: directory.path) else { return [] }
    let entries = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    return
      entries
      .filter { $0.pathExtension == RecoveryConstants.fileExtension }
      .map { $0.deletingPathExtension().lastPathComponent }
      .sorted()
  }

  /// Read just the provenance header without decoding frames. Returns nil when
  /// the header JSON is unreadable but the file is still a spool (recovery can
  /// then proceed on frames alone). Throws `notASpool` for a non-spool file.
  public func readHeader(for recoverySessionID: String) throws -> RecoverySpoolHeader? {
    let url = spoolURL(for: recoverySessionID)
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    return try RecoverySpoolFileFormat.decodeHeader(from: data).header
  }

  /// Reconstruct the valid continuous prefix of a spool. Walks frames in order,
  /// stopping at the first torn, out-of-sequence, or authentication-failing
  /// frame (the recovered duration is honest about where it stopped). The
  /// `cipher` must carry the session key for an encrypted spool.
  public func recover(recoverySessionID: String, cipher: RecoverySpoolCipher) throws
    -> RecoveredSpool
  {
    let url = spoolURL(for: recoverySessionID)
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    let (header, framesOffset) = try RecoverySpoolFileFormat.decodeHeader(from: data)

    // Fail closed on a cipher-mode mismatch. Decoding an encrypted spool with a
    // `.none` cipher (e.g. after a failed key lookup) would read ciphertext as
    // raw Float32 samples and emit GARBAGE audio instead of refusing. If the
    // header declares a cipher, the caller's cipher must match it before we walk
    // a single frame (Codex PR0 P2).
    if let header, header.cipher != cipher.mode {
      return RecoveredSpool(
        recoverySessionID: recoverySessionID, header: header, settings: nil,
        samples: [], frameCount: 0, terminationReason: nil, truncated: true)
    }

    let settings: RecordingSettingsSnapshot? = {
      guard let encrypted = header?.encryptedSettings else { return nil }
      return try? cipher.openSettings(encrypted)
    }()

    var samples: [Float] = []
    var frameCount = 0
    var expectedChunkIndex: UInt32 = 0
    var expectedStartSample: UInt64 = 0
    var terminationReason: RecoverySpoolTerminationReason?
    // A spool is "complete" ONLY if it ends with a clean-finalize marker. Every
    // other outcome — a non-clean marker, a torn/corrupt/out-of-sequence tail,
    // or EOF with NO marker (the common crash case: the app died before
    // `finalize`) — is truncated, so a recovered take never looks complete when
    // it ended abnormally (Codex PR0 P2).
    var sawCleanFinalize = false
    var offset = framesOffset

    loop: while offset < data.count {
      let decoded: (frame: RecoveryFrame, nextOffset: Int)?
      do {
        decoded = try cipher.decodeFrame(from: data, at: offset)
      } catch {
        // A present-but-corrupt frame ends the valid prefix.
        break loop
      }
      guard let (frame, nextOffset) = decoded else {
        // Torn tail (partial frame): nothing more is trustworthy.
        break loop
      }

      switch frame.kind {
      case .audio:
        // Continuity guard: a gap or reordering ends the prefix.
        guard frame.chunkIndex == expectedChunkIndex, frame.startSample == expectedStartSample
        else { break loop }
        samples.append(contentsOf: frame.samples)
        expectedStartSample += UInt64(frame.sampleCount)
        expectedChunkIndex += 1
        frameCount += 1
      case .marker:
        // Continuity guard (same as audio): a marker reached after a gap or
        // reorder is NOT a clean ending.
        guard frame.chunkIndex == expectedChunkIndex, frame.startSample == expectedStartSample
        else { break loop }
        terminationReason = frame.terminationReason
        sawCleanFinalize = frame.terminationReason == .cleanFinalized
        // A marker is terminal; anything after it is ignored.
        break loop
      }
      offset = nextOffset
    }

    return RecoveredSpool(
      recoverySessionID: recoverySessionID,
      header: header,
      settings: settings,
      samples: samples,
      frameCount: frameCount,
      terminationReason: terminationReason,
      truncated: !sawCleanFinalize)
  }

  /// Delete a spool file. Idempotent — a missing file is success.
  public func delete(recoverySessionID: String) throws {
    let url = spoolURL(for: recoverySessionID)
    do {
      try FileManager.default.removeItem(at: url)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      return
    }
  }

  /// Create the directory at 0700, drop the Spotlight marker, and exclude it
  /// from backups. Re-enforced on every init. Soft-fails on any filesystem
  /// operation — better to lose a privacy guarantee than crash a limb.
  private static func prepareDirectory(at directory: URL) {
    let fm = FileManager.default
    try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let marker = directory.appendingPathComponent(".metadata_never_index")
    if !fm.fileExists(atPath: marker.path) {
      fm.createFile(atPath: marker.path, contents: Data(), attributes: nil)
    }
    var mutableDirectory = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? mutableDirectory.setResourceValues(values)
  }
}

/// The reconstructed result of a recovery read: the valid continuous prefix of
/// captured audio plus the provenance the recovery flow needs.
public struct RecoveredSpool: Sendable {
  public let recoverySessionID: String
  /// Provenance header, or nil if its JSON was unreadable (audio still recovers).
  public let header: RecoverySpoolHeader?
  /// Record-time settings, decrypted from the header. Nil ⇒ replay under
  /// current settings.
  public let settings: RecordingSettingsSnapshot?
  /// The recovered audio samples (16 kHz mono Float32).
  public let samples: [Float]
  /// Number of audio frames in the valid prefix.
  public let frameCount: Int
  /// Why writing stopped, if a terminal marker was present.
  public let terminationReason: RecoverySpoolTerminationReason?
  /// True when a torn / corrupt / out-of-sequence tail was discarded.
  public let truncated: Bool

  public init(
    recoverySessionID: String,
    header: RecoverySpoolHeader?,
    settings: RecordingSettingsSnapshot?,
    samples: [Float],
    frameCount: Int,
    terminationReason: RecoverySpoolTerminationReason?,
    truncated: Bool
  ) {
    self.recoverySessionID = recoverySessionID
    self.header = header
    self.settings = settings
    self.samples = samples
    self.frameCount = frameCount
    self.terminationReason = terminationReason
    self.truncated = truncated
  }
}
