#if DEBUG
  import EnviousWisprAppKitTestSupport
  import EnviousWisprCore
  import EnviousWisprPipeline
  import Foundation
  import Testing

  @testable import EnviousWisprAppKit

  /// The Pill Preview sample table and its coverage promises (#3736).
  ///
  /// **A Harness Contract.** When these fail, a developer sees a missing, wrong or unsafe
  /// preview in Settings > Diagnostics. No customer ever sees this surface (it is `#if DEBUG`).
  @MainActor
  @Suite(.tags(.harnessContract))
  struct PillPreviewCatalogTests {

    private static let ignoreNote: PillPreviewNote = { _ in }

    @Test("every playable kind has rows and every excluded kind has none")
    func rowsMatchPolicy() {
      let rowKinds = Set(PillPreviewCatalog.all.map(\.kind))
      for kind in PillPreviewKind.allCases {
        switch PillPreviewCatalog.policy(for: kind) {
        case .playable:
          #expect(rowKinds.contains(kind), "playable kind \(kind) has no dropdown row")
        case .excluded(let exclusion):
          #expect(!rowKinds.contains(kind), "excluded kind \(kind) still has a playable row")
          #expect(!exclusion.reason.isEmpty, "excluded kind \(kind) states no reason")
        }
      }
      // Two-way control: the table is not trivially empty and something is excluded.
      #expect(!PillPreviewCatalog.all.isEmpty)
      #expect(!PillPreviewCatalog.exclusions.isEmpty)
    }

    @Test("a row is labelled with the kind of the request it makes")
    func rowKindMatchesRequest() {
      for entry in PillPreviewCatalog.all {
        let request = entry.make(Self.ignoreNote)
        #expect(
          PillPreviewCatalog.kind(of: request) == entry.kind,
          "row \(entry.id) says \(entry.kind) but makes a different kind")
      }
    }

    @Test("row ids are unique")
    func idsAreUnique() {
      let ids = PillPreviewCatalog.all.map(\.id)
      #expect(Set(ids).count == ids.count)
    }

    @Test("every recording warning case has at least one row")
    func warningsCovered() {
      var covered = Set<String>()
      for entry in PillPreviewCatalog.all where entry.kind == .warning {
        if case .warning(let reason) = entry.make(Self.ignoreNote) {
          covered.insert(PillPreviewCatalog.warningCaseName(reason))
        }
      }
      #expect(covered == PillPreviewCatalog.allWarningCaseNames)
    }

    @Test("every error reason except permission denied has a row, and permission denied has none")
    func errorReasonsCovered() {
      var covered = Set<TerminalNoticeReason>()
      for entry in PillPreviewCatalog.all where entry.kind == .error {
        if case .error(let reason) = entry.make(Self.ignoreNote) { covered.insert(reason) }
      }
      var expected = Set(TerminalNoticeReason.allCases)
      expected.remove(.permissionDenied)
      #expect(covered == expected)
    }

    @Test("every playable row is admitted and shown by a fresh idle director")
    func everyRowIsPresented() {
      for entry in PillPreviewCatalog.all {
        let director = OverlayTestDouble.headlessDirector()
        var result: PillPresentationResult?
        let receipt = director.present(entry.make(Self.ignoreNote)) { result = $0 }
        #expect(receipt != nil, "row \(entry.id) was refused by an empty idle overlay")
        if let receipt {
          #expect(result == .presented(receipt), "row \(entry.id) was admitted but not shown")
        }
        #expect(
          director.renderModel.state.presentation != nil,
          "row \(entry.id) left the overlay empty")
      }
    }

    @Test("both learned-word kinds and both language-chip states have rows, all in the learned phase")
    func learnedAndChipVariantsCovered() {
      var learnedKinds = Set<String>()
      var chipStates: [LanguageChipDisplayState] = []
      for entry in PillPreviewCatalog.all {
        switch entry.make(Self.ignoreNote) {
        case .correctionLearned(let model, _, _, _):
          #expect(model.phase == .learned, "row \(entry.id) is not in the learned phase")
          learnedKinds.insert(model.kind == .added ? "added" : "updated")
        case .languageChip(let payload, _, _, _):
          chipStates.append(payload.state)
        default:
          break
        }
      }
      #expect(learnedKinds == ["added", "updated"])
      #expect(chipStates.contains(.askToLock) && chipStates.contains(.educateAboutSettings))
    }

    @Test("every value that changes a pill's text has a row")
    func valueDependentVariantsCovered() {
      let samples = PillPreviewCatalog.polishSetupSamples
      #expect(
        Set(samples.map { PillPreviewCatalog.polishProblemCaseName($0.problem) })
          == PillPreviewCatalog.allPolishProblemCaseNames)
      let sampleLines = samples.map { PolishSetupCardModel(problem: $0.problem).line }
      #expect(Set(sampleLines).count == sampleLines.count, "two setup samples show one sentence")

      var rowLines: [String] = []
      var tails = Set<String>()
      var warningTexts = Set<String>()
      var cachingLabels = Set<String>()
      var fractions = Set<Double>()
      for entry in PillPreviewCatalog.all {
        switch entry.make(Self.ignoreNote) {
        case .polishSetupCard(let model, _, _):
          rowLines.append(model.line)
        case .warning(let reason):
          warningTexts.insert(DictationNarrator.copy(for: reason))
          if case .interruptedTail(let disclosure, let trimmed) = reason {
            tails.insert("\(PillPreviewCatalog.disclosureName(disclosure)).\(trimmed)")
          }
        case .cachingModel(let label):
          cachingLabels.insert(label)
        case .parakeetUpgrade(let model, _):
          if case .downloading(let fraction) = model.phase { fractions.insert(fraction) }
        default:
          break
        }
      }
      #expect(rowLines.count == samples.count)
      #expect(Set(rowLines) == Set(sampleLines))
      #expect(
        tails == [
          "deviceRemoved.false", "deviceRemoved.true", "otherInterruption.false",
          "otherInterruption.true",
        ])
      for value in PillPreviewCatalog.historyClasses {
        #expect(warningTexts.contains(value.userMessage), "no row shows \(value)")
      }
      for backend in PillPreviewCatalog.backends {
        #expect(cachingLabels.contains(backend.displayName), "no warm-up row for \(backend)")
        #expect(
          warningTexts.contains(
            DictationNarrator.copy(for: .modelNotDownloaded(engineLabel: backend.displayName))),
          "no not-downloaded row for \(backend)")
      }
      #expect(fractions.isSuperset(of: [0.0, 0.4, 1.0]))
      #expect(
        Set(PillPreviewCatalog.historyClasses.map(PillPreviewCatalog.historyClassName)).count
          == 4)
      #expect(
        Set(PillPreviewCatalog.backends.map(PillPreviewCatalog.backendCaseName))
          == ["parakeet", "whisperKit"])
    }

    @Test("sample buttons only report to the status line")
    func sampleCallbacksAreInert() {
      var notes: [String] = []
      let note: PillPreviewNote = { notes.append($0) }

      if case .correctionLearned(_, let stillWanted, let onUndo, let onEnded) = rowRequest(
        "learned.added", note)
      {
        #expect(stillWanted())
        onUndo()
        onEnded()
      } else {
        Issue.record("learned.added did not make a correctionLearned request")
      }
      if case .escapeRecovery(_, let onPaste) = rowRequest("escape.undo", note) {
        onPaste(
          CancelUndoPayload(
            transcriptID: UUID(), targetApp: nil, targetElement: nil, targetWindow: nil,
            takeFacts: InsertionTakeFacts(
              snippetFired: false, lockedLanguageCode: nil, engineDetectsLanguage: false,
              engineReportedLanguage: nil, protectedSpellings: [])))
      } else {
        Issue.record("escape.undo did not make an escapeRecovery request")
      }
      #expect(notes.count == 3)
      #expect(notes.allSatisfy { !$0.isEmpty })
    }

    private func rowRequest(_ id: String, _ note: @escaping PillPreviewNote) -> PillRequest {
      guard let entry = PillPreviewCatalog.all.first(where: { $0.id == id }) else {
        Issue.record("no row with id \(id)")
        return .engineReady
      }
      return entry.make(note)
    }
  }

  /// Play and Dismiss never replace anything real (#3736).
  @MainActor
  @Suite(.tags(.harnessContract))
  struct PillPreviewControllerTests {

    private final class Busy {
      var pipelineBusy = false
    }

    private func make(
      busy: Busy = Busy(), director: OverlayDirector = OverlayTestDouble.headlessDirector()
    ) -> (PillPreviewController, OverlayDirector, Busy) {
      let controller = PillPreviewController(
        presenter: director,
        isPipelineBusy: { busy.pipelineBusy },
        overlayIsEmpty: { director.renderModel.state.presentation == nil })
      return (controller, director, busy)
    }

    /// A presenter that never presents, so a test decides when the host answers.
    @MainActor
    private final class StubPresenter: OverlayPresenting {
      private(set) var pendingResults: [(PillPresentationResult) -> Void] = []
      var featureSlotIsAvailable: Bool { true }
      func present(_ request: PillRequest) -> PillReceipt? { nil }
      func present(
        _ request: PillRequest, onResult: @escaping (PillPresentationResult) -> Void
      ) -> PillReceipt? {
        pendingResults.append(onResult)
        return nil
      }
      func update(_ update: PillUpdate) {}
      func dismissCurrent(_ mode: PillDismissal) {}
      func dismissIfCurrent(_ receipt: PillReceipt) {}
      func isCurrent(_ receipt: PillReceipt) -> Bool { false }
      func deliver(_ result: PillPresentationResult, at index: Int? = nil) {
        pendingResults[index ?? pendingResults.count - 1](result)
      }
    }

    private func stubbedController(_ presenter: StubPresenter) -> PillPreviewController {
      PillPreviewController(
        presenter: presenter, isPipelineBusy: { false }, overlayIsEmpty: { true })
    }

    @Test("Play shows the selected pill when the pipeline is idle and the overlay is empty")
    func playShows() {
      let (controller, director, _) = make()
      controller.isReviewEnabled = true
      controller.play()
      #expect(director.renderModel.state.presentation != nil)
      if case .shown = controller.outcome {
      } else {
        Issue.record("outcome was \(controller.outcome)")
      }
    }

    @Test("Play refuses while the real pipeline is busy")
    func playRefusesWhenBusy() {
      let busy = Busy()
      busy.pipelineBusy = true
      let (controller, director, _) = make(busy: busy)
      controller.play()
      #expect(director.renderModel.state.presentation == nil)
      if case .notShown = controller.outcome {
      } else {
        Issue.record("outcome was \(controller.outcome)")
      }
    }

    @Test("Play never replaces a real pill, even one featureSlotIsAvailable calls available")
    func playRefusesOverRealPills() {
      let realPills: [(String, PillRequest)] = [
        ("importStatus", .importStatus(message: "real import")),
        (
          "parakeetUpgrade",
          .parakeetUpgrade(ParakeetUpgradePillModel(phase: .installing), isStillWanted: { true })
        ),
        (
          "saveError",
          .correctionLearnedSaveError(
            LearnedCorrectionSaveError(canonical: "real", reason: .targetGone))
        ),
        ("retainedClipboard", .retainedClipboardFallback(takeID: "real", isStillWanted: { true })),
        ("engineReady", .engineReady),
      ]
      for (name, real) in realPills {
        let director = OverlayTestDouble.headlessDirector()
        let (controller, _, _) = make(director: director)
        guard let receipt = director.present(real) else {
          Issue.record("\(name): the real pill was not admitted on an empty overlay")
          continue
        }
        let before = director.renderModel.state.presentation?.id
        controller.play()
        #expect(director.isCurrent(receipt), "\(name): the real pill was replaced")
        #expect(director.renderModel.state.presentation?.id == before, "\(name): slot changed")
        if case .notShown = controller.outcome {
        } else {
          Issue.record("\(name): outcome was \(controller.outcome)")
        }
      }
    }

    @Test("Play replaces the controller's own preview")
    func playReplacesOwnPreview() {
      let (controller, director, _) = make()
      controller.play()
      let first = director.renderModel.state.presentation?.id
      controller.selectedID = PillPreviewCatalog.all.last?.id ?? ""
      controller.play()
      let second = director.renderModel.state.presentation?.id
      #expect(first != nil && second != nil && first != second)
    }

    @Test("Dismiss clears its own preview")
    func dismissClears() {
      let (controller, director, _) = make()
      controller.play()
      #expect(director.renderModel.state.presentation != nil, "the first Play showed nothing")
      controller.dismiss()
      #expect(director.renderModel.state.presentation == nil)
      #expect(controller.outcome == .idle)
    }

    @Test("Play with an unknown selection says so instead of keeping an old success")
    func unknownSelectionIsReported() {
      let (controller, _, _) = make()
      controller.play()
      #expect(controller.outcome == .shown("Learned word Undo (added)"))
      controller.selectedID = "no-such-row"
      controller.play()
      #expect(controller.outcome == .notShown("no preview is selected"))
    }

    @Test("a learned preview that runs out its dwell tells only the status line")
    func learnedExpiryIsInert() {
      let clock = LearnedPillClock()
      let director = OverlayDirector(
        host: WindowlessOverlayHost(), scheduler: clock.scheduler, announce: { _ in },
        livePreview: .disabled, grantAccessibility: {}, openMicrophoneSettings: {},
        advisoryHint: { _ in nil }, selections: { .shipped }, firstRenderSchedule: { $0() })
      let (controller, _, _) = make(director: director)
      controller.selectedID = "learned.added"
      controller.play()
      #expect(director.renderModel.state.presentation != nil, "the learned preview never showed")
      clock.advance(to: 1000)
      #expect(director.renderModel.state.presentation == nil, "the preview did not expire")
      #expect(controller.lastEvent == "Preview ended")
    }

    @Test("a dictation Undo preview that expires never pastes")
    func escapeExpiryNeverPastes() {
      let clock = LearnedPillClock()
      let director = OverlayDirector(
        host: WindowlessOverlayHost(), scheduler: clock.scheduler, announce: { _ in },
        livePreview: .disabled, grantAccessibility: {}, openMicrophoneSettings: {},
        advisoryHint: { _ in nil }, selections: { .shipped }, firstRenderSchedule: { $0() })
      let (controller, _, _) = make(director: director)
      controller.selectedID = "escape.undo"
      controller.play()
      #expect(director.renderModel.state.presentation != nil, "the Undo preview never showed")
      clock.advance(to: 1000)
      #expect(director.renderModel.state.presentation == nil, "the preview did not expire")
      #expect(controller.lastEvent == nil, "expiry reached the sample paste callback")
    }

    @Test("a result that arrives after Dismiss cannot change the status")
    func lateResultAfterDismissIsIgnored() {
      let presenter = StubPresenter()
      let controller = stubbedController(presenter)
      controller.play()
      controller.dismiss()
      presenter.deliver(.notPresented)
      #expect(controller.outcome == .idle, "a late host answer overwrote the status")
    }

    @Test("a result from an earlier Play cannot change what a newer Play reports")
    func staleResultFromEarlierPlayIsIgnored() {
      let presenter = StubPresenter()
      let controller = stubbedController(presenter)
      controller.play()
      controller.play()
      #expect(presenter.pendingResults.count == 2)
      presenter.deliver(.notPresented, at: 0)
      #expect(
        controller.outcome == .pending("Learned word Undo (added)"),
        "the first Play's answer overwrote the second Play's status")
    }

    @Test("a refused presentation is reported as not shown")
    func refusedPresentationIsReported() {
      let presenter = StubPresenter()
      let controller = stubbedController(presenter)
      controller.play()
      presenter.deliver(.notPresented)
      #expect(controller.outcome == .notShown("the overlay refused it"))
    }

    @Test("a deferred first render reports pending, then shown")
    func deferredRenderReportsShown() {
      var deferred: (() -> Void)?
      let director = OverlayDirector(
        host: WindowlessOverlayHost(), announce: { _ in }, livePreview: .disabled,
        grantAccessibility: {}, openMicrophoneSettings: {}, advisoryHint: { _ in nil },
        selections: { .shipped }, firstRenderSchedule: { deferred = $0 })
      let (controller, _, _) = make(director: director)
      controller.play()
      #expect(controller.outcome == .pending("Learned word Undo (added)"))
      deferred?()
      #expect(controller.outcome == .shown("Learned word Undo (added)"))
    }

    @Test("Turning review mode off clears the preview")
    func reviewOffClears() {
      let (controller, director, _) = make()
      controller.isReviewEnabled = true
      controller.play()
      #expect(director.renderModel.state.presentation != nil)
      controller.isReviewEnabled = false
      #expect(director.renderModel.state.presentation == nil)
    }

    @Test("Dismiss leaves a real pill that replaced the preview")
    func dismissKeepsReplacement() {
      let (controller, director, _) = make()
      controller.play()
      #expect(director.renderModel.state.presentation != nil, "the first Play showed nothing")
      // A real recording replaces a feature pill preview (an import notice would be refused).
      let recording = PillRequest.recording(
        RecordingPillInput(
          audioLevel: 0, audioLevelProvider: { 0 }, recordingElapsedProvider: { nil },
          isLocked: false))
      guard let real = director.present(recording) else {
        Issue.record("the real recording was refused")
        return
      }
      controller.dismiss()
      #expect(director.isCurrent(real), "Dismiss removed the real recording")
    }
  }
#endif
