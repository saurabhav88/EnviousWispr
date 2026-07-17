import EnviousWisprASR
import EnviousWisprModelDelivery
import EnviousWisprPipeline
import Foundation

/// Builds the multilingual (WhisperKit) delivery wiring in ONE place (#1386
/// PR-2): the retirement coordinator, the one shipped backend, the setup
/// service, and the delivery-state projection that drives the Settings row.
///
/// It exists so the composition root can NAME this subsystem in three lines
/// instead of spelling out its closures. That is the composition root's job —
/// own the graph, not the detail — and epic #763's line ceiling on
/// `WisprBootstrapper` is the thing that says so out loud. Everything here is
/// construction: no policy, no state.
@MainActor
enum WhisperKitDeliveryWiring {
  struct Wired {
    let backend: WhisperKitBackend
    /// Nil when no bundled manifest loaded — the engine then honestly reports
    /// not-installed rather than fetching by an unverified route.
    let retirement: WhisperKitLegacyUpgradeCoordinator?
    let setupService: WhisperKitSetupService
  }

  static func make(modelDelivery: ModelDeliveryHome) -> Wired {
    let handle = modelDelivery.whisperKitHandle
    let installDirectory = modelDelivery.whisperKitRegistration?.installDirectory
    let trustedFiles = modelDelivery.whisperKitRegistration?.manifest.files.map {
      LegacyRetirement.TrustedFile(
        relativePath: $0.resolvedInstallPath, sizeBytes: $0.sizeBytes, sha256: $0.sha256)
    }

    // One closure crosses into ASR (which imports neither Pipeline nor
    // ModelDelivery): where an admitted model lives. It fails closed when
    // delivery is absent.
    //
    // No repair closure, by design: `repair()` deletes the failed components and
    // re-fetches them, so wiring it here would make a keypress start a silent
    // multi-GB download on a corrupted cache — the #1339 exposure this PR exists
    // to delete. Parakeet and EG-1 keep theirs; their policies differ, and that
    // is the point of a per-engine boundary.
    //
    // No relocation gate either, and its absence is the design rather than an
    // omission: the gate existed to stop a byte-MOVE landing under an open CoreML
    // map. Retire-and-refetch never moves bytes under a live map — this build
    // cannot load the foreign copy at all (`prepare()` resolves the admitted
    // folder or throws), and `unlink` does not invalidate an existing mapping.
    // No move, nothing to gate.
    let backend = WhisperKitBackend(
      admittedModelFolder: { [weak handle] in
        guard let handle, let installDirectory, await handle.isAdmitted() else { return nil }
        return installDirectory.path
      })

    let retirement = handle.flatMap { handle -> WhisperKitLegacyUpgradeCoordinator? in
      guard let trustedFiles, !trustedFiles.isEmpty else { return nil }
      return WhisperKitLegacyUpgradeCoordinator(
        variant: WhisperKitBackend.defaultModelVariant(),
        trustedFiles: trustedFiles,
        isAdmitted: { [weak handle] in await handle?.isAdmitted() == true },
        ensureAvailable: { [weak handle] in
          // The kill switch is read at the fetch door, fresh per attempt: that is
          // what makes it a relaunch-free rollback.
          guard handle?.isEnabled() == true else { return false }
          if case .admitted = await handle?.ensureAvailable() { return true }
          return false
        },
        cancelActiveFetch: { [weak handle] in await handle?.cancelActiveFetch() },
        // Read again at the TOP of every run: retiring bytes while the switch is
        // off would strand a rollback user with neither model (Codex 2b-r1 P1).
        isDeliveryEnabled: { [weak handle] in handle?.isEnabled() == true })
    }
    // The migration must not ship blind: retirement outcomes ride the shared
    // delivery funnel, same wiring shape as EG-1's bridge (#1386 PR-2b).
    retirement?.onEvent = WhisperKitRetirementTelemetryBridge.handler
    // 2c: the delivery-layer deletion the Remove drain awaits LAST (L1). The
    // engine-unload seam is assigned by the bootstrapper once the driver
    // exists — the adapter is constructed after this wiring runs.
    retirement?.removeFromDelivery = { [weak handle] in
      await handle?.remove() ?? false
    }

    // Availability is controller admission, never a directory probe. A refused
    // foreign copy is simply not an installed model: it is preserved untouched
    // and never loaded, and the shipped `.notDownloaded` + Download button is the
    // honest answer for an engine whose model is not installed.
    let setupService = WhisperKitSetupService(
      readAvailability: { [weak handle] in
        guard let handle else { return .notDownloaded }
        if await handle.isAdmitted() { return .ready }
        // A crash between the promote and the marker write leaves a complete,
        // hash-valid cache with no marker (cloud review P2). Adopt it —
        // revalidate and admit WITHOUT fetching — instead of telling the user
        // to download 1.6 GB they already have. Absent files fail this check
        // instantly, so the common no-model path stays cheap.
        if await handle.adoptIfPresent() { return .ready }
        // Resumable partials read as PAUSED, not not-downloaded (founder ruling
        // 2026-07-17): derived from disk, so the paused row survives refreshes
        // and relaunches alike (Codex 2c-r7 P2).
        if await handle.hasStagedPartials() { return .paused }
        return .notDownloaded
      },
      // The kill switch is checked HERE, at the fetch door, not only in the copy
      // above: a stale Settings render (or a flag flipped after the row drew)
      // must not still be able to start a multi-GB fetch. Returns whether the
      // request was ACCEPTED — a refusal must not leave the row on "Starting
      // download..." forever (Codex 2b-r1 P2).
      //
      // Download routes through the coordinator, not straight to the handle: its
      // join semantics (L5) make a press during the launch refetch join that
      // fetch instead of racing it.
      startDownload: { [weak handle, weak retirement] in
        guard let handle, handle.isEnabled() else { return false }
        if let retirement {
          await retirement.download()
        } else {
          _ = await handle.ensureAvailable()
        }
        return true
      },
      // Cancel routes through the coordinator too: it clears the owed marker
      // FIRST (L1), so a cancelled launch refetch stays cancelled instead of
      // silently restarting next launch (Codex 2b-r1 P1). A failed marker clear
      // refuses the whole command — returning false so the row does NOT
      // re-detect to "not downloaded" while the fetch is in fact still running
      // (Codex 2b-r3 P2); the live state stream keeps showing the truth.
      cancelActiveDownload: { [weak handle, weak retirement] in
        if let retirement {
          do {
            try await retirement.cancel()
            return true
          } catch {
            return false
          }
        }
        await handle?.cancelActiveFetch()
        return true
      },
      // 2c: Remove routes through the coordinator (L1 order: drain fetch ->
      // unload -> delete). The dictation-in-flight refusal already happened in
      // the presentation layer; a nil coordinator (no manifest) can delete
      // nothing and reports failure honestly.
      removeModelAction: { [weak retirement] in
        guard let retirement else { return .failed }
        switch await retirement.remove() {
        case .removed: return nil
        case .refusedMarkerClear, .failed: return .failed
        }
      })

    // One delivery-state stream projected onto the ASR setup states the Settings
    // row already renders (D6: one stream, two renderers).
    //
    // Codex flicker-fix-r2 P2: the .notReady case below awaits a disk read
    // before applying its result. If a NEWER event (a fresh download start,
    // success, or failure) arrives and applies while that read is still in
    // flight, the stale disk-check result must not land on top of it —
    // `applyGate` bumps on every event and the pending read only applies if
    // it is still the most recent one when it resolves.
    let applyGate = NotReadyStaleReadGate()
    handle?.observeState { [weak setupService] state in
      guard let setupService else { return }
      let generation = applyGate.bump()
      switch state {
      case .preparing:
        setupService.applyDeliveryState(.downloading(progress: 0, status: "Preparing..."))
      case .downloading(let fraction, _, _):
        setupService.applyDeliveryState(
          .downloading(progress: fraction, status: "Downloading model files..."))
      case .verifying:
        setupService.applyDeliveryState(.downloading(progress: 1.0, status: "Verifying..."))
      case .admitted:
        setupService.applyDeliveryState(.ready)
      case .failed(let failure):
        setupService.applyDeliveryState(
          .error(ModelDeliveryCopy.message(reason: failure.reason, detail: failure.detail)))
      case .cancelled(let resumable):
        // Founder ruling 2026-07-17: a cancelled download PAUSES — the row says
        // so and offers Resume (the controller keeps the staging partials).
        // A non-resumable cancel is also terminal delivery truth on its own —
        // see the .notReady case below for why re-probing here is the bug,
        // not the fix.
        if resumable {
          setupService.applyDeliveryState(.paused)
        } else {
          setupService.applyDeliveryState(.notDownloaded)
        }
      case .notReady:
        // .notReady is terminal delivery truth (nothing admitted, no fetch
        // attempted) — apply it directly, never by re-probing the controller.
        // The prior `forceDetectState()` re-probe called readAvailability()
        // -> adoptIfPresent(), which itself republishes .preparing then
        // .notReady through this SAME observer, re-entering this case
        // forever: an unbounded MainActor task loop that pinned the app at
        // 100%+ CPU and froze the Settings row the moment a real user (or
        // Remove) reached a genuinely not-installed state. Never re-enter
        // detection from a push notification the controller just sent —
        // detection is for the PULL path (.onAppear / backend switch), not
        // for reacting to the controller's own state stream.
        //
        // Codex flicker-fix-r1 P2: `.notReady` carries no resumable flag, so
        // settling straight on `.notDownloaded` can overwrite a genuinely
        // paused download shown moments earlier — a stale `.notReady` from
        // this SAME probe chain can land after the pull path's own `.paused`
        // read. `hasStagedPartials()` is a pure disk read (never calls
        // `startAttempt`/`setState`), so checking it here cannot re-enter the
        // loop above; it only decides which terminal presentation is honest.
        //
        // Codex flicker-fix-r2 P2: guard the result against `applyGate` — a
        // newer event (fresh download start/success/failure) may already
        // have applied by the time this read resolves, and this stale result
        // must not overwrite it.
        Task { @MainActor [weak handle, weak setupService] in
          guard let handle, let setupService else { return }
          let hasPartials = await handle.hasStagedPartials()
          guard applyGate.isCurrent(generation) else { return }
          setupService.applyDeliveryState(hasPartials ? .paused : .notDownloaded)
        }
      }
    }

    return Wired(backend: backend, retirement: retirement, setupService: setupService)
  }
}

/// Monotonic freshness guard for the `.notReady` case's async disk read
/// (Codex flicker-fix-r2 P2): every delivery event bumps the generation;
/// the pending read only applies its result if no newer event has landed
/// while it was in flight.
@MainActor private final class NotReadyStaleReadGate {
  private var generation = 0
  func bump() -> Int {
    generation += 1
    return generation
  }
  func isCurrent(_ candidate: Int) -> Bool { candidate == generation }
}
