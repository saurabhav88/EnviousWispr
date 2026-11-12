import EnviousWisprASR
import EnviousWisprCore
import EnviousWisprLocalPolish
import EnviousWisprModelDelivery
import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #4528 C2a: Setup's downloads go through the existing owners in the right order.
///
/// **Product Outcome.** When this fails, Setup warms or loads a model the person did not pick,
/// downloads a model that is already on the Mac, starts a download for Apple Intelligence or a
/// cloud key, shows a refused download as running forever, or cancels the wrong download.
@MainActor
@Suite(.tags(.productOutcome))
struct OnboardingDownloadsTests {
  /// Records every owner call in order; answers come from its fields.
  @MainActor
  final class Owners {
    var calls: [String] = []
    var enabled: Set<ASRBackendType> = [.parakeet, .whisper]
    var installedSpeech: Set<ASRBackendType> = []
    var polish: [LocalPolishModelID: OnboardingDownloadPhase] = [:]
    var acceptsPolishStart = true
    var acceptsSpeechRequest = true
    var clearsBlock = true
    var selected: ASRBackendType = .parakeet
    /// Runs inside the admission read, to change the world while the start is suspended.
    var duringAdmission: () -> Void = {}

    func make() -> OnboardingDownloadOwners {
      OnboardingDownloadOwners(
        speechDeliveryEnabled: { self.enabled.contains($0) },
        speechInstalled: { engine in
          self.calls.append("installed?(\(engine))")
          self.duringAdmission()
          return self.installedSpeech.contains(engine)
        },
        writeSelectedBackend: { engine in
          self.calls.append("select(\(engine))")
          self.selected = engine
        },
        selectedBackend: { self.selected },
        requestSpeech: { engine in
          self.calls.append("request(\(engine))")
          return self.acceptsSpeechRequest
        },
        cancelSpeech: { self.calls.append("cancel(\($0))") },
        clearSpeechBlock: { engine in
          self.calls.append("clearBlock(\(engine))")
          return self.clearsBlock
        },
        speechPhase: { _ in .notStarted },
        writePolishSelection: { self.calls.append("selectPolish(\(Self.name($0)))") },
        polishPhase: { self.polish[$0] ?? .notStarted },
        requestPolish: { model in
          self.calls.append("requestPolish(\(Self.name(model)))")
          return self.acceptsPolishStart
        },
        cancelPolish: { self.calls.append("cancelPolish(\(Self.name($0)))") },
        activatePolish: { self.calls.append("activate(\(Self.name($0)))") })
    }

    static func name(_ model: LocalPolishModelID) -> String {
      model.size.map { "\(model.provider.rawValue).\($0.rawValue)" } ?? model.provider.rawValue
    }
  }

  // MARK: Speech

  @Test("a speech pick is written before its download is requested, for both engines")
  func speechSelectionPrecedesRequest() async {
    for engine in [ASRBackendType.parakeet, .whisper] {
      let owners = Owners()
      let start = await OnboardingDownloads(owners: owners.make()).startSpeech(engine)
      #expect(start == OnboardingStart(id: engine, answer: .requested))
      #expect(owners.calls == ["select(\(engine))", "installed?(\(engine))", "request(\(engine))"])
    }
  }

  @Test("an installed speech model is adopted without another download")
  func installedSpeechIsNotDownloaded() async {
    let owners = Owners()
    owners.installedSpeech = [.whisper]
    let start = await OnboardingDownloads(owners: owners.make()).startSpeech(.whisper)
    #expect(start.answer == .alreadyInstalled)
    #expect(!owners.calls.contains("request(whisper)"))
  }

  @Test(
    "a delivery kill switch refuses the start without requesting, and Retry clears the block first")
  func refusedSpeechAndRetry() async {
    let owners = Owners()
    owners.enabled = []
    let downloads = OnboardingDownloads(owners: owners.make())
    #expect(await downloads.startSpeech(.parakeet).answer == .refused)
    #expect(!owners.calls.contains("request(parakeet)"))

    owners.enabled = [.parakeet]
    owners.calls = []
    #expect(
      await downloads.retrySpeech(.parakeet) == OnboardingStart(id: .parakeet, answer: .requested))
    #expect(owners.calls.first == "clearBlock(parakeet)")
    #expect(owners.calls.last == "request(parakeet)")
  }

  @Test("a pick changed or a start cancelled during the admission read requests nothing")
  func supersededStartRequestsNothing() async {
    let owners = Owners()
    owners.duringAdmission = { owners.selected = .whisper }
    let downloads = OnboardingDownloads(owners: owners.make())
    #expect(await downloads.startSpeech(.parakeet) == OnboardingStart(id: .parakeet, answer: .superseded))
    #expect(!owners.calls.contains("request(parakeet)"))

    let cancelled = Owners()
    cancelled.duringAdmission = { withUnsafeCurrentTask { $0?.cancel() } }
    let task = Task { await OnboardingDownloads(owners: cancelled.make()).startSpeech(.whisper) }
    #expect(await task.value.answer == .superseded)
    #expect(!cancelled.calls.contains("request(whisper)"))
  }

  @Test("an owner's own refusal reads as refused, and a refused unblock stops the Retry")
  func ownerRefusalPropagates() async {
    let owners = Owners()
    owners.acceptsSpeechRequest = false
    let downloads = OnboardingDownloads(owners: owners.make())
    #expect(await downloads.startSpeech(.parakeet).answer == .refused)
    #expect(owners.calls.last == "request(parakeet)")

    owners.acceptsSpeechRequest = true
    owners.clearsBlock = false
    owners.calls = []
    #expect(await downloads.retrySpeech(.parakeet).answer == .refused)
    #expect(owners.calls == ["clearBlock(parakeet)"])
  }

  @Test("cancel reaches the named engine's owner")
  func cancelSpeechTargetsTheEngine() {
    let owners = Owners()
    OnboardingDownloads(owners: owners.make()).cancelSpeech(.whisper)
    #expect(owners.calls == ["cancel(whisper)"])
  }

  // MARK: Polish

  @Test("a local polish pick is written before its download, for every EG-1 size and S1-mini")
  func polishSelectionPrecedesRequest() {
    for (id, name) in [
      ("eg1.full", "egOne.full"), ("eg1.mini", "egOne.mini"), ("eg1.micro", "egOne.micro"),
      ("s1mini", "s1Mini"),
    ] {
      let owners = Owners()
      let start = OnboardingDownloads(owners: owners.make()).startPolish(id)
      #expect(start == OnboardingStart(id: id, answer: .requested), "\(id)")
      #expect(owners.calls == ["selectPolish(\(name))", "requestPolish(\(name))"], "\(id)")
    }
  }

  @Test("an installed polish model is loaded for the current pick instead of downloaded")
  func installedPolishIsActivated() {
    let owners = Owners()
    owners.polish[.egOne(.mini)] = .installed
    let start = OnboardingDownloads(owners: owners.make()).startPolish("eg1.mini")
    #expect(start.answer == .alreadyInstalled)
    #expect(owners.calls == ["selectPolish(egOne.mini)", "activate(egOne.mini)"])
  }

  @Test("Apple Intelligence, a cloud key and polish off start no local download")
  func noLocalDownloadForOtherPicks() {
    for id in ["appleIntelligence", OnboardingChoices.polishCloud, OnboardingChoices.polishOff] {
      let owners = Owners()
      let downloads = OnboardingDownloads(owners: owners.make())
      #expect(downloads.startPolish(id) == OnboardingStart(id: id, answer: .noDownload), "\(id)")
      downloads.cancelPolish(id)
      #expect(downloads.polishPhase(id) == nil, "\(id)")
      #expect(owners.calls.isEmpty, "\(id)")
    }
  }

  @Test("a runtime that does not accept the start reads as refused; cancel targets the pick")
  func refusedPolishAndCancel() {
    let owners = Owners()
    owners.acceptsPolishStart = false
    let downloads = OnboardingDownloads(owners: owners.make())
    #expect(downloads.retryPolish("eg1.full").answer == .refused)
    downloads.cancelPolish("eg1.full")
    #expect(owners.calls.last == "cancelPolish(egOne.full)")
  }

  // MARK: Owner state → phase

  @Test("Parakeet's delivery state maps to Setup's phase; a spent attempt budget is unavailable")
  func parakeetPhase() {
    let failure = DeliveryFailure(reason: .sourceTimeout)
    let rows: [(DeliveryState, OnboardingDownloadPhase)] = [
      (.notReady, .notStarted),
      (.preparing(validatingExistingCache: false), .downloading(fraction: nil)),
      (
        .downloading(fractionCompleted: 0.4, bytesWritten: 4, totalBytes: 10),
        .downloading(fraction: 0.4)
      ),
      (.verifying, .verifying), (.admitted, .installed), (.cancelled(resumable: true), .paused),
      (.cancelled(resumable: false), .notStarted), (.failed(failure), .failed(.delivery(failure))),
    ]
    for (state, phase) in rows {
      #expect(
        OnboardingDownloads.phase(parakeet: state, needsExplicitRetry: false) == phase, "\(state)")
    }
    #expect(
      OnboardingDownloads.phase(
        parakeet: .downloading(fractionCompleted: 0.4, bytesWritten: 4, totalBytes: 10),
        needsExplicitRetry: true) == .unavailable)
  }

  @Test("Whisper's and the local engines' states map to Setup's phase with the owner's failure")
  func whisperAndLocalPolishPhase() {
    #expect(OnboardingDownloads.phase(whisper: .ready) == .installed)
    #expect(OnboardingDownloads.phase(whisper: .paused) == .paused)
    #expect(OnboardingDownloads.phase(whisper: .error("x")) == .failed(.whisper("x")))
    #expect(
      OnboardingDownloads.phase(whisper: .downloading(progress: 0.5, status: ""))
        == .downloading(fraction: 0.5))
    #expect(OnboardingDownloads.phase(localPolish: .installed(version: "1")) == .installed)
    #expect(
      OnboardingDownloads.phase(localPolish: .failed(.network)) == .failed(.localPolish(.network)))
    #expect(OnboardingDownloads.phase(localPolish: .failed(.cancelled)) == .paused)
    #expect(
      OnboardingDownloads.phase(localPolish: .updatePaused(resumable: true, targetVersion: nil))
        == .paused)
  }
}
