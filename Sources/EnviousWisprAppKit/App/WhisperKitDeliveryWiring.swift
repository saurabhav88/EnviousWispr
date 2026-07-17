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
        cancelActiveFetch: { [weak handle] in await handle?.cancelActiveFetch() })
    }

    // Availability is controller admission, never a directory probe. A refused
    // foreign copy is simply not an installed model: it is preserved untouched
    // and never loaded, and the shipped `.notDownloaded` + Download button is the
    // honest answer for an engine whose model is not installed.
    let setupService = WhisperKitSetupService(
      readAvailability: { [weak handle] in
        if await handle?.isAdmitted() == true { return .ready }
        return .notDownloaded
      },
      // The kill switch is checked HERE, at the fetch door, not only in the copy
      // above: a stale Settings render (or a flag flipped after the row drew)
      // must not still be able to start a multi-GB fetch.
      startDownload: { [weak handle] in
        guard handle?.isEnabled() == true else { return }
        _ = await handle?.ensureAvailable()
      },
      cancelActiveDownload: { [weak handle] in await handle?.cancelActiveFetch() })

    // One delivery-state stream projected onto the ASR setup states the Settings
    // row already renders (D6: one stream, two renderers).
    handle?.observeState { [weak setupService] state in
      guard let setupService else { return }
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
      case .cancelled, .notReady:
        Task { await setupService.forceDetectState() }
      }
    }

    return Wired(backend: backend, retirement: retirement, setupService: setupService)
  }
}
