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
    /// **Always DESCRIBES `dataDirectory`, on every result including an
    /// unavailable one.** The two fields may never disagree: a consumer reading
    /// `selection` to decide which root to name in a message, or whether this
    /// install has already moved, must not be told the opposite of what
    /// `dataDirectory` says.
    public let selection: Selection
    /// Every candidate tried, in order, when nothing was usable. Empty on a
    /// successful resolution. Named so the user-facing message can list the
    /// real paths rather than a category.
    public let exhausted: [URL]
    /// `true` when no candidate accepted a write. `dataDirectory` then holds the
    /// path the failure should be REPORTED against — the standard directory
    /// where one exists, or the claimed root that stopped accepting writes — so
    /// the error names a path a person would recognise rather than a temporary
    /// directory they have never seen. **It is not a destination.** Branch on
    /// this, never on `dataDirectory` being non-nil.
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

  /// The standard directory as a PLAIN PATH, with no probing and no fallback
  /// selection. What every existing install already uses.
  ///
  /// **This exists because a store may not be switched to `live` until the data
  /// handoff exists, and shipping the switch without the handoff would lose a
  /// real user's history.** Codex review of this change reproduced it against
  /// the actual resolver: an existing installation whose data directory turns
  /// read-only would commit an empty fallback, `TranscriptStore` and
  /// `RecoverySpoolStore` would then read only from there, and the person's
  /// saved history and recoverable recordings would vanish from the app while
  /// still sitting on disk. Repairing the machine would not bring them back,
  /// because the fallback stays authoritative by design.
  ///
  /// So the stores keep this path until the verified handoff lands (#2695 PR 2).
  /// `live`'s first production consumer is model delivery (#2697), where the
  /// bytes are reproducible and nothing can be orphaned.
  ///
  /// The only behaviour change here is the destination when the system lookup
  /// returns NOTHING at all. That used to be `temporaryDirectory`, which macOS
  /// purges; it is now the home folder, which is durable and the user's own.
  /// That is not a root SWITCH — when the lookup is empty there is no standard
  /// directory for anything to have been written to.
  public static var standardDirectory: URL {
    if let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first {
      return appSupport.appendingPathComponent(AppConstants.appSupportDir, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(AppConstants.appSupportDir, isDirectory: true)
  }

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
    // **A claimed root that cannot be written is UNAVAILABLE, never a reason to
    // use the other one.** Handing over would present the other root's contents
    // as this install's history, write new records into it, and then switch back
    // the moment the claimed root recovers, hiding everything written in
    // between. Two data sets, silently interleaved, with nothing reporting it.
    // Refusing is worse for one launch and correct forever after.
    let fallbackState = claimState(of: fallback, expecting: .homeFallback)
    let standardState = standard.map { claimState(of: $0, expecting: .standard) }

    // Each state permits a different ACTION, and the mapping is stated once
    // here rather than re-derived per candidate.
    func settle(_ directory: URL, _ selection: Selection, _ state: ClaimState) -> Resolution? {
      switch state {
      case .unclaimed, .inFlight:
        // Nothing of this install's is here, or what is here is a partial copy
        // whose originals stand in the other root. Move on.
        return nil
      case .committed, .unreadable:
        guard proveWritable(directory) else {
          return unavailable(
            directory, selection, attempted: [directory], systemApplicationSupport)
        }
        return resolved(directory, selection, systemApplicationSupport)
      case .incompatible:
        return unavailable(
          directory, selection, attempted: [directory], systemApplicationSupport)
      }
    }

    if let settled = settle(fallback, .homeFallback, fallbackState) { return settled }
    if let standard, let standardState,
      let settled = settle(standard, .standard, standardState)
    {
      return settled
    }

    // No authoritative selection, so choose one and record it — but ONLY over a
    // root that is genuinely unclaimed. A `.reserved` root is spoken for by an
    // interrupted handoff, a record we could not read, or a newer build's shape,
    // and claiming over one destroys the only evidence of what was happening
    // there. It is skipped as a candidate for BOTH use and claiming, and still
    // named in `exhausted` so a message can list every path considered.
    // A claim can LOSE to another process of this app that wrote its record
    // between our read and our write. The kernel decides that, not us, and the
    // loser must re-read rather than assume: whatever landed there is now the
    // truth about that root.
    func take(_ directory: URL, _ selection: Selection, _ state: ClaimState) -> Resolution? {
      guard state == .unclaimed else { return nil }
      switch claim(directory, as: selection) {
      case .claimed:
        return resolved(directory, selection, systemApplicationSupport)
      case .lostRace:
        return settle(directory, selection, claimState(of: directory, expecting: selection))
      case .failed:
        return nil
      }
    }

    var attempted: [URL] = []
    if let standard, let standardState {
      attempted.append(standard)
      if let taken = take(standard, .standard, standardState) { return taken }
    }
    attempted.append(fallback)
    if let taken = take(fallback, .homeFallback, fallbackState) { return taken }

    // Nothing is usable. Return the STANDARD path rather than inventing a third
    // destination, so the failure lands at the real write with the real path in
    // the error, unchanged from the behaviour this change replaces.
    if let standard {
      return unavailable(standard, .standard, attempted: attempted, systemApplicationSupport)
    }
    return unavailable(fallback, .homeFallback, attempted: attempted, systemApplicationSupport)
  }

  /// **`selection` always DESCRIBES `dataDirectory`, including here.** The
  /// first version hardcoded `.standard` while returning whichever directory it
  /// had named, so a committed home fallback that stopped accepting writes came
  /// back as `dataDirectory: <home>/EnviousWispr` with `selection: .standard`.
  /// A consumer reading `selection` to decide anything — which root to mention
  /// in a message, whether this install has already moved — would have been told
  /// the opposite of the truth, and the two fields would have disagreed with
  /// nothing reporting it (cloud review of PR #2698).
  private static func unavailable(
    _ directory: URL, _ selection: Selection, attempted: [URL],
    _ systemApplicationSupport: URL?
  ) -> Resolution {
    Resolution(
      dataDirectory: directory,
      systemApplicationSupport: systemApplicationSupport,
      selection: selection,
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
  /// What happened when we tried to take a root.
  enum ClaimOutcome: Equatable {
    /// This process wrote the record and owns the root.
    case claimed
    /// Somebody else got there between our read and our write. Their record
    /// stands; re-read it rather than guessing.
    case lostRace
    /// The directory or the write refused. Try the next candidate.
    case failed
  }

  /// Take a root by creating its record EXCLUSIVELY.
  ///
  /// **Not a temp-file-then-rename, and the difference is the whole point.** A
  /// rename overwrites unconditionally, so between one process reading a root
  /// as `unclaimed` and writing its claim, another process can commit an
  /// interrupted handoff or a newer build's record there — and the rename
  /// destroys it, which is the very thing the five readings exist to prevent
  /// (cloud review round 4). `O_CREAT | O_EXCL` decides that race in the
  /// kernel: exactly one caller creates the file and everybody else gets
  /// `EEXIST`, with no window between the check and the act.
  ///
  /// Same reasoning as `validation-discipline.md`
  /// RULE: a-single-threaded-test-cannot-distinguish-atomic-from-check-then-act,
  /// which is also why the test for this RACES it rather than calling it twice.
  static func claim(_ directory: URL, as selection: Selection) -> ClaimOutcome {
    guard prepare(directory) else { return .failed }
    let recordURL = directory.appendingPathComponent(recordFileName)

    let fd = Foundation.open(recordURL.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
    guard fd >= 0 else { return errno == EEXIST ? .lostRace : .failed }

    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let record = Record(selection: selection, committed: true, createdAt: Date())
      try handle.write(contentsOf: try encoder.encode(record))
      guard fcntl(fd, F_FULLFSYNC) != -1 else { throw CocoaError(.fileWriteUnknown) }
      try handle.close()
    } catch {
      // We created it, so we own the cleanup: a zero-length or half-written
      // record left behind would read as `unreadable` to the next launch, which
      // means "this root holds the user's data" and would be a lie.
      try? handle.close()
      try? FileManager.default.removeItem(at: recordURL)
      return .failed
    }

    let dirFD = Foundation.open(directory.path, O_RDONLY)
    if dirFD >= 0 {
      _ = fcntl(dirFD, F_FULLFSYNC)
      close(dirFD)
    }
    return .claimed
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
  /// Fails CLOSED: a `lstat` we could not complete answers "unsafe", not
  /// "fine". `fileExists` already told us something is there, so a stat that
  /// then fails is an anomaly, and the cost of being wrong here is every future
  /// write landing inside another application's directory.
  private static func isSymbolicLink(_ url: URL) -> Bool {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return true }
    return (info.st_mode & S_IFMT) == S_IFLNK
  }

  /// Has this directory already been chosen by an earlier launch?
  ///
  /// **The record's LOCATION carries the selection; its contents are only a
  /// cross-check.** That is deliberate, and it is what stops a three-valued
  /// question collapsing into two. `try? Data(contentsOf:)` returns `nil` both
  /// for "there is no record" and for "there is a record and I could not read
  /// it", and a caller that treats the second as the first sends a user who has
  /// already moved back to the standard directory, orphaning everything written
  /// since the move. Silent, and not recoverable by a later launch.
  ///
  /// So presence is answered by `lstat`, which distinguishes absence from every
  /// other reason, and an unreadable or undecodable record is treated as a
  /// CLAIM rather than as absence. That is the conservative direction: honouring
  /// a record we cannot read costs a re-proof of writability, which runs anyway;
  /// ignoring one costs the user their data.
  ///
  /// A record we CAN read still has to say `committed`. A half-written selection
  /// is what a future data handoff leaves behind before it starts moving files,
  /// and obeying that would point the app at an incomplete copy.
  /// What the record in a directory says about that directory.
  ///
  /// **Five states, because a `Bool` was one answer to two different questions
  /// and both review rounds landed on that.** "May I claim this root?" and "is
  /// this root usable?" are not the same question, and the states below differ
  /// in WHICH ACTION they permit, not merely in how they arose. Enumerated from
  /// what the file can actually contain rather than from the findings, so a
  /// sixth reading would have to be a new member of this list rather than a
  /// case nobody classified.
  ///
  /// Nothing here ever writes over a root that is not `unclaimed`.
  enum ClaimState: Equatable {
    /// No record. Free to claim.
    case unclaimed
    /// Committed, and this build understands the shape. Use it if it still
    /// accepts a write.
    case committed
    /// A record is there and we could not read or decode it. We only ever write
    /// one after committing, so THIS ROOT HOLDS THE USER'S DATA. Use it if it
    /// still accepts a write: falling through to the other root would present
    /// that root's contents as this install's history and orphan what is here.
    case unreadable
    /// Written by a NEWER build, whose shape this one cannot interpret. The data
    /// is here, so falling through would orphan it; the meaning is unknown, so
    /// using it could write our layout into a root that means something else.
    /// Refuse, loudly, and leave it untouched — upgrading again loses nothing.
    case incompatible
    /// A handoff that did not finish. The copy here is partial and the ORIGINALS
    /// still stand in the other root, so this is the one state where moving on
    /// to the other root is correct rather than dangerous.
    case inFlight
  }

  /// Just the version, decoded on its own.
  ///
  /// **The version gate has to be reachable for EVERY shape, which means
  /// reading it BEFORE the full decode rather than after.** A newer build that
  /// changes a required field or adds a `Selection` case produces a record that
  /// fails to decode as `Record` at all — so a version check placed after the
  /// full decode never runs for exactly the changes it exists to catch, and the
  /// root is classified `unreadable`, which PERMITS WRITES in this build's older
  /// layout. The gate was unreachable in the case that matters (cloud review
  /// round 3).
  private struct RecordVersion: Decodable {
    let version: Int
  }

  /// - Parameter expecting: which candidate this directory IS. Passed in rather
  ///   than derived from the path, because `resolve` already knows and matching
  ///   on path text would be a proxy for the question — right until a path spells
  ///   itself differently, which is exactly what the tests' own sandbox does.
  static func claimState(of directory: URL, expecting expected: Selection) -> ClaimState {
    let recordURL = directory.appendingPathComponent(recordFileName)
    switch presence(of: recordURL) {
    case .absent:
      return .unclaimed
    case .unreadable:
      return .unreadable
    case .present:
      guard let data = try? Data(contentsOf: recordURL) else { return .unreadable }
      // Version FIRST, from a minimal envelope, so a newer shape is refused
      // rather than mistaken for a damaged one.
      guard let stamp = try? JSONDecoder().decode(RecordVersion.self, from: data) else {
        return .unreadable
      }
      guard stamp.version <= Record.currentVersion else { return .incompatible }
      guard let record = try? JSONDecoder().decode(Record.self, from: data) else {
        return .unreadable
      }
      // **A record must describe the root it was found in.** A marker copied or
      // restored into the other candidate would otherwise be honoured for
      // whichever directory happens to hold it, and because the fallback is
      // checked first a stale copy there would win over a healthy standard root.
      // Selection evidence that contradicts its own location is not evidence:
      // refuse, and never write over it, because the copy may be the only trace
      // of what the user actually had.
      guard record.selection == expected else { return .incompatible }
      return record.committed ? .committed : .inFlight
    }
  }

  private enum Presence {
    case absent
    case present
    /// Something is there, or something prevented us from finding out. Both are
    /// handled as "assume it is there", because the cost of being wrong that way
    /// is a wasted probe and the cost of being wrong the other way is data.
    case unreadable
  }

  /// `lstat`, not `fileExists`, and not `try? Data(contentsOf:)`.
  ///
  /// `fileExists` follows symlinks and collapses every failure into `false`.
  /// `lstat`'s errno separates the one answer that means absence — `ENOENT`, or
  /// `ENOTDIR` when a path component is a file — from every other reason a stat
  /// can fail.
  private static func presence(of url: URL) -> Presence {
    var info = stat()
    if lstat(url.path, &info) == 0 { return .present }
    switch errno {
    case ENOENT, ENOTDIR: return .absent
    default: return .unreadable
    }
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
