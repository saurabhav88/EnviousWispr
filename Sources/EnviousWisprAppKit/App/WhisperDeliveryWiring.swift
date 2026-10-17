import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprModelDelivery
import EnviousWisprPipeline
import EnviousWisprServices
import Foundation

/// Builds the Whisper engine's delivery wiring in ONE place (#1386 PR-2; #3735: transcribe.cpp):
/// the one shipped backend, the migration from the retired WhisperKit models, the setup
/// service, and the delivery-state projection that drives the Settings row.
///
/// It exists so the composition root can NAME this subsystem in a few lines instead of
/// spelling out its closures. Everything here is construction: no policy, no state.
@MainActor
enum WhisperDeliveryWiring {
  struct Wired {
    let backend: LiveTranscribeCppWhisperBackend
    let migration: WhisperModelMigration
    let setupService: WhisperSetupService
    /// The Remove drain's engine-unload seam, assigned by the bootstrapper once the driver
    /// exists (the adapter is constructed after this wiring runs).
    let removal: WhisperRemovalHook
  }

  static func make(
    modelDelivery: ModelDeliveryHome,
    settings: SettingsManager,
    engineMutationScope: EngineMutationScope
  ) -> Wired {
    let handle = modelDelivery.whisperHandle
    let registration = modelDelivery.whisperRegistration
    let modelPath = registration.flatMap { registration in
      registration.manifest.resolvedEntrypointPath.map {
        registration.installDirectory.appendingPathComponent($0).path
      }
    }

    // One closure crosses into ASR (which imports neither Pipeline nor ModelDelivery): where
    // the admitted model lives. It fails closed when delivery is absent.
    //
    // No repair closure, by design: a repair deletes failed components and re-fetches them,
    // so wiring it here would make a keypress start a silent model download on a corrupted
    // cache, the #1339 exposure. Load failure is visible; Remove and Download repair it.
    let backend = LiveTranscribeCppWhisperBackend(
      driver: LiveWhisperExecutorDriver(),
      modelVariant: registration?.manifest.identity.variant ?? "",
      admittedModelPath: { [weak handle] in
        guard let handle, let modelPath, await handle.isAdmitted() else { return nil }
        return modelPath
      },
      // #3546 §3.7 T3: the crash-report model tags; the backend keeps the identity only when
      // its variant is the one it loads.
      modelIdentity: registration?.manifest.identity.asrModelIdentity,
      scopeOwner: .shared,
      // Every load waits for the adapter factory's memory-pressure binding (§3.2a).
      loadsAfterPressureBinding: true,
      // #3849: Whisper may load only while it is the active engine. The stored selection is
      // what `setInitialBackendType` restores at launch; parked from construction, so no
      // warm scheduled before that (launch preload, a cold press) loads it beside Parakeet.
      initiallyParked: settings.selectedBackend != .whisper)

    let previewHandle = modelDelivery.whisperPreviewHandle
    // The retired CoreML folders were siblings of the GGUF ones under `Models/`; derived from
    // the registrations so the migration and delivery always agree on the root.
    let legacyDictationDirectory = registration?.installDirectory.deletingLastPathComponent()
      .appendingPathComponent("whisper", isDirectory: true)
    let legacyPreviewDirectory = modelDelivery.whisperPreviewRegistration?.installDirectory
      .deletingLastPathComponent().appendingPathComponent("whisper-preview", isDirectory: true)
    var ports: [WhisperModelMigration.Artifact: WhisperModelMigration.ArtifactPort] = [:]
    if let handle, let legacyDictationDirectory {
      ports[.dictation] = .init(
        isSelected: { [weak settings] in settings?.selectedBackend == .whisper },
        isAdmittedOrAdoptable: { [weak handle] in await handle?.adoptIfPresent() == true },
        ensureAvailable: { [weak handle] in
          // The kill switch is read at the fetch door, fresh per attempt: that is what makes
          // it a relaunch-free rollback.
          guard let handle, handle.isEnabled() else { return false }
          if case .admitted = await handle.ensureAvailable() { return true }
          return false
        },
        legacyInstallDirectory: legacyDictationDirectory)
    }
    if let previewHandle, let legacyPreviewDirectory {
      ports[.preview] = .init(
        isSelected: { [weak settings] in settings?.livePreviewEngine == .universal },
        isAdmittedOrAdoptable: { [weak previewHandle] in
          await previewHandle?.adoptIfPresent() == true
        },
        ensureAvailable: { [weak previewHandle] in
          guard let previewHandle, previewHandle.isEnabled() else { return false }
          if case .admitted = await previewHandle.ensureAvailable() { return true }
          return false
        },
        legacyInstallDirectory: legacyPreviewDirectory)
    }
    let migration = WhisperModelMigration(
      metadataDirectory: registration?.metadataDirectory
        ?? StorageRoot.standardDirectory.appendingPathComponent("ModelDelivery", isDirectory: true),
      ports: ports,
      // Read again at the TOP of every run: retiring bytes while the switch is off would
      // strand a rollback user with neither model (Codex 2b-r1 P1).
      isDeliveryEnabled: { [weak handle] in handle?.isEnabled() == true })
    // The migration must not ship blind: its outcomes ride the shared delivery funnel.
    migration.onEvent = { event in
      var props = ["family": ModelFamily.whisper.rawValue]
      let name: String
      switch event {
      case .legacyRetired:
        name = "legacy_retired"
      case .legacyRetirementFailed:
        name = "legacy_retirement_failed"
        props["reason"] = "delete"
      case .replacementCompleted(let artifact):
        name = "replacement_completed"
        props["artifact"] = artifact.rawValue
      }
      TelemetryService.shared.modelDeliveryEvent(name: name, properties: props)
    }

    bindPreviewCommands(of: modelDelivery, to: migration)

    let removal = WhisperRemovalHook()

    // Availability is controller admission, never a directory probe.
    let setupService = WhisperSetupService(
      engineMutationScope: engineMutationScope,
      readAvailability: { [weak handle] in
        guard let handle else { return .notDownloaded }
        if await handle.isAdmitted() { return .ready }
        // A crash between the promote and the marker write leaves a complete, hash-valid
        // cache with no marker (cloud review P2). Adopt it, revalidating and admitting
        // WITHOUT fetching, instead of telling the user to download a model they already
        // have. Absent files fail this check instantly, so the common no-model path stays
        // cheap.
        if await handle.adoptIfPresent() { return .ready }
        // Resumable partials read as PAUSED, not not-downloaded (founder ruling 2026-07-17):
        // derived from disk, so the paused row survives refreshes and relaunches alike
        // (Codex 2c-r7 P2).
        if await handle.hasStagedPartials() { return .paused }
        return .notDownloaded
      },
      // The kill switch is checked HERE, at the fetch door, not only in the copy: a stale
      // Settings render (or a flag flipped after the row drew) must not still be able to
      // start a model download. Returns whether the request was ACCEPTED: a refusal must not
      // leave the row on "Starting download..." forever (Codex 2b-r1 P2).
      startDownload: { [weak handle, weak migration] in
        guard let handle, let migration, handle.isEnabled() else { return false }
        return await migration.download(.dictation) == .done
      },
      // Cancel records the decline FIRST, so a cancelled download stays cancelled instead of
      // restarting next launch. A failed record write refuses the whole command, returning
      // false so the row does NOT re-detect to "not downloaded" while the fetch is in fact
      // still running (Codex 2b-r3 P2); the live state stream keeps showing the truth.
      cancelActiveDownload: { [weak handle, weak migration] in
        guard let handle, let migration else { return false }
        guard migration.decline(.dictation) == .done else { return false }
        await handle.cancelActiveFetch()
        return true
      },
      // Remove: record the decline, stop any fetch, unload the engine, then delete. The
      // dictation-in-flight refusal already happened in the presentation layer.
      removeModelAction: { [weak handle, weak migration, removal] in
        guard let handle, let migration else { return .failed }
        guard migration.decline(.dictation) == .done else { return .failed }
        await handle.cancelActiveFetch()
        await removal.unloadForRemoval()
        return await handle.remove() ? nil : .failed
      })

    // One delivery-state stream projected onto the setup states the Settings row already
    // renders (D6: one stream, two renderers).
    //
    // Codex flicker-fix-r2 P2: the .notReady case below awaits a disk read before applying
    // its result. If a NEWER event (a fresh download start, success, or failure) arrives and
    // applies while that read is still in flight, the stale disk-check result must not land
    // on top of it: `applyGate` bumps on every event and the pending read only applies if it
    // is still the most recent one when it resolves.
    let applyGate = NotReadyStaleReadGate()
    handle?.observeState { [weak setupService] state in
      guard let setupService else { return }
      let generation = applyGate.bump()
      switch state {
      case .preparing:
        setupService.applyDeliveryState(
          .downloading(
            progress: 0,
            status: String(
              localized: "Preparing...",
              comment: "Speech engine settings, Whisper model: download status line.")))
      case .downloading(let fraction, _, _):
        setupService.applyDeliveryState(
          .downloading(
            progress: fraction,
            status: String(
              localized: "Downloading model files...",
              comment: "Speech engine settings, Whisper model: download status line.")))
      case .verifying:
        setupService.applyDeliveryState(
          .downloading(
            progress: 1.0,
            status: String(
              localized: "Verifying...",
              comment: "Speech engine settings, Whisper model: download status line.")))
      case .admitted:
        setupService.applyDeliveryState(.ready)
      case .failed(let failure):
        setupService.applyDeliveryState(
          .error(ModelDeliveryCopy.message(reason: failure.reason, detail: failure.detail)))
      case .cancelled(let resumable):
        // Founder ruling 2026-07-17: a cancelled download PAUSES; the row says so and offers
        // Resume (the controller keeps the staging partials). A non-resumable cancel is also
        // terminal delivery truth on its own; see the .notReady case below for why
        // re-probing here is the bug, not the fix.
        if resumable {
          setupService.applyDeliveryState(.paused)
        } else {
          setupService.applyDeliveryState(.notDownloaded)
        }
      case .notReady:
        // .notReady is terminal delivery truth (nothing admitted, no fetch attempted): apply
        // it directly, never by re-probing the controller. A `forceDetectState()` re-probe
        // called readAvailability() -> adoptIfPresent(), which itself republishes .preparing
        // then .notReady through this SAME observer, re-entering this case forever: an
        // unbounded MainActor task loop that pinned the app at 100%+ CPU and froze the
        // Settings row the moment a real user (or Remove) reached a genuinely not-installed
        // state. Never re-enter detection from a push notification the controller just sent:
        // detection is for the PULL path (.onAppear / backend switch), not for reacting to
        // the controller's own state stream.
        //
        // Codex flicker-fix-r1 P2: `.notReady` carries no resumable flag, so settling
        // straight on `.notDownloaded` can overwrite a genuinely paused download shown
        // moments earlier. `hasStagedPartials()` is a pure disk read (never calls
        // `startAttempt`/`setState`), so checking it here cannot re-enter the loop above; it
        // only decides which terminal presentation is honest.
        //
        // Codex flicker-fix-r2 P2: guard the result against `applyGate`: a newer event may
        // already have applied by the time this read resolves.
        Task { @MainActor [weak handle, weak setupService] in
          guard let handle, let setupService else { return }
          let hasPartials = await handle.hasStagedPartials()
          guard applyGate.isCurrent(generation) else { return }
          setupService.applyDeliveryState(hasPartials ? .paused : .notDownloaded)
        }
      }
    }

    return Wired(
      backend: backend, migration: migration, setupService: setupService, removal: removal)
  }
}

extension WhisperDeliveryWiring {
  /// The preview's Settings commands go through the migration's record (see
  /// `ModelDeliveryHome.PreviewReplacementCommands`). One function, so tests bind exactly what
  /// production binds.
  static func bindPreviewCommands(
    of modelDelivery: ModelDeliveryHome, to migration: WhisperModelMigration
  ) {
    modelDelivery.previewReplacement = .init(
      download: { [weak migration] in await migration?.download(.preview) == .done },
      decline: { [weak migration] in migration?.decline(.preview) == .done })
  }
}

/// The Remove drain's engine-unload step, assigned once the driver exists. Awaited BEFORE the
/// delivery deletion, so no loaded model is unlinked underneath its engine.
@MainActor final class WhisperRemovalHook {
  var unloadForRemoval: @MainActor () async -> Void = {}
}

/// Monotonic freshness guard for the `.notReady` case's async disk read (Codex
/// flicker-fix-r2 P2): every delivery event bumps the generation; the pending read only
/// applies its result if no newer event has landed while it was in flight.
@MainActor private final class NotReadyStaleReadGate {
  private var generation = 0
  func bump() -> Int {
    generation += 1
    return generation
  }
  func isCurrent(_ candidate: Int) -> Bool { candidate == generation }
}
