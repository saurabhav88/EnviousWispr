import Foundation
import Testing

@testable import EnviousWisprASR
@testable import EnviousWisprAppKit

/// #1741 Chunk 6 — pins the gate-refusal contract for `ModelDeliveryHome`'s
/// two Settings-row mutation sites (Parakeet Cancel/Resume).
@MainActor
@Suite("ModelDeliveryHome — engine mutation gate refusal")
struct ModelDeliveryHomeTests {

  /// Production's trust root is the signed app's own `Bundle.main` (contract
  /// §4a), which a unit-test process cannot see — these resources ride the
  /// `EnviousWispr` app target, not any framework or test bundle. Rather than
  /// author a divergent fixture, point at a `Bundle` over the SAME committed
  /// manifest files `ModelDeliveryHome` loads in production. Same repo-root
  /// discovery as `ParakeetShippedManifestTests.repoRoot`
  /// (`Tests/EnviousWisprTests/ModelDelivery/DeliveryManifestTests.swift`).
  private static func manifestBundle() throws -> Bundle {
    let repoRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // (file)
      .deletingLastPathComponent()  // App
      .deletingLastPathComponent()  // EnviousWisprTests
      .deletingLastPathComponent()  // Tests
    let resourcesDir = repoRoot.appendingPathComponent("Sources/EnviousWispr/Resources")
    return try #require(Bundle(url: resourcesDir))
  }

  /// A throwaway Application Support root, one per call.
  ///
  /// Construction runs a no-fetch delivery PROBE (#2123 whole-diff review), and a
  /// probe that finds a complete cache WRITES an admission marker. Pointed at the
  /// real Application Support, that makes this suite mutate the developer's own
  /// machine as a side effect of running — and on a machine where another process
  /// is measuring those markers, it plants a false row in their data rather than
  /// merely being untidy. Every construction site here takes its own root.
  ///
  /// Not deleted afterwards: these live under the system temp directory, which
  /// the OS reaps, and a `defer` per site would fire while the async work the
  /// constructor kicked off is still running.
  private static func tempAppSupport() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("ew-2123-mdh-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  @Test("a gate-refused cancel reports the site and never releases or wakes")
  func aGateRefusedCancelReportsTheSiteAndNeverReleasesOrWakes() async throws {
    final class Box: @unchecked Sendable {
      var endCalls = 0
      var wakeCalls = 0
      var refusedSites: [String] = []
    }
    let box = Box()
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { false },
        end: {
          box.endCalls += 1
          return false
        },
        wake: { box.wakeCalls += 1 },
        onRefused: { box.refusedSites.append($0) }),
      manifestBundle: try Self.manifestBundle(),
      appSupportOverride: try Self.tempAppSupport())

    home.cancelParakeetDownload()
    // Signal, not clock: wait for the gate's own refusal telemetry, proving
    // the Task actually reached and was refused by the claim, before
    // asserting the negatives that a refusal implies.
    for _ in 0..<200 where box.refusedSites.isEmpty { await Task.yield() }

    #expect(box.refusedSites == ["parakeetCancelDownload"])
    #expect(box.endCalls == 0, "a refused claim is never released")
    #expect(box.wakeCalls == 0, "a refused claim never owes a wake")
  }

  /// The flag store is INJECTED and explicitly ENABLED, which this test did not
  /// need before #2139 and does now. `resumeParakeetDownload` reads the parakeet
  /// family kill switch, so without an injected suite it reads the real
  /// operational one — and on a machine where a developer has that switch set
  /// false the door refuses before the claim and this test fails on MACHINE
  /// STATE rather than on code. Found by cloud review; the omission was harmless
  /// only for as long as this door read no flag.
  @Test("a gate-refused resume reports the site and never releases or wakes")
  func aGateRefusedResumeReportsTheSiteAndNeverReleasesOrWakes() async throws {
    final class Box: @unchecked Sendable {
      var endCalls = 0
      var wakeCalls = 0
      var refusedSites: [String] = []
    }
    let box = Box()
    let suite = try #require(UserDefaults(suiteName: "ew-2139-resume-\(UUID().uuidString)"))
    suite.set(true, forKey: "modelDelivery.parakeet.enabled")
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { false },
        end: {
          box.endCalls += 1
          return false
        },
        wake: { box.wakeCalls += 1 },
        onRefused: { box.refusedSites.append($0) }),
      manifestBundle: try Self.manifestBundle(),
      appSupportOverride: try Self.tempAppSupport(),
      deliveryFlagDefaults: suite)

    home.resumeParakeetDownload()
    // Signal, not clock: wait for the gate's own refusal telemetry, proving
    // the Task actually reached and was refused by the claim, before
    // asserting the negatives that a refusal implies.
    for _ in 0..<200 where box.refusedSites.isEmpty { await Task.yield() }

    #expect(box.refusedSites == ["parakeetResumeDownload"])
    #expect(box.endCalls == 0, "a refused claim is never released")
    #expect(box.wakeCalls == 0, "a refused claim never owes a wake")
  }

  // MARK: - #2108: the Live Preview universal model registration

  /// The whole point of chunk 4a, and the one thing in it that can destroy data.
  ///
  /// `CacheAdmission` treats an install directory as exhaustive truth and deletes
  /// every top-level entry the active manifest does not list. If both WhisperKit
  /// registrations pointed at one directory, admitting either model would delete
  /// the other's files — the 1.6 GB transcription model, a heart-path artifact,
  /// wiped by a display-only limb.
  ///
  /// Asserted against the REAL `installDirectory` URLs rather than the manifests'
  /// `installLocation` tokens, because those tokens are documentary:
  /// `DeliveryManifest` decodes `installLocation` as a free `String` and never
  /// resolves it to a path. The directory is the authority, so the directory is
  /// what this test reads.
  @Test("the preview model installs to its own directory, never the transcription model's")
  func previewModelInstallsToItsOwnDirectory() async throws {
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
      manifestBundle: try Self.manifestBundle(),
      appSupportOverride: try Self.tempAppSupport())

    let transcription = try #require(home.whisperKitRegistration)
    let preview = try #require(home.whisperPreviewRegistration)

    #expect(
      preview.installDirectory != transcription.installDirectory,
      "two registrations sharing an install directory delete each other's files")
    #expect(preview.installDirectory.lastPathComponent == "whisper-preview")
    #expect(transcription.installDirectory.lastPathComponent == "whisper")

    // Neither may be an ANCESTOR of the other either: the exhaustive sweep runs
    // over a directory's top-level entries, so a nested install would put one
    // model's folder inside the other's swept space. Equality alone would not
    // catch that.
    let previewPath = preview.installDirectory.standardizedFileURL.path
    let transcriptionPath = transcription.installDirectory.standardizedFileURL.path
    #expect(!previewPath.hasPrefix(transcriptionPath + "/"))
    #expect(!transcriptionPath.hasPrefix(previewPath + "/"))
  }

  /// Everything that makes a collision plausible is genuinely true — same family,
  /// same source repo, same pinned revision — so the separation above is carrying
  /// real weight rather than restating an accident.
  @Test("the two WhisperKit registrations differ only by variant and install directory")
  func previewAndTranscriptionShareFamilyAndRevision() async throws {
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
      manifestBundle: try Self.manifestBundle(),
      appSupportOverride: try Self.tempAppSupport())

    let transcription = try #require(home.whisperKitRegistration).manifest.identity
    let preview = try #require(home.whisperPreviewRegistration).manifest.identity

    #expect(preview.family == transcription.family)
    #expect(preview.revision == transcription.revision)
    #expect(preview.variant != transcription.variant)
    #expect(preview.variant == "openai_whisper-small_216MB")
  }

  /// The shared metadata directory is deliberate and safe. Staging paths and
  /// admission markers key on the full `ModelIdentity.cacheKey`, which includes
  /// the variant, so two artifacts cannot collide there. Only the INSTALL
  /// directory is exhaustive — pinning that distinction stops a future reader
  /// "fixing" the shared metadata dir and losing the marker separation.
  @Test("the two registrations deliberately share one metadata directory")
  func previewAndTranscriptionShareMetadataDirectory() async throws {
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
      manifestBundle: try Self.manifestBundle(),
      appSupportOverride: try Self.tempAppSupport())

    let transcription = try #require(home.whisperKitRegistration)
    let preview = try #require(home.whisperPreviewRegistration)
    #expect(preview.metadataDirectory == transcription.metadataDirectory)
    #expect(
      preview.manifest.identity.cacheKey != transcription.manifest.identity.cacheKey,
      "the cache key is what keeps markers and staging apart in that shared directory")
  }

  /// A handle exists, so the artifact is reachable for download once chunk 4b
  /// asks. Nil would mean the bundled manifest failed to load, which is the
  /// can't-happen-in-release condition the sibling registrations also guard.
  @Test("the preview registration produces a usable delivery handle")
  func previewRegistrationProducesAHandle() async throws {
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
      manifestBundle: try Self.manifestBundle(),
      appSupportOverride: try Self.tempAppSupport())
    #expect(home.whisperPreviewHandle != nil)
  }

  // MARK: - #2123: removal frees the disk, which means releasing first

  /// **The drain must COMPLETE before the delete, not merely be requested.**
  ///
  /// Unlinking a file that is still open or mapped succeeds while its blocks stay
  /// allocated, so the space only returns once every holder has let go. FOUR can
  /// hold the model — the cached engine, a live session until its asynchronous
  /// teardown finishes, an in-flight preparation, and the session task itself
  /// between opening a session and registering its teardown — so a synchronous
  /// "please release" hook is not enough. The count was three when this comment
  /// was written and four by the next review pass, which is the argument for
  /// capturing holders rather than listing them from memory. The first version of this test asserted only
  /// that a hook had fired by the time `removePreviewModel()` returned, which
  /// stayed green with the delete moved BEFORE it. Cloud review caught that.
  ///
  /// This blocks inside the drain and asserts the removal has not finished while
  /// it is blocked — the property a request-shaped hook cannot have.
  @Test("removal waits for every holder to let go before deleting")
  func removalAwaitsTheDrain() async throws {
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
      manifestBundle: try Self.manifestBundle(),
      appSupportOverride: try Self.tempAppSupport())

    final class Gate: @unchecked Sendable {
      private let mutex = NSLock()
      private var waiter: CheckedContinuation<Void, Never>?
      private var isOpen = false
      private var entered = false
      private var finished = false
      var drainEntered: Bool { mutex.withLock { entered } }
      var removalFinished: Bool { mutex.withLock { finished } }
      func noteFinished() { mutex.withLock { finished = true } }
      func wait() async {
        mutex.withLock { entered = true }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
          let alreadyOpen: Bool = mutex.withLock {
            if isOpen { return true }
            waiter = c
            return false
          }
          if alreadyOpen { c.resume() }
        }
      }
      func open() {
        let waiting: CheckedContinuation<Void, Never>? = mutex.withLock {
          isOpen = true
          let w = waiter
          waiter = nil
          return w
        }
        waiting?.resume()
      }
    }
    let gate = Gate()
    home.drainPreviewHoldersBeforeRemoval = { await gate.wait() }
    home.previewRemovalDidFinish = { gate.noteFinished() }
    // **Never the real delete.** `manifestBundle` redirects only where manifests
    // are READ from; the install root and admission metadata are the developer's
    // own `~/Library/Application Support`, so a real removal here deletes their
    // installed preview model when the suite runs.
    home.deletePreviewModelOverrideForTests = {}

    home.removePreviewModel()
    for _ in 0..<2000 where !gate.drainEntered { await Task.yield() }
    #expect(gate.drainEntered, "control: removal must actually ask the holders to drain")

    // THE ASSERTION: while the drain is blocked, removal has not completed.
    for _ in 0..<200 { await Task.yield() }
    #expect(
      !gate.removalFinished,
      "removal completed while a holder was still draining, so the unlink could hit a mapped file")

    gate.open()
    for _ in 0..<2000 where !gate.removalFinished { await Task.yield() }
    #expect(gate.removalFinished, "removal must finish once the holders have let go")

    // **THE ORDER ITSELF**, which "finished after the drain" cannot see: the
    // finish callback trails both steps whichever way round they are, so an
    // earlier version of this test stayed green with the delete moved first.
    #expect(
      home.removalStepsForTests == ["drain", "delete", "finish"],
      "removal ran in the wrong order: \(home.removalStepsForTests)")
  }

  /// Two presses must produce ONE removal.
  ///
  /// The button stays on screen during the drain, so a second press is ordinary
  /// rather than exotic. Single-flighting only the coordinator's drain was not
  /// enough: both presses shared that and then ran two deletes and two finish
  /// callbacks, and one finish lifts the suppression while the other removal is
  /// still going — reopening the window suppression exists to close.
  ///
  /// Mutation control: drop the `removalTask == nil` guard and the counts double.
  @Test("pressing Remove twice removes once")
  func removalIsSingleFlight() async throws {
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
      manifestBundle: try Self.manifestBundle(),
      appSupportOverride: try Self.tempAppSupport())

    final class Gate: @unchecked Sendable {
      private let mutex = NSLock()
      private var waiter: CheckedContinuation<Void, Never>?
      private var isOpen = false
      private(set) var entries = 0
      var entered: Int { mutex.withLock { entries } }
      func wait() async {
        mutex.withLock { entries += 1 }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
          let open: Bool = mutex.withLock {
            if isOpen { return true }
            waiter = c
            return false
          }
          if open { c.resume() }
        }
      }
      func open() {
        let w: CheckedContinuation<Void, Never>? = mutex.withLock {
          isOpen = true
          let w = waiter
          waiter = nil
          return w
        }
        w?.resume()
      }
    }
    let gate = Gate()
    home.drainPreviewHoldersBeforeRemoval = { await gate.wait() }
    // Counted, not performed: see the note above about Application Support.
    let deletes = Deletes()
    home.deletePreviewModelOverrideForTests = { deletes.record() }

    home.removePreviewModel()
    for _ in 0..<2000 where gate.entered < 1 { await Task.yield() }
    #expect(gate.entered == 1, "control: the first removal is under way")

    // The user presses it again while the first is draining.
    home.removePreviewModel()
    for _ in 0..<200 { await Task.yield() }
    #expect(gate.entered == 1, "a second press started a competing removal")

    gate.open()
    for _ in 0..<2000 where !home.removalStepsForTests.contains("finish") { await Task.yield() }
    #expect(
      home.removalStepsForTests == ["drain", "delete", "finish"],
      "exactly one of each step, got \(home.removalStepsForTests)")
    #expect(deletes.count == 1, "two presses performed \(deletes.count) deletes")
  }

  private final class Deletes: @unchecked Sendable {
    private let mutex = NSLock()
    private var value = 0
    var count: Int { mutex.withLock { value } }
    func record() { mutex.withLock { value += 1 } }
  }

  // MARK: - #2137 cloud review: the delivery kill switch

  /// The Download door must honour `modelDelivery.whisper_kit.enabled`.
  ///
  /// `ensureAvailable()` does NOT enforce the flag itself — the primary WhisperKit
  /// door guards `handle.isEnabled()` immediately before calling it
  /// (`WhisperKitDeliveryWiring.swift:74,125`). This door did not, so an operator
  /// who had disabled the whole family could still have a 217 MB preview fetch
  /// start, bypassing the relaunch-free rollback the flag exists to provide.
  ///
  /// Asserted BOTH ways in one test, because either half alone is satisfiable by
  /// the opposite bug: flag-off must publish nothing, and flag-on must still
  /// reach the controller. A one-way test would pass against a door welded shut,
  /// which breaks the feature for every user to protect against a flag almost
  /// nobody sets.
  ///
  /// The flag store is injected. Writing a real kill switch into the shared suite
  /// to test it would leave an operational flag set on a developer's machine.
  @Test("the preview Download door honours the whisper_kit kill switch, both ways")
  func previewDownloadHonoursTheKillSwitch() async throws {
    func home(enabled: Bool) throws -> ModelDeliveryHome {
      let suite = try #require(UserDefaults(suiteName: "ew-2137-killswitch-\(UUID().uuidString)"))
      suite.set(enabled, forKey: "modelDelivery.whisper_kit.enabled")
      return ModelDeliveryHome(
        engineMutationScope: .live(
          tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
        manifestBundle: try Self.manifestBundle(),
        appSupportOverride: try Self.tempAppSupport(),
        deliveryFlagDefaults: suite)
    }

    let off = try home(enabled: false)
    for _ in 0..<400 { await Task.yield() }
    let offBaseline = off.previewStateUpdatesForTests
    off.startPreviewDownload()
    for _ in 0..<2000 { await Task.yield() }
    #expect(
      off.previewStateUpdatesForTests == offBaseline,
      "the kill switch is off but the download door still reached delivery")

    let on = try home(enabled: true)
    for _ in 0..<400 { await Task.yield() }
    let onBaseline = on.previewStateUpdatesForTests
    on.startPreviewDownload()
    for _ in 0..<4000 where on.previewStateUpdatesForTests == onBaseline { await Task.yield() }
    #expect(
      on.previewStateUpdatesForTests > onBaseline,
      "with the flag ON the door must still reach delivery; a welded-shut door would pass the assertion above"
    )
  }

  /// The Parakeet Resume door honours `modelDelivery.parakeet.enabled` (#2139).
  ///
  /// The flag is enforced per FETCH door by the caller — the controller's own
  /// snapshot drives revalidation, source order and telemetry, never a refusal —
  /// so a door that omits the check ignores the flag rather than weakening it.
  /// Automatic warm-up checks it; this door did not, so an operator who had frozen
  /// delivery could still start a multi-gigabyte fetch from Settings.
  ///
  /// **Both directions in one case**, because either half alone is satisfiable by
  /// the opposite bug: flag-off must not reach the mutation claim, and flag-on
  /// must still reach it. A one-way test passes against a door welded shut, which
  /// breaks Resume for every user in order to honour a flag almost nobody sets.
  ///
  /// **The claim is the observable, and the gate is deliberately set to REFUSE.**
  /// `withClaim` calls `tryBegin` before anything else and reports the site
  /// through `onRefused`, so a refused claim proves control reached the claim —
  /// which is the statement immediately after the guard — while `ensureAvailable()`
  /// is never called. That last part is not a convenience: unlike its two
  /// siblings, Parakeet's install directory is deliberately NOT rerouted by
  /// `appSupportOverride` (it comes from `AsrModels.defaultCacheDirectory`), so a
  /// flag-on arm that reached real delivery would validate or fetch against the
  /// developer's own model cache and the network.
  ///
  /// **The flag-off arm asserts a POSITIVE.** `parakeetResumeRefusalsForTests` is
  /// incremented synchronously inside the guard, on the main actor, before any
  /// `Task` exists — so it is already true when the call returns and there is
  /// nothing to wait for. The companion `refusedSites` assertion is a genuine
  /// absence and is safe for the same structural reason: the refusal path creates
  /// no `Task`, so nothing could ever append to it later.
  ///
  /// The flag store is injected. Reading the real one would mean writing an
  /// operational delivery kill switch onto a developer's machine.
  @Test("the Parakeet Resume door honours the parakeet kill switch, both ways")
  func parakeetResumeHonoursTheKillSwitch() async throws {
    final class Box: @unchecked Sendable {
      var refusedSites: [String] = []
    }

    func makeHome(enabled: Bool, box: Box) throws -> ModelDeliveryHome {
      let suite = try #require(UserDefaults(suiteName: "ew-2139-killswitch-\(UUID().uuidString)"))
      suite.set(enabled, forKey: "modelDelivery.parakeet.enabled")
      return ModelDeliveryHome(
        engineMutationScope: .live(
          tryBegin: { false },
          end: { false },
          wake: {},
          onRefused: { box.refusedSites.append($0) }),
        manifestBundle: try Self.manifestBundle(),
        appSupportOverride: try Self.tempAppSupport(),
        deliveryFlagDefaults: suite)
    }

    let offBox = Box()
    let off = try makeHome(enabled: false, box: offBox)
    off.resumeParakeetDownload()
    #expect(
      off.parakeetResumeRefusalsForTests == 1,
      "with the kill switch off the door must refuse synchronously, before any Task exists")
    #expect(
      offBox.refusedSites.isEmpty,
      "a refused door must not reach the mutation claim: a download that is never going to happen must not serialise against a dictation's engine switch"
    )

    let onBox = Box()
    let on = try makeHome(enabled: true, box: onBox)
    on.resumeParakeetDownload()
    // Signal, not clock: wait for the gate's own refusal telemetry, which the
    // subject fires from inside the door's Task.
    for _ in 0..<400 where onBox.refusedSites.isEmpty { await Task.yield() }
    #expect(
      on.parakeetResumeRefusalsForTests == 0,
      "with the flag ON nothing may refuse on the kill switch")
    #expect(
      onBox.refusedSites == ["parakeetResumeDownload"],
      "with the flag ON the door must still reach delivery; a welded-shut door would pass the assertions above"
    )
  }

  /// A refused removal must still END the removal, or Live Preview dies for the
  /// rest of the launch.
  ///
  /// `remove()` returns `false` without touching the controller when the family
  /// kill switch is off (`WhisperKitModelDelivery.swift:124`) — deliberate, and
  /// owned there: the flag stands down the whole delivery layer, deletions
  /// included. So the model legitimately stays on disk. What is NOT legitimate
  /// is what that does to the finish callback.
  ///
  /// `previewRemovalDidFinish` means "no longer removing", never "removal
  /// succeeded" — it clears `isRemovingModel` in the coordinator. Making it
  /// conditional on success is the obvious-looking reading of a discarded result,
  /// and it latches removal suppression forever: the model will not delete AND
  /// the feature will not run. This pins the sequence so that reading cannot land
  /// silently.
  ///
  /// Both directions, because "the steps completed" alone is satisfiable by a
  /// build that never consults the flag at all: flag-off must record `refused`,
  /// flag-on must NOT, and both must reach `finish`.
  ///
  /// **The real `remove()` runs here, unlike the ordering tests above, which
  /// substitute it.** That is safe only because `appSupportOverride` roots BOTH
  /// the preview model's `installDirectory` and its `metadataDirectory`
  /// (`ModelDeliveryHome.swift:196-210`), so the flag-on half deletes inside a
  /// temp directory rather than the developer's installed 217 MB model.
  @Test("a kill-switch-refused preview removal still finishes, both ways")
  func refusedPreviewRemovalStillFinishes() async throws {
    func home(enabled: Bool) throws -> ModelDeliveryHome {
      let suite = try #require(UserDefaults(suiteName: "ew-2137-rmswitch-\(UUID().uuidString)"))
      suite.set(enabled, forKey: "modelDelivery.whisper_kit.enabled")
      return ModelDeliveryHome(
        engineMutationScope: .live(
          tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
        manifestBundle: try Self.manifestBundle(),
        appSupportOverride: try Self.tempAppSupport(),
        deliveryFlagDefaults: suite)
    }

    // **Observes the CALLBACK, never the `finish` step marker**, and that
    // distinction is the whole test. `removalStepsForTests.append("finish")` is
    // a separate statement AFTER the callback, so it records that control
    // reached that line — not that the callback ran. Asserting the step array
    // passed against the exact mutation this test exists to catch (suppressing
    // the callback on a refusal), because the marker still landed. A proxy one
    // statement away from the subject is not an observation of it.
    @MainActor final class Finishes {
      private(set) var count = 0
      func record() { count += 1 }
    }

    let off = try home(enabled: false)
    let offFinishes = Finishes()
    off.previewRemovalDidFinish = { offFinishes.record() }
    for _ in 0..<400 { await Task.yield() }
    off.removePreviewModel()
    for _ in 0..<4000 where offFinishes.count == 0 { await Task.yield() }
    #expect(
      offFinishes.count == 1,
      "a refused removal must still fire the finish callback; latching suppression kills Live Preview for the launch"
    )
    #expect(
      off.removalStepsForTests.contains("refused"),
      "control: with the flag OFF the removal must actually have been refused")

    let on = try home(enabled: true)
    let onFinishes = Finishes()
    on.previewRemovalDidFinish = { onFinishes.record() }
    for _ in 0..<400 { await Task.yield() }
    on.removePreviewModel()
    for _ in 0..<4000 where onFinishes.count == 0 { await Task.yield() }
    #expect(
      onFinishes.count == 1,
      "with the flag ON removal must still finish exactly once")
    #expect(
      !on.removalStepsForTests.contains("refused"),
      "with the flag ON removal must NOT be refused; a build ignoring the flag would pass the OFF half above"
    )
  }

  // MARK: - #2123 whole-diff review: the launch probe

  /// Launching must PROBE delivery state, not merely wire an observer to it.
  ///
  /// The bug this pins: a model admitted in a previous app session leaves a fresh
  /// controller with no in-memory entry, so there is nothing for a new observer
  /// to be told about, and the card reports "Not downloaded yet" — hiding Remove
  /// — for a model sitting on disk. `recordFirstRunBaseline` cannot cover it; it
  /// records whether this is a first run and publishes no state.
  ///
  /// **What this does and does not pin, established by mutation rather than by
  /// argument.** Deleting the `admitIfComplete` probe from `init` fails it, which
  /// is the regression that matters. Reversing the observer-attach and the probe
  /// does NOT fail it — `addStateObserver` replays every existing entry's state
  /// to a newly attached observer, so attach order is genuinely not load-bearing.
  /// An earlier version of this test claimed to guard that ordering and did not;
  /// the claim is recorded here so nobody re-derives it from the test's shape.
  ///
  /// Rooted at a temp directory rather than the real Application Support, so the
  /// verdict does not depend on whether this machine has ever used the feature.
  @Test("construction probes delivery state rather than only observing it")
  func launchProbePublishesToAnAttachedObserver() async throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("ew-2123-launch-probe-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
      manifestBundle: try Self.manifestBundle(),
      appSupportOverride: root)

    #expect(home.whisperPreviewRegistration?.metadataDirectory.path.hasPrefix(root.path) == true)

    for _ in 0..<4000 where home.previewStateUpdatesForTests == 0 { await Task.yield() }
    #expect(
      home.previewStateUpdatesForTests > 0,
      "launch published nothing to the preview mirror, so the no-fetch probe did not run"
    )
  }

  // MARK: - #2123: the preview model's download state is observable

  /// The state starts where a not-yet-downloaded model should start.
  ///
  /// Deliberately a separate mirror from Parakeet's rather than a shared one:
  /// they are different models with different lifecycles, and a settings page
  /// rendering one from the other's state would show a download that is not
  /// happening.
  @Test("the preview model has its own delivery state, separate from Parakeet's")
  func previewStateIsItsOwnMirror() async throws {
    let home = ModelDeliveryHome(
      engineMutationScope: .live(
        tryBegin: { true }, end: { true }, wake: {}, onRefused: { _ in }),
      manifestBundle: try Self.manifestBundle(),
      appSupportOverride: try Self.tempAppSupport())

    #expect(home.parakeetState == .notReady)
    // Safe to assert absolutely ONLY because this suite is rooted at a throwaway
    // Application Support (see `tempAppSupport`). Construction now runs a
    // no-fetch launch probe, so against the real directory this value would
    // depend on whether the machine running the tests happens to have the preview
    // model on disk — green in CI, green on a clean machine, red on a developer's
    // machine that had used the feature. A fixture that varies by machine is not
    // a fixture; the temp root is what makes this line a constant.
    #expect(home.whisperPreviewState == .notReady)

    let preview = try #require(home.whisperPreviewRegistration)
    let transcription = try #require(home.whisperKitRegistration).manifest.identity
    #expect(
      preview.manifest.identity.cacheKey != transcription.cacheKey,
      "two mirrors over one identity would make each model report the other's progress")

    // **The observer must actually OBSERVE.** Checking the initial value cannot
    // tell a wired mirror from a deleted one — both read `.notReady`. So publish
    // a real state for the preview identity and watch which mirror moves.
    //
    // `admitIfComplete` with no fetch is the safe trigger: it validates what is
    // already on disk and never downloads, and never deletes. `remove` would
    // have published a state too, and would have deleted a real model from the
    // machine running the tests.
    // Measured against a BASELINE, not against zero. The launch probe may already
    // have applied an update by now, and `> 0` would then pass without this
    // explicit trigger proving anything — the assertion would be satisfied by
    // construction alone and would survive deleting the observer's reaction to
    // this publish entirely.
    let baseline = home.previewStateUpdatesForTests
    let parakeetBaseline = home.parakeetStateUpdatesForTests

    _ = await home.controller.admitIfComplete(preview)

    for _ in 0..<2000 where home.previewStateUpdatesForTests == baseline { await Task.yield() }
    #expect(
      home.previewStateUpdatesForTests > baseline,
      "the preview mirror never applied an update — observer missing or filtered wrongly")
    #expect(
      home.parakeetStateUpdatesForTests == parakeetBaseline,
      "a preview state reached Parakeet's mirror, so the identity filter is wrong")
  }
}
