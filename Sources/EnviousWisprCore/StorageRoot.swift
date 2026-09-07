import Foundation

/// Where EnviousWispr may write, decided by DOING it rather than by assuming
/// it (#2695).
///
/// Before this type, ten call sites plus `AppConstants` each resolved
/// `FileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)`
/// independently and every one of them assumed the result was usable. None
/// asked. #2690 is a shipping user whose `~/Library/Application Support` is
/// owned by `root:wheel` mode 755, so he cannot create anything in it: first
/// run fails at `createDirectory`, the app tells him the download could not be
/// verified, and he can never finish setup.
///
/// **The founder ruled out the repair (2026-09-07).** No design may ask a user
/// for an administrator password or change the ownership or permissions of any
/// directory, because the population most likely to hold a root-owned parent is
/// a company-managed Mac, whose user usually has no administrator password and
/// could be in trouble with their employer for using one. So this type does not
/// fix the machine. It finds somewhere the user already owns, and remembers.
///
/// **Two values, not one, and they answer different questions.**
/// `dataDirectory` is "where may we write" and is ours. `systemApplicationSupport`
/// is "where did another vendor put bytes we may only read" and is resolved from
/// the system lookup EVERY TIME, independently of which candidate won. The
/// legacy Parakeet donor under `FluidAudio/` is a SIBLING of our data directory,
/// never a child of it (`ParakeetInstallLocation.legacySharedDonor(appSupport:)`),
/// so deriving it by walking up from `dataDirectory` lands in the user's home
/// under the fallback and returns a clean-looking miss — wrong exactly when the
/// fallback fires, which is the only time it matters.
public enum StorageRoot {

  // MARK: - Selection

  /// Which candidate is authoritative for this install.
  public enum Selection: String, Codable, Sendable {
    /// `<Application Support>/EnviousWispr`. What every install gets when the
    /// machine is healthy.
    case standard
    /// `<home>/EnviousWispr`. Reached only when the standard candidate could
    /// not be created or written.
    case homeFallback = "home_fallback"
  }

  /// The on-disk record, written INSIDE the root it describes.
  ///
  /// **Not `UserDefaults`, and that is the point.** A non-sandboxed app's
  /// defaults live in `~/Library/Preferences/<bundleid>.plist`, which the same
  /// mechanism can make unwritable; and `UserDefaults.set` updates memory
  /// immediately while persisting asynchronously, so reading a value back does
  /// not prove it survived a restart. A record beside the data it describes
  /// cannot disagree with the data, and cannot be lost while the data survives.
  public struct Record: Codable, Sendable, Equatable {
    /// Bumped only for a shape change a previous build could misread.
    public static let currentVersion = 1

    public var version: Int
    public var selection: Selection
    /// `false` while a future data handoff is mid-flight (#2695 PR 2). A
    /// `committed == false` record must never be treated as authoritative.
    /// Written eagerly here so the handoff can extend the shape without a
    /// format break that an already-shipped build would have to understand.
    public var committed: Bool
    public var createdAt: Date

    public init(
      version: Int = Record.currentVersion,
      selection: Selection,
      committed: Bool,
      createdAt: Date
    ) {
      self.version = version
      self.selection = selection
      self.committed = committed
      self.createdAt = createdAt
    }
  }

  /// What `resolve` decided.
  public struct Resolution: Sendable, Equatable {
    /// Ours. Everything we write goes under here, and it already includes the
    /// application folder name. Never hand this to anything expecting a PARENT.
    public let dataDirectory: URL
    /// The system's Application Support directory, or `nil` when the system
    /// lookup returns nothing. **Read-only, for locating another vendor's
    /// shared cache. Never a write destination.**
    public let systemApplicationSupport: URL?
    public let selection: Selection
    /// Every candidate tried, in order, when nothing was usable. Empty on a
    /// successful resolution. Named so the user-facing message can list the
    /// real paths rather than a category.
    public let exhausted: [URL]
    /// `true` when no candidate accepted a write. `dataDirectory` then holds
    /// the STANDARD path, so failures surface at the real write site exactly as
    /// they do today rather than being redirected into a third location that
    /// looks like it worked.
    public let isUnavailable: Bool
  }

  /// The record's filename. Dot-prefixed so it does not appear in a user's
  /// Finder window beside their own data.
  public static let recordFileName = ".storage-state.json"

  // MARK: - Live resolution

  /// Resolved once per process, before any store is constructed.
  ///
  /// A `static let` is lazy and initialised exactly once under the Swift
  /// runtime's own lock, which is the property this needs: two stores racing to
  /// read it must not run the probe twice and must not disagree about the
  /// answer.
  public static let live: Resolution = resolve(
    systemApplicationSupport: FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first,
    home: FileManager.default.homeDirectoryForCurrentUser
  )

  // MARK: - Resolution

  /// Decide which root is authoritative.
  ///
  /// **The candidate list is exactly two, then stop.** Caches, `/tmp`,
  /// Documents and `/Users/Shared` are deliberately absent: each is either
  /// purgeable by the system or shared with other accounts, and a durable store
  /// that quietly loses data is worse than one that refuses. The prior
  /// `AppConstants.appSupportURL` fallback wrote to `temporaryDirectory` and is
  /// deleted by this change for exactly that reason.
  ///
  /// - Parameters:
  ///   - systemApplicationSupport: the system lookup's answer, or `nil`.
  ///   - home: the account's real home directory. Resolve it from the system,
  ///     never by composing `/Users/<name>`, which is wrong for a network,
  ///     mobile or relocated home.
  public static func resolve(
    systemApplicationSupport: URL?,
    home: URL
  ) -> Resolution {
    let standard = systemApplicationSupport?.appendingPathComponent(
      AppConstants.appSupportDir, isDirectory: true)
    let fallback = home.appendingPathComponent(
      AppConstants.appSupportDir, isDirectory: true)

    // An existing committed selection outranks the candidate order, and the
    // FALLBACK is checked first on purpose. Once we have moved, a repaired
    // machine must not silently flip back: the standard directory may still
    // hold a stale copy from before the move, and returning to it would present
    // old history as current while hiding everything written since.
    if let record = readRecord(in: fallback), record.committed,
      record.selection == .homeFallback,
      proveWritable(fallback)
    {
      return resolved(fallback, .homeFallback, systemApplicationSupport)
    }
    if let standard, let record = readRecord(in: standard), record.committed,
      record.selection == .standard,
      proveWritable(standard)
    {
      return resolved(standard, .standard, systemApplicationSupport)
    }

    // No committed selection, so choose one and record it.
    var attempted: [URL] = []
    if let standard {
      attempted.append(standard)
      if claim(standard, as: .standard) {
        return resolved(standard, .standard, systemApplicationSupport)
      }
    }
    attempted.append(fallback)
    if claim(fallback, as: .homeFallback) {
      return resolved(fallback, .homeFallback, systemApplicationSupport)
    }

    // Nothing is usable. Return the STANDARD path rather than inventing a third
    // destination, so the failure lands at the real write with the real path in
    // the error, unchanged from the behaviour this change replaces.
    return Resolution(
      dataDirectory: standard ?? fallback,
      systemApplicationSupport: systemApplicationSupport,
      selection: .standard,
      exhausted: attempted,
      isUnavailable: true)
  }

  // MARK: - Probing

  /// Prove a directory is usable by CREATING it and writing a real file inside
  /// it, then recording the selection.
  ///
  /// Not a parent probe: a parent probe can reject a usable existing child, and
  /// cannot see an unwritable child of a writable parent. The write is the
  /// record itself, so a successful claim leaves the evidence it needed to
  /// produce anyway.
  private static func claim(_ directory: URL, as selection: Selection) -> Bool {
    guard prepare(directory) else { return false }
    let record = Record(selection: selection, committed: true, createdAt: Date())
    do {
      try DurableJSONFile.write(
        record, to: directory.appendingPathComponent(recordFileName),
        tempPrefix: ".ew-storage-state")
      return true
    } catch {
      return false
    }
  }

  /// Re-prove a directory that already carries a committed record.
  ///
  /// A successful earlier claim is not a promise about today: the volume can be
  /// gone, the home can be unmounted, or the permissions can have changed since.
  /// Cheap, because the record is small and the rename is atomic.
  private static func proveWritable(_ directory: URL) -> Bool {
    guard prepare(directory) else { return false }
    let probe = directory.appendingPathComponent(".ew-storage-probe")
    do {
      try DurableJSONFile.write(data: Data(), to: probe, tempPrefix: ".ew-storage-probe")
      try? FileManager.default.removeItem(at: probe)
      return true
    } catch {
      return false
    }
  }

  /// Create the directory at 0700 and report whether it now exists as a
  /// directory we own.
  ///
  /// **Never alters the permissions of anything that already exists.** Founder
  /// constraint: changing permissions is the mechanism that caused #2690, and a
  /// company-managed Mac is exactly where doing it would cause harm. So a
  /// pre-existing directory is accepted as it is and judged by whether the
  /// write below succeeds.
  private static func prepare(_ directory: URL) -> Bool {
    let fm = FileManager.default
    var isDirectory: ObjCBool = false
    if fm.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
      // A file, a socket or a symlink where our directory should be is not a
      // usable root, and we must not delete whatever it is.
      guard isDirectory.boolValue else { return false }
      guard !isSymbolicLink(directory) else { return false }
      return true
    }
    do {
      try fm.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      return true
    } catch {
      return false
    }
  }

  /// `fileExists` FOLLOWS symlinks, which has already cost this project once:
  /// a staged file that was a symlink into another application's directory read
  /// as an ordinary file, and promotion moved the LINK rather than the bytes
  /// (#2694 review). Ask `lstat` instead, which does not follow.
  private static func isSymbolicLink(_ url: URL) -> Bool {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return false }
    return (info.st_mode & S_IFMT) == S_IFLNK
  }

  private static func readRecord(in directory: URL) -> Record? {
    guard
      let data = try? Data(contentsOf: directory.appendingPathComponent(recordFileName))
    else { return nil }
    return try? JSONDecoder().decode(Record.self, from: data)
  }

  private static func resolved(
    _ directory: URL, _ selection: Selection, _ systemApplicationSupport: URL?
  ) -> Resolution {
    Resolution(
      dataDirectory: directory,
      systemApplicationSupport: systemApplicationSupport,
      selection: selection,
      exhausted: [],
      isUnavailable: false)
  }
}
