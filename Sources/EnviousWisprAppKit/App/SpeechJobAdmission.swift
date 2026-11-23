import EnviousWisprCore

/// The one rule for which speech engine a job may use, decided before any work starts (#4578,
/// plan §3.3). Pure: it reads only its arguments. `SpeechModelLibrary` supplies the installed
/// set; each job's owner calls `decide` at its own start and renders a `.stop` through the
/// notice or terminal it already has.
enum SpeechJobAdmission {
  /// A piece of work that needs a speech engine.
  enum Job: Equatable, Sendable {
    case dictation
    case fileImport
    case recoveryReplay
    case benchmark
    case meetingStart
    case meetingTranscript
    case meetingRetranscribe
    /// "Transcribe again with" on an imported file: the person picked the model by name.
    case importedFileRetranscribe
  }

  enum StopReason: Equatable, Sendable {
    /// The requested engine is not on this Mac (the "isn't downloaded yet" notice).
    case engineNotDownloaded(ASRBackendType)
    /// No speech engine is on this Mac at all.
    case noEngineDownloaded
  }

  enum Decision: Equatable, Sendable {
    case use(ASRBackendType)
    /// Meetings only: the requested engine is missing, so the other installed one writes it.
    case useOther(ASRBackendType, insteadOf: ASRBackendType)
    case stop(StopReason)

    var engine: ASRBackendType? {
      switch self {
      case .use(let engine), .useOther(let engine, _): engine
      case .stop: nil
      }
    }
  }

  static func decide(
    _ job: Job, requested: ASRBackendType, installed: Set<ASRBackendType>
  ) -> Decision {
    if installed.contains(requested) { return .use(requested) }
    let other: ASRBackendType = requested == .parakeet ? .whisper : .parakeet
    let anyInstalled = !installed.isEmpty
    switch job {
    case .dictation, .fileImport, .benchmark, .recoveryReplay:
      // The person is present: never a silent switch.
      return .stop(.engineNotDownloaded(requested))
    case .importedFileRetranscribe:
      // The person picked the model by name: never a substitute.
      return .stop(anyInstalled ? .engineNotDownloaded(requested) : .noEngineDownloaded)
    case .meetingStart:
      // Recording proceeds when any engine can write the transcript later.
      return anyInstalled ? .use(requested) : .stop(.noEngineDownloaded)
    case .meetingTranscript, .meetingRetranscribe:
      return installed.contains(other)
        ? .useOther(other, insteadOf: requested) : .stop(.noEngineDownloaded)
    }
  }
}

/// #4578: a job refused because its engine is not on this Mac, carried through a job's existing
/// load-failure path (crash replay's terminal refusal) rather than a new one.
struct SpeechEngineNotDownloadedError: Error, Equatable {
  let engine: ASRBackendType
}
