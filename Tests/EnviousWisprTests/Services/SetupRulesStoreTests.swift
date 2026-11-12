import CryptoKit
import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprServices

/// A throwaway signing key for these tests only: the private half lives in this process and is
/// never written anywhere. Production pins its own key (`PinnedSetupRulesKey`).
enum SetupRulesTestKey: SetupRulesSigningKey {
  static let privateKey = Curve25519.Signing.PrivateKey()
  static var publicKeyBase64: String {
    privateKey.publicKey.rawRepresentation.base64EncodedString()
  }
  static func sign(_ payload: Data) -> Data {
    // swiftlint:disable:next force_try
    Data((try! privateKey.signature(for: payload)).base64EncodedString().appending("\n").utf8)
  }
}

/// A second throwaway key, to sign with the wrong key.
enum SetupRulesOtherKey: SetupRulesSigningKey {
  static let privateKey = Curve25519.Signing.PrivateKey()
  static var publicKeyBase64: String {
    privateKey.publicKey.rawRepresentation.base64EncodedString()
  }
}

/// #4528 B2: the Setup rules store refreshes only to signed, newer, valid rules.
///
/// **Product Outcome.** When this fails, a tampered or stale file on the website could change what
/// Setup recommends to every new user, an older publication could undo a newer one, a broken
/// download could leave a Mac without advice, or the app could ask the website more than once a
/// day. Every store uses a temporary folder, an injected clock and a fake transport.
@Suite(.tags(.productOutcome))
struct SetupRulesStoreTests {
  typealias Document = SignedSetupRules<SetupRulesTestKey>

  private static let start = Date(timeIntervalSince1970: 1_800_000_000)

  /// The bundled rules with a different revision (and optionally a re-ranked 16 GB pick).
  static func rules(revision: Int, sixteenPick: String = "eg1.mini") -> Data {
    Data(
      SetupRules.builtInJSON
        .replacingOccurrences(of: #""revision": 1"#, with: #""revision": \#(revision)"#)
        .replacingOccurrences(
          of: #"{"when": {"memoryAtLeastGiB": 16}, "pick": "eg1.mini"}"#,
          with: #"{"when": {"memoryAtLeastGiB": 16}, "pick": "\#(sixteenPick)"}"#
        ).utf8)
  }

  private static func reply(_ body: Data, url: URL, status: Int = 200) -> (
    response: HTTPURLResponse, body: Data
  ) {
    // swiftlint:disable:next force_unwrapping
    (HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, body)
  }

  private final class Folder {
    let url = TestTemporaryDirectory.url.appendingPathComponent(
      "setup-rules-\(UUID().uuidString)", isDirectory: true)
    var cache: URL { url.appendingPathComponent(Document.cacheFileName) }
    deinit { try? FileManager.default.removeItem(at: url) }
    func writeCache(_ data: Data) throws {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      try data.write(to: cache)
    }
  }

  private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
  }

  /// Answers the rules address and the signature address separately, and counts requests.
  private final class Site: @unchecked Sendable {
    private let lock = NSLock()
    private var payload: Data
    private var signature: Data?
    private var payloadStatus = 200
    private(set) var requests: [URL] = []
    init(payload: Data, signature: Data?) {
      self.payload = payload
      self.signature = signature
    }
    var count: Int { lock.withLock { requests.count } }
    var send: RemoteRules.Transport {
      { request, _ in
        let url = request.url ?? SetupRulesEndpoints.rules
        let (body, status): (Data?, Int) = self.lock.withLock {
          self.requests.append(url)
          if url == SetupRulesEndpoints.signature {
            return (self.signature, self.signature == nil ? 404 : 200)
          }
          return (self.payload, self.payloadStatus)
        }
        return SetupRulesStoreTests.reply(body ?? Data(), url: url, status: status)
      }
    }
  }

  private static func signedSite(_ payload: Data) -> Site {
    Site(payload: payload, signature: SetupRulesTestKey.sign(payload))
  }

  private func store(
    _ folder: Folder, bundled: Data = SetupRulesStoreTests.rules(revision: 1), site: Site,
    clock: Clock
  ) -> RemoteRulesStore<Document> {
    RemoteRulesStore(
      directory: folder.url, bundledData: { bundled }, transport: site.send, now: { clock.now })
  }

  // MARK: - Accepting signed, newer rules

  @Test("a signed higher revision is accepted, cached, and still in force after a relaunch")
  func signedNewerIsAccepted() async {
    let folder = Folder()
    let clock = Clock(Self.start)
    let site = Self.signedSite(Self.rules(revision: 3))
    let fresh = await store(folder, site: site, clock: clock).refreshIfDue()
    #expect(fresh.revision == 3 && fresh.origin == .downloaded)
    #expect(site.requests == [SetupRulesEndpoints.rules, SetupRulesEndpoints.signature])
    let relaunched = await store(folder, site: Site(payload: Data(), signature: nil), clock: clock)
      .current()
    #expect(relaunched.revision == 3 && relaunched.origin == .cached)
  }

  // MARK: - Rejections keep the trusted rules

  @Test("the wrong key, a changed payload or a missing or broken signature keep the trusted rules")
  func untrustedDownloadsAreRefused() async {
    let payload = Self.rules(revision: 5)
    let wrongKey = Data(
      (try! SetupRulesOtherKey.privateKey.signature(for: payload)).base64EncodedString().utf8)  // swiftlint:disable:this force_try
    let sites = [
      Site(payload: payload, signature: wrongKey),
      Site(payload: Self.rules(revision: 6), signature: SetupRulesTestKey.sign(payload)),
      Site(payload: payload, signature: nil),
      Site(payload: payload, signature: Data("not base64!".utf8)),
    ]
    for site in sites {
      let result = await store(Folder(), site: site, clock: Clock(Self.start)).refreshIfDue()
      #expect(
        result.revision == 1 && result.origin == .bundled, "an untrusted download was admitted")
    }
  }

  @Test("signed rules that fail validation keep the trusted rules")
  func signedButInvalidIsRefused() async {
    let badSchema = Data(
      String(decoding: Self.rules(revision: 4), as: UTF8.self)
        .replacingOccurrences(of: #""schema": 1"#, with: #""schema": 2"#).utf8)
    let afmPick = Self.rules(revision: 4, sixteenPick: "appleIntelligence")
    let unknown = Self.rules(revision: 4, sixteenPick: "eg1.huge")
    for payload in [badSchema, afmPick, unknown] {
      let result = await store(Folder(), site: Self.signedSite(payload), clock: Clock(Self.start))
        .refreshIfDue()
      #expect(result.revision == 1 && result.origin == .bundled)
    }
  }

  @Test("an equal or lower revision never replaces the trusted rules")
  func equalOrLowerIsRefused() async {
    let folder = Folder()
    let clock = Clock(Self.start)
    _ = await store(folder, site: Self.signedSite(Self.rules(revision: 4)), clock: clock)
      .refreshIfDue()
    for revision in [4, 3, 1] {
      clock.advance(2 * RemoteRules.refreshInterval)
      let result = await store(
        folder, site: Self.signedSite(Self.rules(revision: revision)), clock: clock
      ).refreshIfDue()
      #expect(result.revision == 4, "revision \(revision) replaced revision 4")
    }
  }

  // MARK: - Choosing between the bundle and the cache

  @Test("offline, the higher of bundle and cache answers at once, and the bundle wins a tie")
  func offlineSelection() async throws {
    let higher = Folder()
    let unit = try SetupRulesCacheUnit(
      payload: Self.rules(revision: 3), signature: SetupRulesTestKey.sign(Self.rules(revision: 3))
    ).encoded()
    try higher.writeCache(unit)
    let site = Site(payload: Data(), signature: nil)
    let fromCache = await store(
      higher, bundled: Self.rules(revision: 2), site: site, clock: Clock(Self.start)
    ).current()
    #expect(fromCache.revision == 3 && fromCache.origin == .cached)
    let tie = await store(
      higher, bundled: Self.rules(revision: 3), site: site, clock: Clock(Self.start)
    ).current()
    #expect(tie.origin == .bundled, "a tie must keep the bundled copy")
    #expect(site.count == 0, "current() must not touch the network")
  }

  @Test("a tampered cache is not trusted: the bundle answers")
  func tamperedCacheFallsBack() async throws {
    let folder = Folder()
    let signedThree = SetupRulesTestKey.sign(Self.rules(revision: 3))
    // Mixed pair: revision 9's payload with revision 3's signature.
    let mixed = try SetupRulesCacheUnit(payload: Self.rules(revision: 9), signature: signedThree)
      .encoded()
    try folder.writeCache(mixed)
    let result = await store(
      folder, site: Site(payload: Data(), signature: nil), clock: Clock(Self.start)
    ).current()
    #expect(result.revision == 1 && result.origin == .bundled)
    try folder.writeCache(Data("not a cache unit".utf8))
    let garbage = await store(
      folder, site: Site(payload: Data(), signature: nil), clock: Clock(Self.start)
    ).current()
    #expect(garbage.origin == .bundled)
  }

  @Test("with neither a valid bundle nor a cache, the compiled copy answers")
  func builtInWhenNothingIsValid() async {
    let result = await store(
      Folder(), bundled: Data("broken".utf8), site: Site(payload: Data(), signature: nil),
      clock: Clock(Self.start)
    ).current()
    #expect(result.origin == .empty && result.rules == SetupRules.builtIn)
  }

  @Test("a failed refresh keeps the valid cache")
  func failedRefreshKeepsCache() async {
    let folder = Folder()
    let clock = Clock(Self.start)
    _ = await store(folder, site: Self.signedSite(Self.rules(revision: 3)), clock: clock)
      .refreshIfDue()
    clock.advance(2 * RemoteRules.refreshInterval)
    let failing = Site(payload: Self.rules(revision: 8), signature: Data("bad".utf8))
    let result = await store(folder, site: failing, clock: clock).refreshIfDue()
    #expect(result.revision == 3 && result.origin == .cached)
  }

  // MARK: - Daily limit and shared work

  @Test("the daily limit survives a relaunch")
  func dailyLimitSurvivesRelaunch() async {
    let folder = Folder()
    let clock = Clock(Self.start)
    let site = Self.signedSite(Self.rules(revision: 2))
    _ = await store(folder, site: site, clock: clock).refreshIfDue()
    clock.advance(60 * 60)
    _ = await store(folder, site: site, clock: clock).refreshIfDue()
    #expect(
      site.count == 2, "one refresh is two requests (rules and signature); a second refresh ran")
  }

  @Test("concurrent refreshes share one download")
  func concurrentRefreshesShare() async {
    let site = Self.signedSite(Self.rules(revision: 2))
    let store = store(Folder(), site: site, clock: Clock(Self.start))
    async let a = store.refreshIfDue()
    async let b = store.refreshIfDue()
    let (x, y) = await (a, b)
    #expect(x.revision == 2 && y.revision == 2)
    #expect(site.count == 2, "two refreshes made \(site.count) requests")
  }

  // MARK: - Rollback

  /// Plan §12: deleting the website file does not clear a client cache; a higher revision that
  /// restores the bundled rows does.
  @Test("a higher revision that restores the bundled rows rolls a cached change back")
  func higherRevisionRollsBack() async {
    let folder = Folder()
    let clock = Clock(Self.start)
    let changed = await store(
      folder, site: Self.signedSite(Self.rules(revision: 3, sixteenPick: "eg1.full")), clock: clock
    ).refreshIfDue()
    #expect(changed.rules.polishPrimary[1].pick == "eg1.full")
    clock.advance(2 * RemoteRules.refreshInterval)
    let restored = await store(folder, site: Self.signedSite(Self.rules(revision: 4)), clock: clock)
      .refreshIfDue()
    #expect(restored.revision == 4)
    #expect(
      restored.rules.polishPrimary == SetupRules.builtIn.polishPrimary,
      "the rollback did not restore the bundled rows")
  }

  // MARK: - Python and Swift agree

  @Test("a signature made by the signing tool verifies in the app")
  func interopFixtureVerifies() throws {
    let dir = RepoRoot.url.appending(path: "scripts/setup-rules/fixtures/interop")
    let payload = try Data(contentsOf: dir.appending(path: "payload.json"))
    let signature = try Data(contentsOf: dir.appending(path: "payload.json.sig"))
    let key = try String(contentsOf: dir.appending(path: "public-key.txt"), encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    try SetupRulesSignature.verify(payload: payload, signatureText: signature, publicKeyBase64: key)
    #expect(throws: SetupRulesSignature.Failure.signatureMismatch) {
      try SetupRulesSignature.verify(
        payload: payload + Data("\n".utf8), signatureText: signature, publicKeyBase64: key)
    }
  }

  // MARK: - Size bounds and refresh outcomes

  /// A valid rules file just under the 64 KB payload cap, padded with extra (valid) polish rows
  /// before the catch-all. Its cache unit is larger than 64 KB, so it must still read back.
  static func largeRules(revision: Int) -> Data {
    let row = #"{"when": {"memoryAtLeastGiB": 512}, "pick": "eg1.full"},"#
    var text = String(decoding: rules(revision: revision), as: UTF8.self)
    let anchor = #""primary": ["#
    var padding = ""
    while text.utf8.count + padding.utf8.count + row.utf8.count < Document.maximumBytes - 64 {
      padding += "\n      " + row
    }
    text = text.replacingOccurrences(of: anchor, with: anchor + padding)
    return Data(text.utf8)
  }

  @Test("a signed rules file near the payload cap is accepted and still trusted after a relaunch")
  func nearLimitPayloadSurvivesRelaunch() async throws {
    let payload = Self.largeRules(revision: 3)
    #expect(payload.count > Document.maximumBytes - 200 && payload.count <= Document.maximumBytes)
    _ = try SetupRules.validated(from: payload)
    let folder = Folder()
    let clock = Clock(Self.start)
    let fresh = await store(folder, site: Self.signedSite(payload), clock: clock).refreshIfDue()
    #expect(fresh.revision == 3)
    let cacheSize = try Data(contentsOf: folder.cache).count
    #expect(cacheSize > Document.maximumBytes, "the cache unit should be larger than the payload cap")
    let relaunched = await store(folder, site: Site(payload: Data(), signature: nil), clock: clock).current()
    #expect(relaunched.revision == 3 && relaunched.origin == .cached, "a valid large download was lost on relaunch")
  }

  @Test("each refresh records a bounded reason for how it ended")
  func refreshOutcomes() async {
    func outcome(_ site: Site, folder: Folder = Folder()) async -> RemoteRulesRefreshOutcome? {
      let subject = store(folder, site: site, clock: Clock(Self.start))
      _ = await subject.refreshIfDue()
      return await subject.lastRefreshOutcome()
    }
    #expect(await outcome(Self.signedSite(Self.rules(revision: 2))) == .accepted)
    #expect(await outcome(Site(payload: Self.rules(revision: 2), signature: nil)) == .signatureUnavailable)
    #expect(await outcome(Site(payload: Self.rules(revision: 2), signature: Data("bad".utf8))) == .invalid)
    #expect(await outcome(Self.signedSite(Self.rules(revision: 1))) == .notNewer)
    let offlineStore = RemoteRulesStore<Document>(
      directory: Folder().url, bundledData: { Self.rules(revision: 1) },
      transport: { _, _ in throw URLError(.notConnectedToInternet) }, now: { Self.start })
    _ = await offlineStore.refreshIfDue()
    #expect(await offlineStore.lastRefreshOutcome() == .transportFailed)
    _ = await offlineStore.refreshIfDue()
    #expect(await offlineStore.lastRefreshOutcome() == .notDue)
  }

  // MARK: - The synchronous holder (SetupAdvice's rules in force)

  private func signedUnit(_ revision: Int) throws -> Data {
    try SetupRulesCacheUnit(
      payload: Self.rules(revision: revision),
      signature: SetupRulesTestKey.sign(Self.rules(revision: revision))
    ).encoded()
  }

  @Test("the synchronous selection and the store's first answer pick the same trusted rules")
  func synchronousSelectionMatchesStore() async throws {
    let offline = Site(payload: Data(), signature: nil)
    let mixed = try SetupRulesCacheUnit(
      payload: Self.rules(revision: 9), signature: SetupRulesTestKey.sign(Self.rules(revision: 3))
    ).encoded()
    let oversized = Data(repeating: 0x20, count: Document.maximumCacheBytes + 1)
    // (cache file, bundled copy, expected revision, expected origin)
    let cases: [(Data?, Data, Int, RemoteRulesOrigin)] = [
      (nil, Self.rules(revision: 2), 2, .bundled),
      (try signedUnit(3), Self.rules(revision: 2), 3, .cached),
      (try signedUnit(3), Self.rules(revision: 3), 3, .bundled),
      (mixed, Self.rules(revision: 2), 2, .bundled),
      (oversized, Self.rules(revision: 2), 2, .bundled),
      (Data("not a cache unit".utf8), Self.rules(revision: 2), 2, .bundled),
      (nil, Data("broken".utf8), SetupRules.builtIn.revision, .empty),
    ]
    for (index, (cache, bundled, revision, origin)) in cases.enumerated() {
      let folder = Folder()
      if let cache { try folder.writeCache(cache) }
      let subject = store(folder, bundled: bundled, site: offline, clock: Clock(Self.start))
      let synchronous = subject.trustedLocalDocument()
      let isolated = await subject.current()
      #expect(synchronous == isolated, "case \(index): the two reads chose different rules")
      #expect(
        synchronous.revision == revision && synchronous.origin == origin,
        "case \(index): chose revision \(synchronous.revision) from \(synchronous.origin)")
    }
    #expect(offline.count == 0, "a local read must not touch the network")
  }

  @Test("the holder answers a higher signed cache on its first read, before any refresh")
  func holderSeedsFromSignedCache() throws {
    let folder = Folder()
    try folder.writeCache(try signedUnit(3))
    let site = Site(payload: Data(), signature: nil)
    let holder = SetupRulesHolder(
      store: store(folder, bundled: Self.rules(revision: 2), site: site, clock: Clock(Self.start)))
    let first = holder.document
    #expect(first.revision == 3 && first.origin == .cached)
    // Later reads use memory: removing the cache does not change the rules in force.
    try FileManager.default.removeItem(at: folder.cache)
    #expect(holder.document == first)
    #expect(site.count == 0)
  }

  @Test("the holder moves up to a newer signed download and never down")
  func holderMovesOnlyUp() async throws {
    let folder = Folder()
    let clock = Clock(Self.start)
    let up = SetupRulesHolder(
      store: store(folder, site: Self.signedSite(Self.rules(revision: 4)), clock: clock))
    #expect(up.document.revision == 1 && up.document.origin == .bundled)
    await up.refreshIfDue()
    #expect(up.document.revision == 4 && up.document.origin == .downloaded)

    // Seeded from a signed revision-3 cache that then goes bad on disk (the store itself would
    // now choose the bundled revision 1). A failed refresh, and a valid signed revision 2, both
    // leave revision 3 in force, and revision 2 is refused as not newer and never cached.
    let cases: [(Site, RemoteRulesRefreshOutcome)] = [
      (Site(payload: Data(), signature: nil), .signatureUnavailable),
      (Self.signedSite(Self.rules(revision: 2)), .notNewer),
    ]
    for (site, expected) in cases {
      let damaged = Folder()
      try damaged.writeCache(try signedUnit(3))
      let subject = store(damaged, site: site, clock: clock)
      let down = SetupRulesHolder(store: subject)
      #expect(down.document.revision == 3)
      let garbage = Data("not a cache unit".utf8)
      try damaged.writeCache(garbage)
      await down.refreshIfDue()
      #expect(down.document.revision == 3 && down.document.origin == .cached)
      #expect(await subject.current().revision == 3, "the store's baseline fell below the holder")
      #expect(await subject.lastRefreshOutcome() == expected)
      #expect(try Data(contentsOf: damaged.cache) == garbage, "a lower revision was cached")
    }
  }

  @Test("concurrent reads during a refresh always see rules and origin from one document")
  func holderReadsArePaired() async {
    let holder = SetupRulesHolder(
      store: store(
        Folder(), site: Self.signedSite(Self.rules(revision: 4)), clock: Clock(Self.start)))
    let seen = await withTaskGroup(of: [SignedSetupRules<SetupRulesTestKey>].self) { group in
      group.addTask {
        await holder.refreshIfDue()
        return [holder.document]
      }
      for _ in 0..<8 {
        group.addTask { (0..<50).map { _ in holder.document } }
      }
      var all: [SignedSetupRules<SetupRulesTestKey>] = []
      for await batch in group { all += batch }
      return all
    }
    for document in seen {
      let paired =
        (document.revision == 1 && document.origin == .bundled)
        || (document.revision == 4 && document.origin == .downloaded)
      #expect(paired, "revision \(document.revision) arrived with origin \(document.origin)")
      #expect(document.rules.revision == document.revision)
    }
    #expect(holder.document.revision == 4)
  }
}
