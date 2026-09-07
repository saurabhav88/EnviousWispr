import Foundation
import Testing

@testable import EnviousWisprCore

/// When these fail, the user's dictation history, custom words and snippets go
/// somewhere the app will not look for them again, or the app refuses to start
/// on a machine where it could have worked (#2695).
///
/// Every case drives the REAL filesystem inside a private temporary sandbox,
/// because the whole subject of `StorageRoot` is whether a directory actually
/// accepts a write. A fake `FileManager` would answer the question the type
/// exists to stop us assuming.
@Suite(.tags(.productOutcome))
struct StorageRootTests {

  // MARK: - Sandbox

  /// Two independent roots standing in for the machine's Application Support
  /// directory and the account's home directory.
  private struct Sandbox {
    let root: URL
    let appSupport: URL
    let home: URL

    init() throws {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ew-storage-root-\(UUID().uuidString)", isDirectory: true)
      appSupport = root.appendingPathComponent("ApplicationSupport", isDirectory: true)
      home = root.appendingPathComponent("Home", isDirectory: true)
      try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var standardCandidate: URL {
      appSupport.appendingPathComponent(AppConstants.appSupportDir, isDirectory: true)
    }
    var fallbackCandidate: URL {
      home.appendingPathComponent(AppConstants.appSupportDir, isDirectory: true)
    }

    /// Take away the right to CREATE inside a directory without deleting it, the
    /// way #2690's machine did. `0o500` is read plus traverse, no write.
    func lock(_ directory: URL) throws {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o500], ofItemAtPath: directory.path)
    }

    /// Restore write access so the sandbox can be removed. Called from `defer`
    /// on every case that locks something, so a failing assertion still leaves
    /// the machine clean.
    func unlockAll() {
      for directory in [standardCandidate, fallbackCandidate, appSupport, home, root] {
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o600],
          ofItemAtPath: directory.appendingPathComponent(StorageRoot.recordFileName).path)
      }
    }

    /// Restores write access to everything under the sandbox before removing
    /// it. Cases deliberately create unreadable files and unwritable
    /// directories, and a `removeItem` over one of those fails silently and
    /// leaves the machine littered.
    func tearDown() {
      unlockAll()
      let fm = FileManager.default
      if let walker = fm.enumerator(atPath: root.path) {
        for case let relative as String in walker {
          try? fm.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.appendingPathComponent(relative).path)
        }
      }
      try? fm.removeItem(at: root)
    }
  }

  private func writeRecord(
    _ record: StorageRoot.Record, into directory: URL
  ) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(record)
    try data.write(to: directory.appendingPathComponent(StorageRoot.recordFileName))
  }

  private func readRecord(from directory: URL) throws -> StorageRoot.Record {
    let data = try Data(
      contentsOf: directory.appendingPathComponent(StorageRoot.recordFileName))
    return try JSONDecoder().decode(StorageRoot.Record.self, from: data)
  }

  private func permissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let number = try #require(attributes[.posixPermissions] as? NSNumber)
    return number.intValue
  }

  // MARK: - The ordinary machine

  @Test("A healthy Mac uses Application Support and writes down that it did")
  func healthyMachineSelectsStandardAndRecordsIt() throws {
    let sandbox = try Sandbox()
    defer { sandbox.tearDown() }

    let resolution = StorageRoot.resolve(
      systemApplicationSupport: sandbox.appSupport, home: sandbox.home)

    #expect(resolution.selection == .standard)
    #expect(resolution.dataDirectory == sandbox.standardCandidate)
    #expect(resolution.isUnavailable == false)
    #expect(resolution.exhausted.isEmpty)

    let record = try readRecord(from: sandbox.standardCandidate)
    #expect(record.selection == .standard)
    #expect(record.committed)
    #expect(record.version == StorageRoot.Record.currentVersion)
  }

  @Test("A created root is readable only by its owner")
  func aCreatedRootIsOwnerOnly() throws {
    let sandbox = try Sandbox()
    defer { sandbox.tearDown() }

    _ = StorageRoot.resolve(systemApplicationSupport: sandbox.appSupport, home: sandbox.home)

    #expect(try permissions(of: sandbox.standardCandidate) == 0o700)
  }

  // MARK: - #2690's machine

  @Test("An Application Support directory we cannot write to sends us to the home folder")
  func unwritableApplicationSupportFallsBackToHome() throws {
    let sandbox = try Sandbox()
    defer { sandbox.tearDown() }
    try sandbox.lock(sandbox.appSupport)

    let resolution = StorageRoot.resolve(
      systemApplicationSupport: sandbox.appSupport, home: sandbox.home)

    #expect(resolution.selection == .homeFallback)
    #expect(resolution.dataDirectory == sandbox.fallbackCandidate)
    #expect(resolution.isUnavailable == false)

    let record = try readRecord(from: sandbox.fallbackCandidate)
    #expect(record.selection == .homeFallback)
    #expect(record.committed)
  }

  /// The donor question. Another vendor's shared model cache is a SIBLING of our
  /// standard directory, so it can only be found through the system lookup. If
  /// the fallback's win overwrote or cleared this value, the donor would become
  /// underivable exactly when the fallback fires, and the miss would look clean.
  @Test("The system's own Application Support path survives the fallback winning")
  func theVendorLookupIsCarriedThroughUnchangedWhenTheFallbackWins() throws {
    let sandbox = try Sandbox()
    defer { sandbox.tearDown() }
    try sandbox.lock(sandbox.appSupport)

    let resolution = StorageRoot.resolve(
      systemApplicationSupport: sandbox.appSupport, home: sandbox.home)

    #expect(resolution.selection == .homeFallback)
    #expect(resolution.systemApplicationSupport == sandbox.appSupport)
    #expect(resolution.systemApplicationSupport != resolution.dataDirectory)
  }

  // MARK: - Remembering, and never quietly going back

  /// The case that makes the record worth having. A machine gets repaired, or
  /// the user is moved to a new Mac by Migration Assistant, and Application
  /// Support works again. Everything written since the move lives in the home
  /// folder. Returning to the standard directory would show the user an empty
  /// or stale history and hide the real one, with nothing reporting it.
  @Test("Once we have moved, a repaired Application Support does not take us back")
  func aCommittedFallbackIsKeptEvenWhenTheStandardPathWorksAgain() throws {
    let sandbox = try Sandbox()
    defer { sandbox.tearDown() }
    try writeRecord(
      StorageRoot.Record(selection: .homeFallback, committed: true, createdAt: Date()),
      into: sandbox.fallbackCandidate)

    // Application Support is perfectly writable in this case.
    let resolution = StorageRoot.resolve(
      systemApplicationSupport: sandbox.appSupport, home: sandbox.home)

    #expect(resolution.selection == .homeFallback)
    #expect(resolution.dataDirectory == sandbox.fallbackCandidate)
    #expect(FileManager.default.fileExists(atPath: sandbox.standardCandidate.path) == false)
  }

  @Test("A recorded standard selection is honoured without re-deciding")
  func aCommittedStandardRecordIsHonoured() throws {
    let sandbox = try Sandbox()
    defer { sandbox.tearDown() }
    let earlier = Date(timeIntervalSince1970: 1)
    try writeRecord(
      StorageRoot.Record(selection: .standard, committed: true, createdAt: earlier),
      into: sandbox.standardCandidate)

    let resolution = StorageRoot.resolve(
      systemApplicationSupport: sandbox.appSupport, home: sandbox.home)

    #expect(resolution.selection == .standard)
    // The existing record is left as it was rather than restamped, which is how
    // a later reader can tell when this install first chose its root.
    #expect(try readRecord(from: sandbox.standardCandidate).createdAt == earlier)
  }

  /// A half-written selection must not be obeyed. `committed: false` is what a
  /// future data handoff writes before it starts moving files, so treating it as
  /// authoritative would point the app at a directory holding an incomplete copy.
  @Test("A selection that was never committed is not obeyed")
  func anUncommittedRecordIsNotAuthoritative() throws {
    let sandbox = try Sandbox()
    defer { sandbox.tearDown() }
    try writeRecord(
      StorageRoot.Record(selection: .homeFallback, committed: false, createdAt: Date()),
      into: sandbox.fallbackCandidate)

    let recordURL = sandbox.fallbackCandidate.appendingPathComponent(
      StorageRoot.recordFileName)
    let before = try Data(contentsOf: recordURL)

    let resolution = StorageRoot.resolve(
      systemApplicationSupport: sandbox.appSupport, home: sandbox.home)

    #expect(resolution.selection == .standard)
    // And the half-finished record is left exactly as it was, so whatever was
    // moving can be resumed or reported.
    #expect(try Data(contentsOf: recordURL) == before)
  }

  /// The costly version of the case above. An interrupted handoff left a
  /// `committed: false` record in the fallback, and the standard directory is
  /// unwritable. Treating "not committed" as "not claimed" made the fallback
  /// look free, and the next step CLAIMED it — stamping a committed record over
  /// the only evidence that a move was half done, and presenting a partial copy
  /// as a complete one.
  @Test("An interrupted move is never claimed over, even with nowhere else to go")
  func anInterruptedHandoffIsNeverOverwritten() throws {
    let sandbox = try Sandbox()
    defer { sandbox.tearDown() }
    try writeRecord(
      StorageRoot.Record(selection: .homeFallback, committed: false, createdAt: Date()),
      into: sandbox.fallbackCandidate)
    let recordURL = sandbox.fallbackCandidate.appendingPathComponent(
      StorageRoot.recordFileName)
    let before = try Data(contentsOf: recordURL)
    try sandbox.lock(sandbox.appSupport)

    let resolution = StorageRoot.resolve(
      systemApplicationSupport: sandbox.appSupport, home: sandbox.home)

    #expect(resolution.isUnavailable)
    #expect(try Data(contentsOf: recordURL) == before)
  }

  /// A record written by a NEWER build. A compatible superset still decodes, so
  /// deciding from `committed` alone would accept a shape this build does not
  /// understand, while an incompatible shape would take the decode-failure path
  /// and be handled differently — same record, two answers, depending on a
  /// property nobody chose. Both are refused the same way, so downgrading and
  /// upgrading again loses nothing.
  @Test("A record from a newer build is neither used nor overwritten")
  func aRecordFromANewerBuildIsNeitherUsedNorOverwritten() throws {
    let sandbox = try Sandbox()
    defer { sandbox.tearDown() }
    try writeRecord(
      StorageRoot.Record(
        version: StorageRoot.Record.currentVersion + 1,
        selection: .homeFallback, committed: true, createdAt: Date()),
      into: sandbox.fallbackCandidate)
    let recordURL = sandbox.fallbackCandidate.appendingPathComponent(
      StorageRoot.recordFileName)
    let before = try Data(contentsOf: recordURL)

    let resolution = StorageRoot.resolve(
      systemApplicationSupport: sandbox.appSupport, home: sandbox.home)

    // Refused rather than used, because the shape is unknown; and refused
    // rather than fallen through, because the data is HERE.
    #expect(resolution.isUnavailable)
    #expect(resolution.selection == .homeFallback)
    #expect(try Data(contentsOf: recordURL) == before)
  }

  /// The class behind both findings above, enumerated rather than described.
  /// Every answer the record file can give, and what each must mean.
  @Test("Every state a record can be in is classified, and only one is claimable")
  func everyRecordStateIsClassified() throws {
    let sandbox = try Sandbox()
    defer { sandbox.tearDown() }
    let fm = FileManager.default

    func stateOf(_ build: (URL) throws -> Void) throws -> StorageRoot.ClaimState {
      let directory = sandbox.root.appendingPathComponent(
        "case-\(UUID().uuidString)", isDirectory: true)
      try fm.createDirectory(at: directory, withIntermediateDirectories: true)
      try build(directory)
      return StorageRoot.claimState(of: directory, expecting: .standard)
    }

    #expect(try stateOf { _ in } == .unclaimed)

    #expect(
      try stateOf { directory in
        try Data("not a record".utf8).write(
          to: directory.appendingPathComponent(StorageRoot.recordFileName))
      } == .unreadable, "undecodable")

    #expect(
      try stateOf { directory in
        try JSONEncoder().encode(
          StorageRoot.Record(selection: .standard, committed: false, createdAt: Date())
        ).write(to: directory.appendingPathComponent(StorageRoot.recordFileName))
      } == .inFlight, "handoff in flight")

    #expect(
      try stateOf { directory in
        try JSONEncoder().encode(
          StorageRoot.Record(
            version: StorageRoot.Record.currentVersion + 1,
            selection: .standard, committed: true, createdAt: Date())
        ).write(to: directory.appendingPathComponent(StorageRoot.recordFileName))
      } == .incompatible, "written by a newer build")

    #expect(
      try stateOf { directory in
        let url = directory.appendingPathComponent(StorageRoot.recordFileName)
        try JSONEncoder().encode(
          StorageRoot.Record(selection: .standard, committed: true, createdAt: Date())
        ).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
      } == .unreadable, "unreadable")

    #expect(
      try stateOf { directory in
        try JSONEncoder().encode(
          StorageRoot.Record(selection: .homeFallback, committed: true, createdAt: Date())
        ).write(to: directory.appendingPathComponent(StorageRoot.recordFileName))
      } == .incompatible, "describes the OTHER root")

    #expect(
      try stateOf { directory in
        try JSONEncoder().encode(
          StorageRoot.Record(selection: .standard, committed: true, createdAt: Date())
        ).write(to: directory.appendingPathComponent(StorageRoot.recordFileName))
      } == .committed)
  }

  /// A newer build that adds a `Selection` case, or changes a required field,
  /// produces a record that will not decode as `Record` at all. Checking the
  /// version AFTER the full decode meant the version gate never ran for exactly
  /// the changes it exists to catch, and the root came back as merely damaged —
  /// which PERMITS writes in this build's older layout.
  @Test("A shape from the future is refused, not mistaken for damage")
  func aFutureShapeIsRefusedRatherThanTreatedAsDamage() throws {
    let sandbox = try Sandbox()
    defer { sandbox.tearDown() }
    try FileManager.default.createDirectory(
      at: sandbox.fallbackCandidate, withIntermediateDirectories: true)
    // Decodes as a version stamp, does NOT decode as a `Record`: the shape a
    // newer build with a new `Selection` case would leave behind.
    try Data(#"{"version":99,"selection":"cloud","committed":true}"#.utf8).write(
      to: sandbox.fallbackCandidate.appendingPathComponent(StorageRoot.recordFileName))

    #expect(
      StorageRoot.claimState(of: sandbox.fallbackCandidate, expecting: .homeFallback)
        == .incompatible)
  }

  /// A marker copied or restored into the other candidate. The fallback is
  /// checked first, so a stale copy there would otherwise win over a healthy
  /// standard root and point the app at a directory that never held its data.
  @Test("A record that describes the other root is not evidence about this one")
  func aRecordDescribingTheOtherRootIsRefused() throws {
    let sandbox = try Sandbox()
    defer { sandbox.tearDown() }
    try writeRecord(
      StorageRoot.Record(selection: .standard, committed: true, createdAt: Date()),
      into: sandbox.fallbackCandidate)
    let recordURL = sandbox.fallbackCandidate.appendingPathComponent(
      StorageRoot.recordFileName)
    let before = try Data(contentsOf: recordURL)

    let resolution = StorageRoot.resolve(
      systemApplicationSupport: sandbox.appSupport, home: sandbox.home)

    #expect(resolution.isUnavailable)
    #expect(resolution.selection == .homeFallback)
    // Never written over: the stray copy may be the only trace of what the user
    // actually had.
    #expect(try Data(contentsOf: recordURL) == before)
  }

  /// A recorded selection is a claim about the past, not a promise about today:
  /// an external drive can be gone, a network home unmounted, permissions changed.
  ///
  /// But a chosen root that stops accepting writes must REFUSE, never hand over
  /// to the other one. Handing over shows the other root's contents as this
  /// install's history, writes new records into it, and then switches back the
  /// moment the chosen root recovers, hiding everything written in between. Two
  /// data sets silently interleaved, with nothing reporting it.
  @Test("A chosen root that stops accepting writes refuses rather than switching")
  func aRecordedSelectionThatNoLongerWritesRefusesRatherThanSwitching() throws {
    let sandbox = try Sandbox()
    defer { sandbox.tearDown() }
    try writeRecord(
      StorageRoot.Record(selection: .homeFallback, committed: true, createdAt: Date()),
      into: sandbox.fallbackCandidate)
    try sandbox.lock(sandbox.fallbackCandidate)

    let resolution = StorageRoot.resolve(
      systemApplicationSupport: sandbox.appSupport, home: sandbox.home)

    #expect(resolution.isUnavailable)
    #expect(resolution.dataDirectory == sandbox.fallbackCandidate)
    #expect(resolution.exhausted == [sandbox.fallbackCandidate])
    // The two fields must agree. Reporting `.standard` beside the fallback's
    // path tells a caller the opposite of the truth about whether this install
    // has already moved, and nothing would report the disagreement.
    #expect(resolution.selection == .homeFallback)
    // The other root must not have been claimed behind the user's back.
    #expect(FileManager.default.fileExists(atPath: sandbox.standardCandidate.path) == false)
  }

  /// The invariant behind the case above, asserted across every shape a
  /// resolution can take rather than at the one site review happened to name.
  @Test("What we chose always describes where we point, on every outcome")
  func selectionAlwaysDescribesTheDataDirectory() throws {
    let sandbox = try Sandbox()
    defer { sandbox.tearDown() }

    func check(_ resolution: StorageRoot.Resolution, _ label: Comment) {
      switch resolution.selection {
      case .standard:
        #expect(resolution.dataDirectory == sandbox.standardCandidate, label)
      case .homeFallback:
        #expect(resolution.dataDirectory == sandbox.fallbackCandidate, label)
      }
    }

    check(
      StorageRoot.resolve(systemApplicationSupport: sandbox.appSupport, home: sandbox.home),
      "healthy machine")

    try sandbox.lock(sandbox.appSupport)
    check(
      StorageRoot.resolve(systemApplicationSupport: sandbox.appSupport, home: sandbox.home),
      "Application Support unwritable, fallback taken")

    try sandbox.lock(sandbox.home)
    check(
      StorageRoot.resolve(systemApplicationSupport: sandbox.appSupport, home: sandbox.home),
      "nothing writable")

    sandbox.unlockAll()
    check(
      StorageRoot.resolve(systemApplicationSupport: nil, home: sandbox.home),
      "no system lookup at all")
  }

  /// The three-valued read. `try? Data(contentsOf:)` answers `nil` both for
  /// "there is no record" and for "there is one and I could not read it". A
  /// caller that treats the second as the first sends someone who has already
  /// moved back to the standard directory and orphans everything written since.
  @Test("A record we cannot read still counts as a claim")
  func anUnreadableRecordStillCountsAsAClaim() throws {
    let sandbox = try Sandbox()
    defer { sandbox.tearDown() }
    try writeRecord(
      StorageRoot.Record(selection: .homeFallback, committed: true, createdAt: Date()),
      into: sandbox.fallbackCandidate)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o000],
      ofItemAtPath: sandbox.fallbackCandidate.appendingPathComponent(
        StorageRoot.recordFileName
      ).path)

    let resolution = StorageRoot.resolve(
      systemApplicationSupport: sandbox.appSupport, home: sandbox.home)

    #expect(resolution.selection == .homeFallback)
    #expect(resolution.dataDirectory == sandbox.fallbackCandidate)
  }

  @Test("A damaged record still counts as a claim")
  func aDamagedRecordStillCountsAsAClaim() throws {
    let sandbox = try Sandbox()
    defer { sandbox.tearDown() }
    try FileManager.default.createDirectory(
      at: sandbox.fallbackCandidate, withIntermediateDirectories: true)
    try Data("this is not the record you are looking for".utf8).write(
      to: sandbox.fallbackCandidate.appendingPathComponent(StorageRoot.recordFileName))

    let resolution = StorageRoot.resolve(
      systemApplicationSupport: sandbox.appSupport, home: sandbox.home)

    #expect(resolution.selection == .homeFallback)
  }

  // MARK: - Things that are not our directory

  /// `fileExists` follows symlinks, and this project has already paid for that
  /// once: a staged file that was a symlink into another application's directory
  /// read as an ordinary file, and promotion moved the link rather than the
  /// bytes. A symlink where our root belongs must never be adopted, because
  /// everything we then write lands in whatever it points at.
  @Test("A symlink where our folder belongs is refused, not followed")
  func aSymlinkWhereOurDirectoryBelongsIsRefused() throws {
    let sandbox = try Sandbox()
    defer { sandbox.tearDown() }
    let elsewhere = sandbox.root.appendingPathComponent("SomeoneElse", isDirectory: true)
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: sandbox.standardCandidate, withDestinationURL: elsewhere)

    let resolution = StorageRoot.resolve(
      systemApplicationSupport: sandbox.appSupport, home: sandbox.home)

    #expect(resolution.selection == .homeFallback)
    #expect(
      FileManager.default.fileExists(
        atPath: elsewhere.appendingPathComponent(StorageRoot.recordFileName).path) == false)
  }

  @Test("A file where our folder belongs is refused and left untouched")
  func aFileWhereOurDirectoryBelongsIsRefusedAndLeftAlone() throws {
    let sandbox = try Sandbox()
    defer { sandbox.tearDown() }
    let contents = Data("not ours".utf8)
    try contents.write(to: sandbox.standardCandidate)

    let resolution = StorageRoot.resolve(
      systemApplicationSupport: sandbox.appSupport, home: sandbox.home)

    #expect(resolution.selection == .homeFallback)
    #expect(try Data(contentsOf: sandbox.standardCandidate) == contents)
  }

  /// The founder's binding constraint, as an assertion rather than a comment.
  /// Changing a permission is the mechanism that caused #2690, and on a
  /// company-managed Mac doing it could get the user in trouble with their
  /// employer. So a directory that already exists is used as it is or not at all.
  @Test("An existing folder's permissions are never changed")
  func anExistingDirectorysPermissionsAreNeverChanged() throws {
    let sandbox = try Sandbox()
    defer { sandbox.tearDown() }
    try FileManager.default.createDirectory(
      at: sandbox.standardCandidate, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o755])

    let resolution = StorageRoot.resolve(
      systemApplicationSupport: sandbox.appSupport, home: sandbox.home)

    #expect(resolution.selection == .standard)
    #expect(try permissions(of: sandbox.standardCandidate) == 0o755)
  }

  // MARK: - Nowhere to go

  @Test("With no system lookup at all we still reach the home folder")
  func anAbsentSystemLookupStillResolvesToTheHomeFallback() throws {
    let sandbox = try Sandbox()
    defer { sandbox.tearDown() }

    let resolution = StorageRoot.resolve(systemApplicationSupport: nil, home: sandbox.home)

    #expect(resolution.selection == .homeFallback)
    #expect(resolution.dataDirectory == sandbox.fallbackCandidate)
    #expect(resolution.systemApplicationSupport == nil)
  }

  /// The honest terminal state. There is no third location, and inventing one
  /// would hide the failure rather than end it.
  @Test("When nothing accepts a write we say so and name what we tried")
  func nothingWritableReportsUnavailableAndListsWhatItTried() throws {
    let sandbox = try Sandbox()
    defer { sandbox.tearDown() }
    try sandbox.lock(sandbox.appSupport)
    try sandbox.lock(sandbox.home)

    let resolution = StorageRoot.resolve(
      systemApplicationSupport: sandbox.appSupport, home: sandbox.home)

    #expect(resolution.isUnavailable)
    #expect(resolution.exhausted == [sandbox.standardCandidate, sandbox.fallbackCandidate])
    // The standard path, so the eventual write fails with the path a person
    // would recognise rather than a temporary directory they have never seen.
    #expect(resolution.dataDirectory == sandbox.standardCandidate)
  }
}

/// The stores must not read a RESOLVED root until the verified data handoff
/// exists (#2695 PR 2).
///
/// Codex reproduced the consequence against the real resolver: an existing
/// installation whose data directory turns read-only commits an empty fallback,
/// `TranscriptStore` and `RecoverySpoolStore` then read only from there, and the
/// person's saved history and recoverable recordings leave the app while staying
/// on disk. Repairing the machine does not bring them back, because the chosen
/// root stays authoritative by design.
///
/// A comment saying "do not wire this yet" has no enforcer and would be deleted
/// by the first person who thought the wiring was obviously right. This fails
/// the build instead.
@Suite(.tags(.driftGuard))
struct StorageRootWiringGuardTests {

  @Test("The stores' path stays the plain standard directory until the handoff lands")
  func appSupportURLDoesNotReadTheResolvedRoot() throws {
    let source = try String(
      contentsOf: RepoRoot.sourceURL("Sources/EnviousWisprCore/Constants.swift"),
      encoding: .utf8)

    // Match the DECLARATION LINE, never the whole file. A whole-file match
    // cannot tell an ACTION on `StorageRoot.live` from PROSE about it, and the
    // doc comment on this very property explains at length why it does not use
    // `live` — so the file-wide version fired on the sentence saying the guard
    // holds. Same proxy defect the review rules name: comparing a RENDERING
    // when the question is REACHABILITY.
    let declaration = try #require(
      source.split(separator: "\n").first { $0.contains("static var appSupportURL") },
      "`AppConstants.appSupportURL` has been renamed or removed; this guard is now blind.")

    #expect(declaration.contains("StorageRoot.standardDirectory"))
    #expect(
      declaration.contains("StorageRoot.live") == false,
      """
      `AppConstants.appSupportURL` reaches every existing store. Pointing it at \
      a resolved root before the verified handoff exists removes a real user's \
      dictation history and recovery spools from the app. Ship the handoff in \
      the same change, or leave this pointing at the standard directory.
      """)
  }
}

/// Taking a root is a RACE between processes of this app, and a single-threaded
/// test cannot tell an atomic claim from a check-then-act one — both pass.
/// `validation-discipline.md`
/// RULE: a-single-threaded-test-cannot-distinguish-atomic-from-check-then-act
/// says the only way to test atomicity is to race it, so these do.
///
/// What is at stake: the old claim wrote a temporary file and renamed it into
/// place, and a rename overwrites unconditionally. Between one process reading a
/// root as free and writing its claim, another could commit an interrupted
/// handoff there — and the rename would destroy it, which is exactly what the
/// five readings of the record exist to prevent.
@Suite(.tags(.productOutcome))
struct StorageRootClaimRaceTests {

  /// Collects results from many threads. `@unchecked Sendable` because the lock
  /// is what makes it safe, and the compiler cannot see that.
  private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var outcomes: [StorageRoot.ClaimOutcome] = []
    func add(_ outcome: StorageRoot.ClaimOutcome) {
      lock.lock()
      outcomes.append(outcome)
      lock.unlock()
    }
  }

  private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ew-claim-race-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test("Exactly one of forty simultaneous claims wins")
  func fortySimultaneousClaimsProduceOneWinner() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let box = Box()

    DispatchQueue.concurrentPerform(iterations: 40) { _ in
      box.add(StorageRoot.claim(directory, as: .standard))
    }

    let outcomes = box.outcomes
    #expect(outcomes.count == 40)
    #expect(outcomes.filter { $0 == .claimed }.count == 1)
    #expect(outcomes.filter { $0 == .lostRace }.count == 39)
    #expect(outcomes.contains(.failed) == false)
  }

  /// **Weaker than its neighbours, and marked so the suite does not read as
  /// uniformly strong.** Measured: this case stays GREEN against the pre-fix
  /// rename-based claim, because a rename also leaves one whole readable
  /// record. It catches a TORN write, not a lost one. The two cases either side
  /// of it are what distinguish atomic from overwrite.
  @Test("Forty simultaneous claims leave one whole, readable record")
  func aRacedRootEndsWithOneIntactRecord() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    DispatchQueue.concurrentPerform(iterations: 40) { _ in
      _ = StorageRoot.claim(directory, as: .standard)
    }

    // Not "a file exists" — a file exists after a torn write too. The record has
    // to still decode, and the root has to still classify as ours.
    let data = try Data(
      contentsOf: directory.appendingPathComponent(StorageRoot.recordFileName))
    let record = try JSONDecoder().decode(StorageRoot.Record.self, from: data)
    #expect(record.selection == .standard)
    #expect(record.committed)
    #expect(StorageRoot.claimState(of: directory, expecting: .standard) == .committed)
  }

  /// The finding itself, single-threaded and structural: with a record already
  /// present, a claim must decline and write NOTHING. This is what makes the
  /// race safe rather than merely unlikely.
  @Test("A claim never writes over a half-finished move")
  func aClaimDeclinesRatherThanOverwriteAnInterruptedHandoff() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let recordURL = directory.appendingPathComponent(StorageRoot.recordFileName)
    try JSONEncoder().encode(
      StorageRoot.Record(selection: .standard, committed: false, createdAt: Date())
    ).write(to: recordURL)
    let before = try Data(contentsOf: recordURL)

    #expect(StorageRoot.claim(directory, as: .standard) == .lostRace)
    #expect(try Data(contentsOf: recordURL) == before)
  }
}
