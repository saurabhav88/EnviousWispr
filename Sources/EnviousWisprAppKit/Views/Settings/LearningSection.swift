import AppKit
import EnviousWisprCore
import EnviousWisprPipeline
import EnviousWisprServices
import SwiftUI

/// Settings copy is a projection of the same frozen-choice owner used by takes.
/// It has no delivery or provider selection rule of its own.
struct LearnedCheckerSettingsStatus: Equatable {
  let line: String
  let canRetry: Bool
  /// The status word for Fix words it learned (#5006), decided with the state.
  let readiness: LearnFromEditsSettingsPresentation.StatusWord
  static let retryTitle = LocalizedStringResource(
    "Try again",
    comment: "Your Words, Learn from: the self-learning dictionary row: retry the word check download.")

  /// A check that is installed and ready, named by its owner. Used for the shared word check
  /// (#3242), whose status is read without loading its model.
  init(checkedBy judge: LearnedWordJudge) {
    line = Self.checkedByLine(judge.displayName)
    canRetry = false
    readiness = .ready
  }

  private static func checkedByLine(_ judge: String) -> String {
    String(
      localized: "Available with \(judge)",
      comment: "Your Words, Learn from: the self-learning dictionary row: which word check is in use, or why none is.")
  }

  /// The status the row may show. With Enable Dictionary off no learned word is checked or
  /// applied and nothing downloads, so every line here ("Checked by...", "downloading...")
  /// would be untrue; the row shows none (#3255).
  static func shown(
    _ status: LearnedCheckerSettingsStatus?, dictionaryEnabled: Bool
  ) -> LearnedCheckerSettingsStatus? {
    dictionaryEnabled ? status : nil
  }

  init(selection: LearnedWordCheckerSelection) {
    // The judge's owner names it; the copy has no engine of its own, so a new
    // judge needs no edit here. Every dictation language is checked (#3105).
    let judge = selection.judge?.displayName
      ?? String(localized: "The polish engine", comment: "Your Words, Learn from: the self-learning dictionary row: which word check is in use, or why none is.")
    if selection.checker != nil {
      line = Self.checkedByLine(judge)
      canRetry = false
      readiness = .ready
      return
    }
    canRetry = selection.retryAvailable
    readiness = selection.absence == .engineHasNoChecker ? .notAvailable : .notReady
    switch selection.absence {
    case .adapterDownloading:
      line = String(
        localized: "\(judge)'s word check is downloading",
        comment: "Your Words, Learn from: the self-learning dictionary row: which word check is in use, or why none is.")
    case .adapterDeliveryFailed, .deliveryDisabled:
      line = selection.retryAvailable
        ? String(
          localized:
            "\(judge)'s word check couldn't download",
          comment: "Your Words, Learn from: the self-learning dictionary row: which word check is in use, or why none is.")
        : String(
          localized:
            "\(judge)'s word check isn't available yet",
          comment: "Your Words, Learn from: the self-learning dictionary row: which word check is in use, or why none is.")
    case .engineHasNoChecker:
      line = String(
        localized: "This polish choice can't check learned words.", comment: "Your Words, Learn from: the self-learning dictionary row: which word check is in use, or why none is.")
    case .baseNotAdmitted, .baseMismatch, .serverWithoutAdapter, .serverUnavailable,
      .selectionTimedOut, .none:
      line = String(
        localized: "\(judge)'s word check isn't ready",
        comment: "Your Words, Learn from: the self-learning dictionary row: which word check is in use, or why none is.")
    }
  }
}

/// Learn from... tab of the Dictionary page. Two ways the app can pick up words
/// without being told each one: learn from the user's own edits (#996, live
/// since chunk 5g; the "Coming soon" pill of Phase 7 #629 is gone) and Contacts
/// import (Phase 6 #636, live). Bible §10.2.
///
/// **Two features, two cards, and that is the fix.** The first build put both
/// inside one `BrandedSection` as `BrandedRow`s separated by a hairline, so a
/// title, a paragraph, a status line, a button, a second toggle and a second
/// paragraph ran together as one column of text with nothing saying where one
/// feature ended (founder, 2026-08-29: "just blends together with no clear UX
/// design"). The approved mockup draws each as its own card
/// (`.learn-row`). "Keep in sync on launch" is not
/// a peer of those two features — it is a setting BELONGING to Contacts, so it
/// sits inside that card under a divider, which is what the mockup's
/// `.sync-row` is.
struct LearningSection: View {
  @Environment(ContactsImportCoordinator.self) private var contactsImport
  @Environment(SettingsManager.self) private var settings
  /// #996 §3.9 / phase D: the row's enabled state, its reason line and its one
  /// action come from `LearnFromEditsAvailability`, the composition root's live
  /// picture; this view never reads the selection, the OS or the delivery
  /// layer itself.
  @Environment(LearnFromEditsAvailability.self) private var availability
  @Environment(LearnedWordCheckerEligibility.self) private var checkerEligibility
  /// #3975: owns the learning memory the Forget row reads and clears.
  @Environment(CustomWordsCoordinator.self) private var customWords
  private struct CheckerStatusKey: Equatable {
    let dictation: LocalPolishModelID
    let file: LocalPolishModelID
    let revision: Int
    let enabled: Bool
  }

  private struct CheckerStatuses {
    let key: CheckerStatusKey
    let dictation: LearnedCheckerSettingsStatus
    let file: LearnedCheckerSettingsStatus
  }

  @State private var checkerStatuses: CheckerStatuses?
  @State private var showingBlocked = false

  private var checkerStatusKey: CheckerStatusKey {
    CheckerStatusKey(
      dictation: settings.polishModelID(for: settings.llmProvider),
      file: settings.polishModelID(for: settings.effectiveFileImportLLMProvider),
      revision: checkerEligibility.statusRevision,
      enabled: settings.wordCorrectionEnabled && settings.fixLearnedWords)
  }

  var body: some View {
    @Bindable var settings = settings

    // The page says what it is for. `BrandedPanel` puts that header INSIDE the
    // card, so the tab opens with a sentence rather than with a control.
    BrandedPanel(
      icon: "sparkle.magnifyingglass",
      header: SettingsItemCopy.Dictionary.learnFromPanel,
      description: SettingsItemCopy.Dictionary.learnFromShort
    ) {
      VStack(alignment: .leading, spacing: 12) {
        // #5006 (founder 2026-11-26): one heading over both switches, one line
        // each, the learning memory as a third row in the same card.
        Text(LearnFromEditsSettingsPresentation.sectionTitle)
          .font(.stRowTitle)
          .foregroundStyle(.stTextPrimary)
          .accessibilityAddTraits(.isHeader)
        learnCard(verticalPadding: DesignSpacing.xs) {
          VStack(alignment: .leading, spacing: 0) {
            editsLine(settings: $settings)
            Divider().overlay(Color.stDivider)
            fixesLine(settings: $settings)
            if customWords.learnMemoryStored {
              Divider().overlay(Color.stDivider)
              learnMemoryLine
            }
          }
        }
        // On the stack, not the memory row: removing the last blocked fix hides
        // the row while the window and its Undo stay open (#5006 §16.1).
        .sheet(isPresented: $showingBlocked) {
          BlockedWordsSheet().environment(customWords)
        }
        contactsCard(settings: $settings)
      }
    }
    .settingsMapRegistration(.learnFrom)
    .onAppear { customWords.refreshLearnMemorySummary() }
    .sheet(isPresented: confirmSheetBinding) {
      if let preview = contactsImport.pendingPreview {
        ContactsImportConfirm(
          preview: preview,
          onConfirm: { Task { await contactsImport.confirmImport() } },
          onCancel: { contactsImport.cancelImport() })
      }
    }
    .task(id: checkerStatusKey) {
      let key = checkerStatusKey
      guard key.enabled else { return }
      let dictation = await checkerEligibility.settingsStatus(model: key.dictation)
      let file = key.file == key.dictation
        ? dictation : await checkerEligibility.settingsStatus(model: key.file)
      guard !Task.isCancelled, key == checkerStatusKey else { return }
      checkerStatuses = CheckerStatuses(key: key, dictation: dictation, file: file)
    }
  }

  /// Learn new words (#996 §3.9; "Learn from my edits" until 2026-09-21): one
  /// line with its status word (#5006). The toggle is the stored choice; a
  /// disabled row keeps showing it, and the choice applies again on a Mac that
  /// can act on it. A state with an action keeps one visible line and its button;
  /// any other reason, and the article link, live in the "?".
  private func editsLine(settings: Bindable<SettingsManager>) -> some View {
    let learnFromEdits = availability.presentation
    let isOn = settings.wrappedValue.learnFromEdits
    let word = isOn ? learnFromEdits.readiness : .off
    // One decision for where the reason shows: the visible action line, or else the "?".
    let showsActionLine = isOn && learnFromEdits.secondaryLine != nil && learnFromEdits.action != nil
    return VStack(alignment: .leading, spacing: DesignSpacing.md) {
      LearnLine(title: LearnFromEditsSettingsPresentation.rowTitle, status: word.text) {
        SettingsInfoButton(rowTitle: LearnFromEditsSettingsPresentation.rowTitle, tooltip: nil) {
          VStack(alignment: .leading, spacing: DesignSpacing.lg) {
            SettingsHelpText(text: LearnFromEditsSettingsPresentation.learningSwitchHelp)
            if !showsActionLine, let reason = learnFromEdits.secondaryLine {
              SettingsHelpText(text: reason)
            }
            // Which apps it works in, how the on-device judge runs and what a
            // remembered word reaches are the article's job, not the card's.
            SettingsHelpArticleLink(
              url: URL(string: LearnFromEditsSettingsPresentation.learnMoreURL),
              label: LearnFromEditsSettingsPresentation.learnMoreLabelResource,
              accessibilityLabel: LearnFromEditsSettingsPresentation.learnMoreAccessibilityLabel)
          }
        }
        // The "Learn more" search result lands on this "?", which holds the
        // article link (#5006, founder 2026-11-26: keep the search result).
        .settingsArrivalFocusControl()
        .settingsMapRegistration(.selfLearningDictionaryLearnMore)
      } trailing: {
        Toggle("", isOn: settings.learnFromEdits)
          .toggleStyle(BrandedToggleStyle())
          .labelsHidden()
          // BrandedToggleStyle wraps label-Spacer-track in a content shape so
          // a labelled row is clickable end to end. With the label hidden its
          // Spacer claims the whole remaining row, which would make the empty
          // middle of this card toggle the switch. `fixedSize` collapses it.
          .fixedSize()
          .accessibilityLabel(LearnFromEditsSettingsPresentation.rowTitle)
      }
      .settingsMapRegistration(.selfLearningDictionary)
      if showsActionLine, let reason = learnFromEdits.secondaryLine, let action = learnFromEdits.action {
        HStack(alignment: .center, spacing: DesignSpacing.md) {
          Text(reason)
            .font(.stHelper)
            .foregroundStyle(.stTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: DesignSpacing.md)
          Button {
            availability.perform(action)
          } label: {
            EnviousButtonLabel(verbatim: Self.actionTitle(action))
          }
          .settingsButton(isEnabled: true)
          .settingsArrivalWithoutInheritedPlace()
        }
      }
    }
    .padding(.vertical, DesignSpacing.lg)
  }

  /// Fix words it learned: one line with its status word (#5006). Enable
  /// Dictionary off comes first (switch disabled, one line, no button; the
  /// wider Dictionary rethink is #5007). The word follows the dictation status;
  /// a different file-transcription model adds its sentence to the "?" and its
  /// own retry line when it can retry.
  private func fixesLine(settings: Bindable<SettingsManager>) -> some View {
    let key = checkerStatusKey
    let dictionaryOn = settings.wrappedValue.wordCorrectionEnabled
    let fixOn = settings.wrappedValue.fixLearnedWords
    let statuses = checkerStatuses.flatMap { $0.key == key ? $0 : nil }
    let showsStatus = dictionaryOn && fixOn
    // A different file model always gets its sentence in the "?"; its own Try again
    // only when its status differs too, so one shared word-check failure offers one
    // Try again, not two (as before #5006).
    let fileModelDiffers = key.file != key.dictation
    let fileRetrySeparate = fileModelDiffers && statuses.map { $0.file != $0.dictation } == true
    let word: LearnFromEditsSettingsPresentation.StatusWord? =
      !dictionaryOn ? .paused : !fixOn ? .off : statuses?.dictation.readiness
    return VStack(alignment: .leading, spacing: DesignSpacing.md) {
      LearnLine(title: String(localized: LearnFromEditsSettingsPresentation.fixesTitle), status: word?.text) {
        SettingsInfoButton(rowTitle: String(localized: LearnFromEditsSettingsPresentation.fixesTitle), tooltip: nil) {
          VStack(alignment: .leading, spacing: DesignSpacing.lg) {
            SettingsHelpText(text: String(localized: LearnFromEditsSettingsPresentation.fixesHelp))
            if showsStatus, let statuses {
              SettingsHelpText(text: statuses.dictation.line)
              if fileModelDiffers {
                SettingsHelpText(text: Self.fileLine(statuses.file))
              }
            }
          }
        }
      } trailing: {
        Toggle("", isOn: settings.fixLearnedWords)
          .toggleStyle(BrandedToggleStyle())
          .labelsHidden()
          .fixedSize()
          .disabled(!dictionaryOn)
          .accessibilityLabel(String(localized: LearnFromEditsSettingsPresentation.fixesTitle))
      }
      .settingsMapRegistration(.fixLearnedWords)

      if !dictionaryOn {
        Text(LearnFromEditsSettingsPresentation.dictionaryOffLine)
          .font(.stHelper).foregroundStyle(.stTextSecondary)
      } else if showsStatus, let statuses {
        if statuses.dictation.canRetry {
          checkerStatusLine(statuses.dictation.line, status: statuses.dictation, model: key.dictation, key: key)
        }
        if fileRetrySeparate, statuses.file.canRetry {
          checkerStatusLine(Self.fileLine(statuses.file), status: statuses.file, model: key.file, key: key)
        }
      }
    }
    .padding(.vertical, DesignSpacing.lg)
  }

  private static func fileLine(_ status: LearnedCheckerSettingsStatus) -> String {
    String(
      localized: "Transcribe a File: \(status.line)",
      comment: "Dictionary: word checker status for file transcription.")
  }

  private func checkerStatusLine(
    _ line: String, status: LearnedCheckerSettingsStatus, model: LocalPolishModelID,
    key: CheckerStatusKey
  ) -> some View {
    HStack(spacing: DesignSpacing.md) {
      Text(line).font(.stHelper).foregroundStyle(.stTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
      if status.canRetry {
        Spacer(minLength: DesignSpacing.md)
        Button {
          Task {
            guard key == checkerStatusKey, key.enabled else { return }
            await checkerEligibility.retryDownload(for: model)
          }
        } label: {
          EnviousButtonLabel(LearnedCheckerSettingsStatus.retryTitle)
        }
        .settingsButton(isEnabled: true)
        .settingsArrivalWithoutInheritedPlace()
      }
    }
  }

  /// #3975 §3.4, #5006: what the app remembers about the user's fixes, outside
  /// the "?" (founder 2026-11-26). The count opens the Blocked words window,
  /// where one fix or everything can be forgotten.
  private var learnMemoryLine: some View {
    let count = customWords.learnMemoryBlockedCount
    return LearnLine(
      title: String(localized: LearnFromEditsSettingsPresentation.memoryTitle), status: nil,
      trailingDropsBelow: true
    ) {
      SettingsInfoButton(rowTitle: String(localized: LearnFromEditsSettingsPresentation.memoryTitle), tooltip: nil) {
        SettingsHelpText(text: String(localized: LearnFromEditsSettingsPresentation.memoryHelp))
      }
    } trailing: {
      Button {
        showingBlocked = true
      } label: {
        EnviousButtonLabel(
          verbatim: LearnFromEditsSettingsPresentation.blockedCount(count), trailingSystemImage: "chevron.right")
      }
      .settingsButton(isEnabled: true)
      .accessibilityLabel(LearnFromEditsSettingsPresentation.blockedCountAccessibility(count))
      .settingsArrivalFocusControl()
      .settingsMapRegistration(.selfLearningDictionaryForgetMemory)
    }
    .padding(.vertical, DesignSpacing.lg)
  }

  /// The row's one verb per state (phase D); copy lives with the state table.
  static func actionTitle(_ action: LearnFromEditsSettingsPresentation.Action) -> String {
    switch action {
    case .download:
      return String(
        localized: "Download",
        comment:
          "Your Words, Learn from: the self-learning dictionary row: button that downloads the correction model."
      )
    case .cancel:
      return String(
        localized: "Cancel",
        comment:
          "Your Words, Learn from: the self-learning dictionary row: button that stops the download."
      )
    case .retryLoad:
      return String(
        localized: "Try again",
        comment:
          "Your Words, Learn from: the self-learning dictionary row: button that retries loading the model."
      )
    case .removeAndDownload:
      return String(
        localized: "Remove and download again",
        comment:
          "Your Words, Learn from: the self-learning dictionary row: button that replaces a wrong model."
      )
    }
  }

  /// Contacts import, plus the one setting that belongs to it.
  private func contactsCard(settings: Bindable<SettingsManager>) -> some View {
    learnCard {
      VStack(alignment: .leading, spacing: 10) {
        // ViewThatFits: at the app's 750pt minimum window this card is narrow
        // enough that the imported-count pill and button cannot share a line
        // with the title (cloud review, PR #2499).
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .center, spacing: 10) {
            contactsRowLabel
            Spacer(minLength: 8)
            importControl
          }
          VStack(alignment: .leading, spacing: 10) {
            contactsRowLabel
            importControl
          }
        }

        contactsStatus

        Divider().overlay(Color.stDivider)

        HStack(alignment: .center, spacing: 10) {
          VStack(alignment: .leading, spacing: 2) {
            Text(SettingsItemCopy.Dictionary.syncOnLaunch).settingsRowLabel()
            Text(SettingsItemCopy.Dictionary.syncOnLaunchShort)
              .settingsReadingCopy()
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 8)
          Toggle("", isOn: settings.contactsSyncOnLaunchEnabled)
            .toggleStyle(BrandedToggleStyle())
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(Text(SettingsItemCopy.Dictionary.syncOnLaunch))
        }
        .settingsMapRegistration(.contactsSyncOnLaunch)
      }
    }
  }

  /// The import's own feedback, in one place rather than four sibling `if`s in
  /// the middle of the card's layout.
  @ViewBuilder private var contactsStatus: some View {
    if case .imported(let count) = contactsImport.phase {
      Label(Self.addedFeedback(count), systemImage: "checkmark.circle.fill")
        .font(.stHelper)
        .foregroundStyle(.stSuccess)
    }
    if let progress = contactsImport.enrichmentProgress {
      Label(
        "Finding spoken variants… \(progress.done) of \(progress.total)",
        systemImage: "sparkles"
      )
      .font(.stHelper)
      .foregroundStyle(.stTextSecondary)
    }
    if case .failed(let message) = contactsImport.phase {
      Text(message)
        .font(.stHelper)
        .foregroundStyle(.stError)
        .fixedSize(horizontal: false, vertical: true)
    }
    if contactsImport.phase == .denied {
      Text("Contacts access is off. Turn it on in System Settings, then try again.")
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// The card each feature sits in, in the shared control fill `stInputBg`, the
  /// same fill the search field on the Your Words tab uses (founder, 2026-10-03).
  private func learnCard<Content: View>(
    verticalPadding: CGFloat = 14, @ViewBuilder content: () -> Content
  ) -> some View {
    content()
      .padding(.horizontal, 14)
      .padding(.vertical, verticalPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Color.stInputBg)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(Color.stDivider, lineWidth: 1)
          // A decoration is never in the hit path — these cards contain
          // toggles and a button.
          .allowsHitTesting(false)
      )
  }

  private var contactsRowLabel: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(SettingsItemCopy.Dictionary.importContacts)
        .settingsRowLabel()
      Text(SettingsItemCopy.Dictionary.importContactsShort)
      .settingsReadingCopy()
      .fixedSize(horizontal: false, vertical: true)
    }
    .settingsMapRegistration(.importContacts)
  }

  /// Right-side control: spinner while working, Open Settings if denied, the
  /// "N imported ✕" pill plus an Import/Re-scan button otherwise.
  @ViewBuilder private var importControl: some View {
    HStack(spacing: 8) {
      if contactsImport.importedCount > 0 {
        importedPill
      }
      actionButton
    }
  }

  @ViewBuilder private var actionButton: some View {
    switch contactsImport.phase {
    case .requesting, .importing:
      ProgressView()
        .controlSize(.small)
    case .denied:
      Button {
        openContactsSettings()
      } label: {
        EnviousButtonLabel("Open Settings")
      }
      .settingsButton(.filled, isEnabled: true)
      .settingsArrivalWithoutInheritedPlace()
      .settingsArrivalFocusControl(place: .importContacts)
    default:
      Button {
        Task { await contactsImport.prepareImport() }
      } label: {
        EnviousButtonLabel(contactsImport.importedCount > 0 ? "Re-scan" : "Import")
      }
      .settingsButton(isEnabled: true)
      .settingsArrivalWithoutInheritedPlace()
      .settingsArrivalFocusControl(place: .importContacts)
    }
  }

  private var importedPill: some View {
    HStack(spacing: 4) {
      Text("\(contactsImport.importedCount) imported")
        .font(.stHelper)
      Button {
        Task { await contactsImport.bulkRemoveImported() }
      } label: {
        Image(systemName: "xmark.circle.fill")
          // Bulk-removes every imported name, from a glyph inside a status
          // pill -- the least button-shaped thing on the page doing the most.
          .settingsHoverQuiet(tint: .stError)
      }
      .buttonStyle(.plain)
      .help("Remove all imported names")
      .accessibilityLabel("Remove all imported names")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Capsule().fill(Color.secondary.opacity(0.15)))
  }

  private var confirmSheetBinding: Binding<Bool> {
    Binding(
      get: { contactsImport.pendingPreview != nil },
      set: { presented in
        if !presented { contactsImport.cancelImport() }
      })
  }

  static func addedFeedback(_ count: Int) -> String {
    count == 1
      ? String(
        localized: "Added 1 name",
        comment: "Your Words, import from Contacts: result after adding names: one name added.")
      : String(
        localized: "Added \(String(count)) names",
        comment:
          "Your Words, import from Contacts: result after adding names: %@ is the number of names, never 1."
      )
  }

  private func openContactsSettings() {
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")
    {
      NSWorkspace.shared.open(url)
    }
  }
}

/// One Learn from line (#5006): title, its "?", a short status word and a trailing
/// control on one line when they fit. When they do not (German or French at the
/// 750 pt window, where this column is about 190 pt wide), the title takes the full
/// width and wraps at word boundaries; its "?", the status word and, with
/// `trailingDropsBelow`, the trailing control follow on the line below; a switch
/// stays on the right.
private struct LearnLine<Help: View, Trailing: View>: View {
  let title: String
  let status: String?
  var trailingDropsBelow = false
  @ViewBuilder let help: () -> Help
  @ViewBuilder let trailing: () -> Trailing

  private var statusText: some View {
    Text(status ?? "").font(.stHelper).foregroundStyle(.stTextSecondary).fixedSize()
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: DesignSpacing.md) {
        Text(title).settingsRowLabel().fixedSize()
        help()
        if status != nil { statusText }
        Spacer(minLength: DesignSpacing.md)
        trailing()
      }
      HStack(alignment: .center, spacing: DesignSpacing.md) {
        VStack(alignment: .leading, spacing: DesignSpacing.xs) {
          // The title takes the whole width so a long single word ("Korrekturen",
          // "aprendidas") is never split; the "?" and the status follow below it.
          Text(title).settingsRowLabel().fixedSize(horizontal: false, vertical: true)
          HStack(alignment: .center, spacing: DesignSpacing.md) {
            help()
            if status != nil { statusText }
            if trailingDropsBelow { trailing() }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if !trailingDropsBelow { trailing() }
      }
    }
  }
}
