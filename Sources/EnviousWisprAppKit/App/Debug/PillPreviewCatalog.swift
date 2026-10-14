#if DEBUG
  import EnviousWisprCore
  import EnviousWisprPipeline
  import EnviousWisprServices
  import Foundation

  // The sample table behind Settings > Diagnostics > Pill Preview (#3736).
  //
  // This file owns two things and nothing else: what a SAMPLE of each pill looks like as a
  // `PillRequest`, and which kinds may be previewed at all. The look, the timing and the
  // admission rules stay with `PillCatalog`, the reducer and the director, because a preview
  // is a normal request sent through the same door a real pill uses.

  /// Every top-level `PillRequest` kind. The exhaustive switch in
  /// `PillPreviewCatalog.kind(of:)` has no `default`, so adding a `PillRequest` case fails the
  /// build until it is classified here.
  enum PillPreviewKind: CaseIterable, Hashable {
    case recording
    case processing
    case clipboardFallback
    case warning
    case error
    case advisory
    case interruption
    case cachingModel
    case engineReady
    case recoverySucceeded
    case importStatus
    case accessibilityNotice
    case recoveryNotice
    case languageChip
    case bluetoothAwareness
    case parakeetUpgrade
    case polishSetupCard
    case escapeRecovery
    case correctionLearned
    case correctionLearnedSaveError
    case retainedClipboardFallback
  }

  enum PillPreviewPolicy: Equatable {
    case playable
    /// The request carries a live effect a sample callback cannot make inert.
    case excluded(PillPreviewExclusion)
  }

  /// What a sample callback tells the controller. The text is shown in the Diagnostics status
  /// line; nothing else happens, which is what makes every sample button inert.
  typealias PillPreviewNote = @MainActor (String) -> Void

  /// One playable row in the drop-down.
  @MainActor
  struct PillPreviewEntry: Identifiable {
    let id: String
    let kind: PillPreviewKind
    let group: String
    let title: String
    let make: (@escaping PillPreviewNote) -> PillRequest
  }

  /// A row that is deliberately NOT playable, with the reason shown to the developer.
  struct PillPreviewExclusion: Equatable {
    let title: String
    let reason: String
  }

  @MainActor
  enum PillPreviewCatalog {

    // MARK: - Coverage guarantees

    /// Build-time guarantee: a new `PillRequest` case does not compile until it is named here.
    static func kind(of request: PillRequest) -> PillPreviewKind {
      switch request {
      case .recording: return .recording
      case .processing: return .processing
      case .clipboardFallback: return .clipboardFallback
      case .warning: return .warning
      case .error: return .error
      case .advisory: return .advisory
      case .interruption: return .interruption
      case .cachingModel: return .cachingModel
      case .engineReady: return .engineReady
      case .recoverySucceeded: return .recoverySucceeded
      case .importStatus: return .importStatus
      case .accessibilityNotice: return .accessibilityNotice
      case .recoveryNotice: return .recoveryNotice
      case .languageChip: return .languageChip
      case .bluetoothAwareness: return .bluetoothAwareness
      case .parakeetUpgrade: return .parakeetUpgrade
      case .polishSetupCard: return .polishSetupCard
      case .escapeRecovery: return .escapeRecovery
      case .correctionLearned: return .correctionLearned
      case .correctionLearnedSaveError: return .correctionLearnedSaveError
      case .retainedClipboardFallback: return .retainedClipboardFallback
      }
    }

    /// Whether a kind may be previewed. Exhaustive with no `default`, so a new kind forces a
    /// decision here as well.
    static func policy(for kind: PillPreviewKind) -> PillPreviewPolicy {
      switch kind {
      case .recording:
        return .excluded(
          PillPreviewExclusion(
            title: "Recording pill",
            reason:
              "Showing it starts a real Live Preview session. Use a real dictation to see it."))
      case .accessibilityNotice:
        return .excluded(
          PillPreviewExclusion(
            title: "Accessibility notice",
            reason:
              "Showing it uses up the once-per-session Accessibility prompt, and its Grant button asks macOS for permission."
          ))
      case .processing, .clipboardFallback, .warning, .error, .advisory, .interruption,
        .cachingModel, .engineReady, .recoverySucceeded, .importStatus, .recoveryNotice,
        .languageChip, .bluetoothAwareness, .parakeetUpgrade, .polishSetupCard,
        .escapeRecovery, .correctionLearned, .correctionLearnedSaveError,
        .retainedClipboardFallback:
        return .playable
      }
    }

    /// Variants of a playable kind that are still not playable.
    static let excludedVariants: [PillPreviewExclusion] = [
      PillPreviewExclusion(
        title: "Error: permission denied",
        reason: "Its Open Settings button calls a live microphone permission handler."),
      PillPreviewExclusion(
        title: "Learned word Undo results (Undone, Couldn't undo)",
        reason: "They only appear after a real Undo press, as a change to the pill on screen."),
      PillPreviewExclusion(
        title: "Notices inside a recording pill",
        reason: "They need a live recording pill to appear inside."),
    ]

    /// Everything the Diagnostics page lists as not previewable, kinds first.
    static var exclusions: [PillPreviewExclusion] {
      let kinds: [PillPreviewExclusion] = PillPreviewKind.allCases.compactMap { kind in
        guard case .excluded(let exclusion) = policy(for: kind) else { return nil }
        return exclusion
      }
      return kinds + excludedVariants
    }

    // MARK: - Rows

    /// Group names in drop-down order.
    static let groupOrder = [
      "Undo pills", "Cards and chips", "Notices", "Warnings", "Errors", "Advisories",
      "Interruptions",
    ]

    /// The names of every `RecordingWarningReason` case, by exhaustive switch. The enum is not
    /// `CaseIterable` (its cases carry values), so this is where a new case is forced into view.
    static func warningCaseName(_ reason: RecordingWarningReason) -> String {
      switch reason {
      case .modelNotDownloaded: return "modelNotDownloaded"
      case .polishFailed: return "polishFailed"
      case .historySaveFailed: return "historySaveFailed"
      case .escapeRecoveryUnavailable: return "escapeRecoveryUnavailable"
      case .salvagedBeginning: return "salvagedBeginning"
      case .interruptedTail: return "interruptedTail"
      case .sharedEngineBusy: return "sharedEngineBusy"
      }
    }

    /// Every warning case name a complete table must cover.
    static let allWarningCaseNames: Set<String> = [
      "modelNotDownloaded", "polishFailed", "historySaveFailed", "escapeRecoveryUnavailable",
      "salvagedBeginning", "interruptedTail", "sharedEngineBusy",
    ]

    /// Sample warning reasons. Fake data only.
    private static let warningSamples: [RecordingWarningReason] = [
      .modelNotDownloaded(engineLabel: "Parakeet"),
      .polishFailed,
      .historySaveFailed(reason: "disk full"),
      .escapeRecoveryUnavailable,
      .salvagedBeginning,
      .interruptedTail(disclosure: .deviceRemoved, alsoTrimmedLead: false),
      .interruptedTail(disclosure: .otherInterruption, alsoTrimmedLead: true),
    ]

    private static let interruptionReasons: [TerminalNoticeReason] = [
      .deviceRemoved, .engineLost, .unknownInterruption,
    ]

    private static func row(
      _ id: String, _ kind: PillPreviewKind, _ group: String, _ title: String,
      make: @escaping (@escaping PillPreviewNote) -> PillRequest
    ) -> PillPreviewEntry {
      PillPreviewEntry(id: id, kind: kind, group: group, title: title, make: make)
    }

    /// Every playable row. Samples use fresh fake IDs and obviously fake text, never real data.
    static let all: [PillPreviewEntry] = {
      var rows: [PillPreviewEntry] = []

      // Undo pills.
      for kind in [LearnedCorrectionPillModel.Kind.added, .updated] {
        let name = kind == .added ? "added" : "updated"
        rows.append(
          row(
            "learned.\(name)", .correctionLearned, "Undo pills",
            "Learned word Undo (\(name))"
          ) { note in
            let model = LearnedCorrectionPillModel(
              id: UUID(), wordID: UUID(), canonical: "Preview word", kind: kind)
            return .correctionLearned(
              model: model,
              isStillWanted: { true },
              onUndo: { note("Undo pressed (preview only, no word was changed)") },
              onEnded: { note("Pill ended on its own") })
          })
      }
      rows.append(
        row("escape.undo", .escapeRecovery, "Undo pills", "Dictation Undo (Escape Recovery)") {
          note in
          let facts = InsertionTakeFacts(
            snippetFired: false, lockedLanguageCode: nil, engineDetectsLanguage: false,
            engineReportedLanguage: nil, protectedSpellings: [])
          let payload = CancelUndoPayload(
            transcriptID: UUID(), targetApp: nil, targetElement: nil, targetWindow: nil,
            takeFacts: facts)
          return .escapeRecovery(
            payload: payload,
            onPaste: { _ in note("Paste pressed (preview only, nothing was pasted)") })
        })
      rows.append(
        row(
          "learned.saveError", .correctionLearnedSaveError, "Undo pills",
          "Learned word save error"
        ) { _ in
          .correctionLearnedSaveError(
            LearnedCorrectionSaveError(canonical: "Preview word", reason: .vocabularyWriteFailed))
        })

      // Cards and chips.
      rows.append(
        row("chip.ask", .languageChip, "Cards and chips", "Language chip (ask to lock)") { note in
          .languageChip(
            payload: LanguageChipPayload(
              lang: "es", displayName: "Spanish", state: .askToLock, generation: 1),
            onLock: { note("Lock pressed (preview only)") },
            onDismiss: { note("Dismiss pressed (preview only)") },
            onExpire: { note("Chip ended on its own") })
        })
      rows.append(
        row("chip.educate", .languageChip, "Cards and chips", "Language chip (settings hint)") {
          note in
          .languageChip(
            payload: LanguageChipPayload(
              lang: "fr", displayName: "French", state: .educateAboutSettings, generation: 1),
            onLock: { note("Lock pressed (preview only)") },
            onDismiss: { note("Dismiss pressed (preview only)") },
            onExpire: { note("Chip ended on its own") })
        })
      rows.append(
        row("bluetooth", .bluetoothAwareness, "Cards and chips", "Bluetooth awareness card") {
          note in
          .bluetoothAwareness(
            onAcknowledge: { note("Got it pressed (preview only)") },
            onClose: { note("Close pressed (preview only)") },
            onOpenSettings: { note("Adjust settings pressed (preview only)") })
        })
      rows.append(
        row("polishSetup.ollama", .polishSetupCard, "Cards and chips", "AI polish setup card") {
          note in
          .polishSetupCard(
            model: PolishSetupCardModel(problem: .ollamaNotRunning),
            onFinishSetup: { note("Finish setup pressed (preview only)") },
            onNotNow: { note("Not now pressed (preview only)") })
        })
      rows.append(
        row("recoveryNotice", .recoveryNotice, "Cards and chips", "Crash recovery notice") {
          note in
          .recoveryNotice(onDiscard: { note("Discard pressed (preview only)") })
        })

      // Notices.
      for phase in ProcessingPhase.allCases {
        rows.append(
          row(
            "processing.\(phase)", .processing, "Notices", "Processing: \(phase)"
          ) { _ in .processing(phase: phase) })
      }
      rows.append(
        row("clipboardFallback", .clipboardFallback, "Notices", "Copied to clipboard") { _ in
          .clipboardFallback
        })
      rows.append(
        row(
          "retainedClipboard", .retainedClipboardFallback, "Notices",
          "Copied to clipboard (kept words)"
        ) { _ in .retainedClipboardFallback(takeID: "preview-take", isStillWanted: { true }) })
      rows.append(
        row("cachingModel", .cachingModel, "Notices", "Warming up the engine") { _ in
          .cachingModel(engineLabel: "Parakeet")
        })
      rows.append(
        row("engineReady", .engineReady, "Notices", "Engine ready") { _ in .engineReady })
      rows.append(
        row("recoverySucceeded", .recoverySucceeded, "Notices", "Recovery succeeded") { _ in
          .recoverySucceeded
        })
      rows.append(
        row("importStatus", .importStatus, "Notices", "Import status") { _ in
          .importStatus(message: "Importing 3 files")
        })
      let upgradePhases: [(String, ParakeetUpgradePillModel.Phase)] = [
        ("downloading", .downloading(fraction: 0.4)), ("installing", .installing),
        ("ready", .ready),
      ]
      for (name, phase) in upgradePhases {
        rows.append(
          row(
            "parakeetUpgrade.\(name)", .parakeetUpgrade, "Notices", "Parakeet upgrade (\(name))"
          ) { _ in
            .parakeetUpgrade(ParakeetUpgradePillModel(phase: phase), isStillWanted: { true })
          })
      }

      // Warnings.
      for (index, reason) in warningSamples.enumerated() {
        let name = warningCaseName(reason)
        rows.append(
          row("warning.\(index).\(name)", .warning, "Warnings", "Warning: \(name) (\(index + 1))") {
            _ in .warning(reason: reason)
          })
      }
      for holder in SharedEngineHolder.allCases {
        rows.append(
          row(
            "warning.sharedEngineBusy.\(holder.rawValue)", .warning, "Warnings",
            "Warning: sharedEngineBusy (\(holder.rawValue))"
          ) { _ in .warning(reason: .sharedEngineBusy(holder: holder)) })
      }

      // Errors. Permission denied is an exclusion, see `excludedVariants`.
      for reason in TerminalNoticeReason.allCases where reason != .permissionDenied {
        rows.append(
          row("error.\(reason.rawValue)", .error, "Errors", "Error: \(reason.rawValue)") { _ in
            .error(reason: reason)
          })
      }

      // Advisories. A nil hint makes the director look up the live input device (a read only).
      for reason in TerminalAdvisoryReason.allCases {
        rows.append(
          row(
            "advisory.\(reason)", .advisory, "Advisories", "Advisory: \(reason)"
          ) { _ in .advisory(reason: reason) })
      }
      rows.append(
        row(
          "advisory.zeroSignal.hint", .advisory, "Advisories",
          "Advisory: zeroSignal (with device name)"
        ) { _ in
          .advisory(
            reason: .zeroSignal, hint: MultiInputAdvisoryHint(deviceName: "Preview Interface"))
        })

      // Interruptions.
      for reason in interruptionReasons {
        rows.append(
          row(
            "interruption.\(reason.rawValue)", .interruption, "Interruptions",
            "Interruption: \(reason.rawValue)"
          ) { _ in .interruption(reason: reason) })
      }

      return rows
    }()

    /// The rows in drop-down order: by group, then in table order within a group.
    static var orderedGroups: [(group: String, entries: [PillPreviewEntry])] {
      groupOrder.map { group in (group, all.filter { $0.group == group }) }
    }
  }
#endif
