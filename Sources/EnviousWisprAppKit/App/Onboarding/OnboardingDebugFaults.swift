#if DEBUG
  import EnviousWisprCore
  import EnviousWisprModelDelivery
  import Foundation

  /// The approved Setup faults for CLI UAT (#4528 plan §3.9, the door's `onboarding fault`).
  enum OnboardingFault: String, CaseIterable, Sendable {
    case downloadFail = "download-fail"
    case slowNetwork = "slow-network"
    case diskShort = "disk-short"
    case keyInvalid = "key-invalid"
    case warmFail = "warm-fail"
    case polishFail = "polish-fail"
  }

  /// Active DEBUG faults, applied only at Setup's own boundaries (the download and readiness
  /// closures, free disk, progress samples). No fault touches a real credential, model cache,
  /// delivery policy or setting: a faulted request is answered synthetically and never reaches
  /// its owner. Read on every call, so a fault turns on and off while Setup runs.
  @MainActor
  enum OnboardingDebugFaults {
    static var active: Set<OnboardingFault> = []

    /// The failure a faulted speech download reports, marked synthetic.
    static let simulatedDeliveryFailure = DeliveryFailure(
      reason: .sourceUnreachable, detail: "simulated_fault")

    static func apply(to owners: OnboardingDownloadOwners) -> OnboardingDownloadOwners {
      var faulted = owners
      let real = owners
      faulted.requestSpeech = { engine in
        // `download-fail`: accepted, then failed, without starting a real transfer.
        if active.contains(.downloadFail) {
          return real.speechReportsEnd(engine) ? .ended(.failed) : .accepted
        }
        return await real.requestSpeech(engine)
      }
      faulted.speechPhase = { engine in
        if active.contains(.downloadFail), real.speechPhase(engine) != .installed {
          return .failed(.delivery(simulatedDeliveryFailure))
        }
        return real.speechPhase(engine)
      }
      return faulted
    }

    /// The failure a faulted warm-up reports, marked synthetic.
    struct SimulatedWarmFailure: Error {}

    /// `warm-fail`: the warm-up answers a labelled failure without calling the owner, so the
    /// failure path (warmFailed, `warmup_failed`, Retry) runs with no real load touched.
    static func apply(to warmup: OnboardingWarmup) -> OnboardingWarmup {
      OnboardingWarmup(
        run: {
          if active.contains(.warmFail) { return .failed(SimulatedWarmFailure()) }
          return await warmup.run()
        },
        cancel: warmup.cancel)
    }

    static func apply(to sources: OnboardingReadinessSources) -> OnboardingReadinessSources {
      var faulted = sources
      let real = sources
      faulted.engine = {
        // `warm-fail`: the selected engine never reads ready.
        let engine = real.engine()
        return active.contains(.warmFail) ? (engine.selected, .notReady) : engine
      }
      faulted.localPolish = { model in
        // `polish-fail`: the picked local model fails to load (Getting ready's failure path,
        // plan §7); installed stays installed, so recovery after clearing needs no download.
        guard active.contains(.polishFail), let state = real.localPolish(model) else {
          return real.localPolish(model)
        }
        return OnboardingLocalPolishState(installed: state.installed, serverReady: state.serverReady, healthy: false)
      }
      faulted.cloudEvidence = { provider in
        // `key-invalid`: the current check reads rejected.
        guard active.contains(.keyInvalid), let evidence = real.cloudEvidence(provider) else {
          return real.cloudEvidence(provider)
        }
        return OnboardingCloudEvidence(
          provider: evidence.provider, model: evidence.model,
          checkedRevision: evidence.checkedRevision, currentRevision: evidence.currentRevision,
          accepted: false)
      }
      return faulted
    }
  }
#endif
