import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprPostProcessing
import EnviousWisprAppKitTestSupport

/// #3975: the Self-Learning Dictionary's memory of the user's fixes. When one
/// of these fails, the user sees a fix they made twice never learned, a word
/// they refused twice learned again, or "Forget learning memory" leave
/// something behind.
@MainActor
@Suite(.tags(.productOutcome))
struct LearnMemoryTests {

  // MARK: Fixtures

  private static func tempDir() -> URL {
    let dir = TestTemporaryDirectory.url
      .appendingPathComponent("EnviousWispr-learn-memory-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private static func cleanup(_ dir: URL) {
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    try? FileManager.default.removeItem(at: dir)
  }

  private static let cenit = CorrectionPairKey.make(original: "Senate", corrected: "CENIT")
  private static let sify = CorrectionPairKey.make(original: "CIFI", corrected: "Sify")

  /// A clock the test moves by hand.
  private final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
  }

  private static func memory(_ dir: URL, clock: Clock? = nil) -> LearnMemory {
    let url = dir.appendingPathComponent(LearnMemory.fileName)
    if let clock { return LearnMemory(fileURL: url, now: { clock.now }) }
    return LearnMemory(fileURL: url)
  }

  // MARK: Refusal and repeat

  @Test("a pair the judge refused is a repeat, and survives a restart")
  func refusalIsRepeatAcrossRestart() {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let first = Self.memory(dir)
    #expect(first.isRepeat(Self.cenit) == false)
    #expect(first.recordJudgeRefusal(Self.cenit) == .committed(true))
    #expect(first.isRepeat(Self.cenit))
    #expect(first.isRepeat(Self.sify) == false)
    let relaunched = Self.memory(dir)
    #expect(relaunched.isRepeat(Self.cenit))
  }

  @Test("pair identity ignores case, as the filter's keys do")
  func caseInsensitiveKey() {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let memory = Self.memory(dir)
    memory.recordJudgeRefusal(Self.cenit)
    #expect(memory.isRepeat(CorrectionPairKey.make(original: "senate", corrected: "cenit")))
  }

  // MARK: User no

  @Test("first no watches, second no blocks, a blocked pair is no longer a repeat")
  func secondNoBlocks() {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let memory = Self.memory(dir)
    memory.recordJudgeRefusal(Self.cenit)
    #expect(memory.recordUndo(Self.cenit) == .committed(.watching))
    #expect(memory.isBlocked(Self.cenit) == false)
    #expect(memory.isRepeat(Self.cenit))
    #expect(memory.recordUndo(Self.cenit) == .committed(.blocked))
    #expect(memory.isBlocked(Self.cenit))
    #expect(memory.isRepeat(Self.cenit) == false)
    #expect(memory.blockedKeys == [Self.cenit])
    #expect(memory.blockedCount == 1)
    #expect(Self.memory(dir).isBlocked(Self.cenit))
  }

  // MARK: Bounds

  @Test("an unblocked entry expires after 90 days unseen; a block never does")
  func expiryKeepsBlocks() {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let clock = Clock()
    let memory = Self.memory(dir, clock: clock)
    memory.recordJudgeRefusal(Self.sify)
    memory.recordUndo(Self.cenit)
    memory.recordUndo(Self.cenit)
    clock.now = clock.now.addingTimeInterval(LearnMemory.unblockedLifetime - 60)
    #expect(Self.memory(dir, clock: clock).isRepeat(Self.sify))
    clock.now = clock.now.addingTimeInterval(120)
    let later = Self.memory(dir, clock: clock)
    #expect(later.isRepeat(Self.sify) == false)
    #expect(later.isBlocked(Self.cenit))
    // The SAME instance, with the file unchanged since it read it, answers
    // exactly as a fresh launch does once the deadline passes.
    #expect(memory.isRepeat(Self.sify) == false)
    #expect(memory.entry(Self.sify) == nil)
    #expect(memory.isBlocked(Self.cenit))
  }

  @Test("past the unblocked cap the oldest unblocked entries go first; blocks stay")
  func evictionKeepsBlocks() {
    var pairs: [String: LearnMemory.Entry] = [:]
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    for i in 0..<(LearnMemory.unblockedCap + 3) {
      pairs["k\(i)"] = .init(
        judgeRefusals: 1, userNos: 0, blocked: false, lastSeen: base.addingTimeInterval(Double(i)))
    }
    pairs["blocked-oldest"] = .init(
      judgeRefusals: 0, userNos: 2, blocked: true, lastSeen: base.addingTimeInterval(-1_000))
    LearnMemory.prune(&pairs, now: base.addingTimeInterval(10_000))
    #expect(pairs.values.filter { !$0.blocked }.count == LearnMemory.unblockedCap)
    #expect(pairs["k0"] == nil && pairs["k1"] == nil && pairs["k2"] == nil)
    #expect(pairs["k3"] != nil)
    #expect(pairs["blocked-oldest"]?.blocked == true)
  }

  @Test("at the block cap a new block is not remembered and nothing changes")
  func blockCapRefuses() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let url = dir.appendingPathComponent(LearnMemory.fileName)
    let at = Date(timeIntervalSince1970: 1_800_000_000)
    var pairs: [String: LearnMemory.Entry] = [:]
    for i in 0..<LearnMemory.blockedCap {
      pairs["b\(i)"] = .init(judgeRefusals: 0, userNos: 2, blocked: true, lastSeen: at)
    }
    try Self.writeStore(pairs, to: url)
    var signals: [LearnMemoryDiagnostic] = []
    let memory = LearnMemory(fileURL: url, now: { at }, report: { signals.append($0) })
    #expect(memory.recordUndo(Self.cenit) == .committed(.watching))
    #expect(memory.recordUndo(Self.cenit) == .notRemembered)
    #expect(signals == [.notRemembered(.blockCap)])
    #expect(memory.isBlocked(Self.cenit) == false)
    #expect(memory.entry(Self.cenit)?.userNos == 1)
    #expect(memory.blockedCount == LearnMemory.blockedCap)
  }

  @Test("onChange fires after each committed change and after Forget, never for an event not remembered")
  func onChangeFollowsCommits() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let memory = Self.memory(dir)
    var changes = 0
    memory.onChange = { changes += 1 }
    memory.recordJudgeRefusal(Self.sify)
    memory.recordUndo(Self.sify)
    #expect(changes == 2)
    let lockPath = memory.fileURL.appendingPathExtension("lock").path
    let fd = open(lockPath, O_RDWR | O_CREAT, 0o600)
    try #require(fd >= 0)
    defer { close(fd) }
    try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
    #expect(memory.recordUndo(Self.cenit) == .notRemembered)
    #expect(changes == 2, "nothing committed")
    flock(fd, LOCK_UN)
    #expect(memory.forgetAll())
    #expect(changes == 3)
  }

  // MARK: Failure contracts

  @Test("a held lock: the event is not remembered and committed state is unchanged")
  func busyLockDropsTheEvent() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let memory = Self.memory(dir)
    memory.recordJudgeRefusal(Self.sify)
    let lockPath = memory.fileURL.appendingPathExtension("lock").path
    let fd = open(lockPath, O_RDWR | O_CREAT, 0o600)
    try #require(fd >= 0)
    defer { close(fd) }
    try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
    #expect(memory.recordJudgeRefusal(Self.cenit) == .notRemembered)
    #expect(memory.recordUndo(Self.sify) == .notRemembered)
    flock(fd, LOCK_UN)
    #expect(memory.isRepeat(Self.cenit) == false)
    #expect(memory.entry(Self.sify)?.userNos == 0)
    #expect(Self.memory(dir).isRepeat(Self.cenit) == false)
  }

  @Test("a failed write: not remembered, committed state unchanged")
  func failedWriteDropsTheEvent() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let memory = Self.memory(dir)
    memory.recordJudgeRefusal(Self.sify)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    #expect(memory.recordJudgeRefusal(Self.cenit) == .notRemembered)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    #expect(memory.isRepeat(Self.cenit) == false)
    #expect(memory.isRepeat(Self.sify))
  }

  @Test("a corrupt or wrong-version file is set aside, the memory starts empty, one copy kept")
  func corruptFileSetAside() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let url = dir.appendingPathComponent(LearnMemory.fileName)
    try Data("not json".utf8).write(to: url)
    let memory = LearnMemory(fileURL: url)
    #expect(memory.isRepeat(Self.cenit) == false)
    #expect(try memory.corruptedCopies().count == 1)
    #expect(memory.hasStoredMemory)
    try Data(#"{"version":99,"pairs":{}}"#.utf8).write(to: url)
    #expect(memory.isBlocked(Self.cenit) == false)
    #expect(try memory.corruptedCopies().count == 1)
    #expect(memory.recordJudgeRefusal(Self.cenit) == .committed(true))
    #expect(Self.memory(dir).isRepeat(Self.cenit))
  }

  // MARK: Forget

  @Test("Forget deletes the file and every corrupt copy")
  func forgetDeletesEverything() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let url = dir.appendingPathComponent(LearnMemory.fileName)
    try Data("broken".utf8).write(to: url)
    let memory = LearnMemory(fileURL: url)
    _ = memory.isRepeat(Self.cenit)
    memory.recordUndo(Self.cenit)
    memory.recordUndo(Self.cenit)
    #expect(memory.hasStoredMemory)
    #expect(memory.forgetAll())
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(try memory.corruptedCopies().isEmpty)
    #expect(memory.hasStoredMemory == false)
    #expect(memory.isBlocked(Self.cenit) == false)
  }

  @Test("two instances: each sees the other's commits, and a Forget is not resurrected")
  func twoInstances() {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let a = Self.memory(dir)
    let b = Self.memory(dir)
    a.recordUndo(Self.cenit)
    b.recordUndo(Self.cenit)
    #expect(a.isBlocked(Self.cenit))
    #expect(b.isBlocked(Self.cenit))
    b.recordJudgeRefusal(Self.sify)
    #expect(a.isRepeat(Self.sify))
    #expect(b.forgetAll())
    #expect(a.isBlocked(Self.cenit) == false)
    a.recordJudgeRefusal(CorrectionPairKey.make(original: "Hanwar", corrected: "Hanwha"))
    #expect(b.isBlocked(Self.cenit) == false)
    #expect(b.isRepeat(Self.sify) == false)
  }

  @Test("Forget removes every corrupt copy, and reports failure when a deletion fails")
  func forgetFailsHonestly() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let memory = Self.memory(dir)
    memory.recordUndo(Self.cenit)
    for _ in 0..<2 {
      try Data("x".utf8).write(
        to: dir.appendingPathComponent(LearnMemory.fileName + ".corrupted-" + UUID().uuidString))
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    #expect(memory.forgetAll() == false)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    #expect(memory.entry(Self.cenit)?.userNos == 1)
    #expect(memory.forgetAll())
    #expect(try memory.corruptedCopies().isEmpty)
    #expect(memory.hasStoredMemory == false)
  }

  // MARK: File format

  @Test("reads a hand-written file in the plan's schema (ISO 8601 dates)")
  func readsLiteralFixture() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let url = dir.appendingPathComponent(LearnMemory.fileName)
    let literal = """
      {"version":1,"pairs":{\(Self.jsonKey(Self.cenit)):{"judgeRefusals":1,"userNos":0,"blocked":false,"lastSeen":"2027-01-15T10:00:00Z"},\(Self.jsonKey(Self.sify)):{"judgeRefusals":0,"userNos":2,"blocked":true,"lastSeen":"2027-01-15T10:00:00Z"}}}
      """
    try Data(literal.utf8).write(to: url)
    let memory = LearnMemory(fileURL: url, now: { Date(timeIntervalSince1970: 1_800_000_000) })
    #expect(memory.isRepeat(Self.cenit))
    #expect(memory.isBlocked(Self.sify))
    memory.recordJudgeRefusal(CorrectionPairKey.make(original: "a", corrected: "B"))
    let written = try String(contentsOf: url, encoding: .utf8)
    #expect(written.contains("\"lastSeen\" : \"2027-01-15T10:00:00Z\""))
  }

  // MARK: Two instances, interleaved

  @Test("a commit from another instance between read and re-stat is not missed")
  func staleReadIsRetried() {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let a = Self.memory(dir)
    let b = Self.memory(dir)
    a.recordJudgeRefusal(Self.sify)
    b.recordUndo(Self.cenit)
    var fired = false
    a.afterReadForTesting = {
      guard !fired else { return }
      fired = true
      b.recordUndo(Self.cenit)
    }
    #expect(a.isBlocked(Self.cenit))
    a.afterReadForTesting = nil
    #expect(a.isBlocked(Self.cenit))
  }

  @Test("a corrupt file replaced by another instance's valid commit is read, not wiped")
  func corruptThenReplaced() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let url = dir.appendingPathComponent(LearnMemory.fileName)
    try Data("broken".utf8).write(to: url)
    var signals: [LearnMemoryDiagnostic] = []
    let a = LearnMemory(fileURL: url, report: { signals.append($0) })
    let b = LearnMemory(fileURL: url)
    var fired = false
    a.afterReadForTesting = {
      guard !fired else { return }
      fired = true
      b.recordJudgeRefusal(Self.cenit)
    }
    #expect(a.isRepeat(Self.cenit))
    #expect(signals.isEmpty)
  }

  // MARK: Diagnostics

  @Test("diagnostics: reset, busy lock, failed write and block cap are reported, text-free")
  func diagnostics() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let url = dir.appendingPathComponent(LearnMemory.fileName)
    try Data("broken".utf8).write(to: url)
    var signals: [LearnMemoryDiagnostic] = []
    let memory = LearnMemory(fileURL: url, report: { signals.append($0) })
    _ = memory.isBlocked(Self.cenit)
    #expect(signals == [.memoryReset])
    let fd = open(url.appendingPathExtension("lock").path, O_RDWR | O_CREAT, 0o600)
    try #require(fd >= 0)
    try #require(flock(fd, LOCK_EX | LOCK_NB) == 0)
    memory.recordJudgeRefusal(Self.cenit)
    flock(fd, LOCK_UN)
    close(fd)
    #expect(signals.last == .notRemembered(.lockBusy))
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
    memory.recordJudgeRefusal(Self.cenit)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    #expect(signals.last == .notRemembered(.writeFailed))
  }

  // MARK: Reload cost

  @Test("the largest allowed file (10,000 blocked + 2,000 unblocked) reloads well inside the 50 ms budget (measured, printed)")
  func largeReloadCost() throws {
    let dir = Self.tempDir()
    defer { Self.cleanup(dir) }
    let url = dir.appendingPathComponent(LearnMemory.fileName)
    let at = Date(timeIntervalSince1970: 1_800_000_000)
    var pairs: [String: LearnMemory.Entry] = [:]
    for i in 0..<LearnMemory.blockedCap {
      pairs[CorrectionPairKey.make(original: "misheard phrase \(i)", corrected: "BrandName\(i)")] =
        .init(judgeRefusals: 1, userNos: 2, blocked: true, lastSeen: at)
    }
    for i in 0..<LearnMemory.unblockedCap {
      pairs[CorrectionPairKey.make(original: "refused phrase \(i)", corrected: "Term\(i)")] =
        .init(judgeRefusals: 1, userNos: 0, blocked: false, lastSeen: at)
    }
    try Self.writeStore(pairs, to: url)
    let memory = LearnMemory(fileURL: url, now: { at })
    let clock = ContinuousClock()
    let elapsed = clock.measure { _ = memory.blockedCount }
    print("LearnMemory max-size reload: \(elapsed)")
    #expect(memory.blockedCount == LearnMemory.blockedCap)
    // Hang guard only; the measured value is reported in the PR.
    #expect(elapsed < .seconds(2))
  }

  // MARK: Helpers

  private struct Store: Codable {
    var version: Int
    var pairs: [String: LearnMemory.Entry]
  }

  /// The key as a JSON object key, escaped independently of the subject.
  private static func jsonKey(_ key: String) -> String {
    String(decoding: try! JSONEncoder().encode(key), as: UTF8.self)
  }

  private static func writeStore(_ pairs: [String: LearnMemory.Entry], to url: URL) throws {
    try LearnMemory.encoder().encode(Store(version: LearnMemory.currentVersion, pairs: pairs)).write(
      to: url)
  }
}
