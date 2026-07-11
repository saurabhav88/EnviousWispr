import EnviousWisprLLM
import EnviousWisprModelDelivery
import Foundation

/// EG-1's delivery + relocation wiring (#1386 PR-1), extracted from
/// `WisprBootstrapper` so the composition root stays a composer rather than
/// growing a migration brain (`architecture-rules.md` keep-central-types-thin;
/// the bootstrapper is line-ceilinged for exactly this reason).
///
/// Owns two things and nothing else:
///  1. WHERE EG-1's bytes live — the app-owned `EnviousWispr/Models/eg-1`, and
///     the legacy `PolishModels` home they came from.
///  2. WHEN the launch transition runs — relocate first, then either replace a
///     superseded layout or activate normally.
enum EGOneDeliveryWiring {

  /// The one previously-shipped EG-1 layout. Every released build installs a
  /// single monolithic `eg-1-v1.gguf`; it cannot satisfy the current 8-shard
  /// manifest (#1417's sharding is in no released tag). Those bytes ARE ours —
  /// we shipped them and hold their digest — so the contract's automatic-
  /// replacement clause permits replacing them with no user click, but only ever
  /// verify-before-delete.
  ///
  /// Size + digest are the SHIPPED values, lifted from the last monolithic
  /// manifest (`eg1-manifest.json` at tag v2.3.2, and the pre-#1417 delivery
  /// manifest, which agree). They are what makes this artifact identifiable as
  /// OURS: a same-named file we did not ship fails the hash and is never
  /// touched. Do not "simplify" this back to a filename match.
  static let trustedLegacyArtifacts = [
    ModelRelocationMigrator.TrustedLegacyArtifact(
      name: "eg-1-v1.gguf",
      sizeBytes: 2_889_511_680,
      sha256: "3343fc1a30a3e82df7499a4775ef73dd6e28dea1cc39bb58197ec0b66ec874f6")
  ]

  struct Wired {
    let adapter: EGOneDeliveryAdapter
    let registration: DeliveryRegistration
    let relocation: ModelRelocationMigrator.RelocationPlan
  }

  /// Build EG-1's registration + adapter + relocation plan against the owned
  /// model home. Returns nil when the bundled manifest cannot be read (a RED
  /// limb state, never a crash).
  ///
  /// `@MainActor` because `EGOneDeliveryAdapter` is: the composition root
  /// already runs there, so this is the adapter's isolation, not a new hop.
  @MainActor
  static func wire(
    controller: ModelDeliveryController,
    version: String?,
    appSupport: URL
  ) -> Wired? {
    guard let manifest = try? DeliveryManifest.loadBundled(resource: "eg1-delivery-manifest")
    else { return nil }
    let metadataDirectory = appSupport.appendingPathComponent(
      "EnviousWispr/ModelDelivery", isDirectory: true)
    // One app-owned home for every model: EG-1 leaves its one-off
    // `PolishModels` subfolder and sits beside the speech engines.
    let ownedDirectory = appSupport.appendingPathComponent(
      "EnviousWispr/Models/eg-1", isDirectory: true)
    let legacyDirectory = appSupport.appendingPathComponent(
      "EnviousWispr/PolishModels", isDirectory: true)

    // With the kill switch off, nothing may MUTATE model bytes — so we read from
    // wherever a usable copy already is. Pick by ADMISSION, never by directory
    // existence: a relocation that failed partway leaves a half-populated
    // `Models/eg-1` beside a perfectly good `PolishModels`, and "the folder is
    // there" would choose the broken one (Codex PR-1 review r10). Both are real
    // candidates — a machine that downloaded shards before this change has them in
    // the legacy home.
    //
    // WHAT THE KILL SWITCH DOES AND DOES NOT PROMISE (Codex PR-1 review r14).
    // It guarantees: no model bytes are moved, deleted, or fetched. It does NOT
    // guarantee that polish keeps working — and for one cohort it cannot. A user
    // still on the previously-shipped MONOLITH has bytes this build is structurally
    // unable to load: the runtime boots the manifest's entrypoint, and the bundled
    // manifest is sharded, so no directory choice can make an `eg-1-v1.gguf`
    // loadable. Restoring that would mean shipping the old manifest AND the old load
    // path alongside the new ones, permanently — dual-format support for a rollback
    // lever. That is not worth it. With the switch off, such a user gets raw text
    // (EG-1 is a limb) and their model is left completely untouched; flipping the
    // switch back on runs the migration and polish returns. Nothing is lost, only
    // deferred. Do not "fix" this by resurrecting the monolithic load path.
    let installDirectory: URL = {
      guard !EGOneDeliveryAdapter.isDeliveryEnabled() else { return ownedDirectory }
      return ModelRelocationMigrator.admittedLocation(
        manifest: manifest,
        candidates: [ownedDirectory, legacyDirectory],
        metadataDirectory: metadataDirectory) ?? ownedDirectory
    }()

    let registration = DeliveryRegistration(
      manifest: manifest,
      installDirectory: installDirectory,
      metadataDirectory: metadataDirectory)
    return Wired(
      adapter: EGOneDeliveryAdapter(
        controller: controller,
        registration: registration,
        version: version ?? manifest.identity.revision),
      registration: registration,
      relocation: ModelRelocationMigrator.RelocationPlan(
        manifest: manifest,
        oldLocations: [legacyDirectory],
        // Always the OWNED home: the relocation plan describes where the bytes
        // SHOULD end up, and `startLaunchTransition` refuses to run it at all when
        // the kill switch is off. (A disabled build's registration may read from
        // the legacy dir above; that is a load path, not a destination.)
        destination: ownedDirectory,
        metadataDirectory: metadataDirectory,
        trustedLegacyArtifacts: trustedLegacyArtifacts,
        // The retired EGOneModelStore downloaded IN PLACE, leaving a `.partial`
        // (up to ~2.9 GB) and a resume sidecar in PolishModels. The adapter's own
        // sweep only ever looks at its CURRENT install dir, so the moment that
        // dir moves to Models/eg-1 nothing would ever reclaim them — a user
        // interrupted mid-download would carry those gigabytes forever, and the
        // replacement download's disk preflight could fail because of them.
        // (Codex PR-1 review r3; this is the leftover half of #1363.)
        staleSidecarSuffixes: [".partial", ".resume.json"]))
  }

  /// Launch transition. Relocation runs BEFORE EG-1 activates, so nothing loads
  /// a model out of a directory that is about to move.
  ///
  /// Deliberately LIMB-scoped: Parakeet and WhisperKit are NOT gated behind
  /// this, and the multi-GB legacy replacement runs outside it entirely. A
  /// polish download that blocked the speech engines would be a self-inflicted
  /// heart outage.
  ///
  /// A pending token means a superseded layout is still on disk awaiting
  /// replacement — either classified just now, or admitted on an earlier launch
  /// whose cleanup did not finish. Both reconcile through the same path, which
  /// is why crash recovery needs no separate branch.
  @MainActor
  static func startLaunchTransition(
    runtime: EGOneRuntime,
    relocation: ModelRelocationMigrator.RelocationPlan,
    providerIsEGOne: Bool
  ) {
    // The delivery kill switch is the operational rollback control: with it off,
    // NOTHING may mutate model bytes. Relocation runs before every other delivery
    // call, so it has to honor the flag itself — otherwise it would move and delete
    // files precisely when someone had reached for the lever to stop exactly that
    // (Codex PR-1 review r8). Flag off ⇒ behave as we did before #1386: no
    // relocation, no cleanup, load from wherever the bytes already are.
    guard EGOneDeliveryAdapter.isDeliveryEnabled() else {
      if providerIsEGOne {
        runtime.startIfActiveProvider()
      } else {
        runtime.sweepStaleServersAtLaunch()
      }
      return
    }

    let migrator = ModelRelocationMigrator()
    // A Remove retires any pending replacement: the stranded artifact becomes a
    // plain delete, so a failed cleanup can never resurrect a model the user threw
    // away.
    runtime.onModelRemoved = { migrator.markLegacyForRemoval(relocation) }
    // ...and taking the removal back restores it, so the durable intent never
    // outlives the decision that set it.
    runtime.onModelRemovalCancelled = { migrator.markLegacyForReplacement(relocation) }
    // ONE cleanup, reachable from both ways the replacement can be admitted: the
    // automatic migration, and a user-initiated Download after that migration failed.
    runtime.legacyCleanup = { try await migrator.cleanUpLegacy(relocation) }
    Task { @MainActor in
      let outcome = await migrator.migrate(relocation)

      // The OUTCOME drives this launch; the token drives RECOVERY across launches.
      //
      // The two cannot disagree: `migrate` reports `.trustedLegacyPending` ONLY once the
      // token is durably written, and returns `.unrecognized` — do nothing, touch
      // nothing — when it cannot write it (GitHub cloud review, PR #1497).
      //
      // That supersedes r17 ("start the replacement even if journalling failed") and is
      // the correct version of its intent. An unjournaled replacement could never be
      // admitted ANYWAY: the token and the admission marker share this one metadata
      // directory, so a filesystem refusing the token refuses the marker too. Starting a
      // 2.9 GB download that cannot be admitted — and that would leave a later Remove
      // with no token to flip, resurrecting the model on the next launch — is strictly
      // worse than waiting for a launch that can journal.
      let intent = migrator.pendingLegacyIntent(relocation)
      let legacyNeedsReplacing: Bool
      if case .trustedLegacyPending = outcome {
        legacyNeedsReplacing = true
      } else {
        legacyNeedsReplacing = false
      }

      switch intent ?? (legacyNeedsReplacing ? .replace : nil) {
      case .replace:
        runtime.sweepStaleServersAtLaunch()
        runtime.startLegacyLayoutMigration()
      case .remove:
        // The user removed EG-1 while a legacy artifact was still stranded. Finish
        // the removal they asked for, and fetch NOTHING.
        //
        // Both halves, in this order, and the token clears LAST — but ONLY if the
        // first half actually succeeded.
        //
        // The token is the sole durable record that a Remove is owed, and
        // `cleanUpLegacy` is what clears it. So the delivery removal is AWAITED
        // (clearing the token while a fire-and-forget removal was still running
        // would lose the Remove to a crash in that window — r14), and its OUTCOME is
        // checked (clearing the token after a FAILED removal would strand model
        // remnants on disk with nothing left to honor the user's Remove — r15).
        //
        // A failed removal keeps the token and everything it records, so the next
        // launch tries again. Both halves are idempotent, so repeating them is free.
        guard case .removed = await runtime.removeModelAwaitingCompletion() else {
          runtime.sweepStaleServersAtLaunch()
          return
        }
        try? await migrator.cleanUpLegacy(relocation)
        runtime.sweepStaleServersAtLaunch()
      case nil:
        if providerIsEGOne {
          runtime.startIfActiveProvider()
        } else {
          runtime.sweepStaleServersAtLaunch()
        }
      }
    }
  }
}
