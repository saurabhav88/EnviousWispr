import EnviousWisprCore
import EnviousWisprLivePreview
import EnviousWisprModelDelivery
import EnviousWisprServices
import SwiftUI

/// The Live Preview settings page (#2080, redesigned #2154).
///
/// Moved out of Transcription, where it was a sub-section of a page about
/// something else and nobody found it. Measured, and the reason the page
/// exists: exactly 7 of 54 languages are installed on a stock Mac, and the set
/// is not regional, so a French, Italian, Korean, Portuguese, Dutch, Russian or
/// Polish user previously got an empty pill and no way to learn why.
///
/// **#2154 redesign, from the founder's 2026-08-18 mockup.** The page was all
/// configuration and no status: everything on it described settings, nothing
/// described whether the feature was working. Somebody arrives here BECAUSE
/// their preview showed nothing, which makes "is it ready, and if not what do I
/// press" the first question, not the last. Hence the hero card's right column.
struct LivePreviewSettingsView: View {
  /// Narrow environment home, matching every sibling settings page.
  @Environment(SettingsManager.self) private var settings

  /// **Owned by the WINDOW, not by this page.** Selecting another sidebar
  /// section destroys this view, and with it any `@State` it owned — so a
  /// download in flight lost its bookkeeping and a returning user could start a
  /// second one. `swiftui-mv-first` puts cross-view state in the retained
  /// parent, and `swiftui-task-never-owns-workflows` says a multi-second
  /// workflow like a download must outlive view churn. This page only renders it.
  let packs: LivePreviewPacksModel

  /// #2123: the preview model's download lifecycle. Optional for the same
  /// reason the speech-engine page's is — a preview or a test may render this
  /// page with no delivery home in the environment.
  @Environment(ModelDeliveryHome.self) private var modelDelivery: ModelDeliveryHome?

  /// View-local: a search box is about what this page is SHOWING, not about the
  /// catalogue, so the model has no reason to know it exists.
  @State private var searchText: String = ""

  /// #2154: the dictation-language picker, opened by the Change button.
  @State private var showLanguageSheet: Bool = false


  // MARK: - Derived state

  /// Whether APPLE's engine can run here. Still the gate for the pack list and
  /// the active-language summary, which are about Apple's packs specifically.
  private var isAppleSupported: Bool { ApplePreviewEngineResolver.isSupportedOnThisSystem }

  /// Whether the universal engine was composable in this build.
  private var universalExists: Bool {
    guard let modelDelivery else { return false }
    // Registration is not enough: a route also needs the bundled tokenizer, and
    // a build missing it would otherwise enable the toggle and offer a Download
    // for an engine that could never run.
    return WhisperPreviewDeliveryWiring.isComposable(modelDelivery: modelDelivery)
  }

  /// Whether APPLE is the engine actually in use. Apple-specific claims — the
  /// active-language summary and the "In use" badge — are only true then.
  private var isUsingApple: Bool { settings.livePreviewEngine == .apple }

  /// **Whether the FEATURE can run at all, which is not the same question.**
  ///
  /// The toggle used to be disabled on `isAppleSupported`, so below macOS 26 a
  /// user could not switch the preview on — correct while Apple's was the only
  /// engine, and the exact dead end #2077 exists to remove now that a second
  /// engine has no OS floor. Gating the feature on one engine's rule is what
  /// `live-preview.md` warns against.
  private var anyEngineAvailable: Bool { isAppleSupported || universalExists }

  /// The toggle's own value, NOT whether a preview could run. Anything the page
  /// says about a live preview is false while this is off, and it is off by default.
  private var isPreviewOn: Bool { settings.livePreviewEnabled }

  private var universalState: DeliveryState {
    modelDelivery?.whisperPreviewState ?? .notReady
  }

  /// The status card's answer. One call, so the chip and its detail line can
  /// never describe different states.
  private var status: LivePreviewStatusMapping.Summary {
    LivePreviewStatusMapping.summary(
      isEnabled: isPreviewOn,
      engine: settings.livePreviewEngine,
      appleSupported: isAppleSupported,
      universalExists: universalExists,
      universalState: universalState,
      // The universal preview refuses to run while the heart decodes
      // continuously. Read live rather than snapshotted, for the same reason the
      // resolver reads it live: the answer must be current.
      heartIsStreaming: heartIsStreaming,
      // `currentActive`, like every other consumer. It is nil both when nothing
      // has resolved yet and when what resolved is stale; the flag below tells
      // the mapping which, and the mapping checks the flag first. No consumer
      // reads `packs.active` directly, so there is no exception for the next
      // reader to copy.
      active: currentActive,
      // The model refuses to reload while an install runs, so `active` is stale
      // for that whole window and the card must not assert from it.
      anInstallIsInFlight: packs.installingTag != nil,
      // `load()` cannot run during an install, so switching language mid-download
      // leaves `active` describing the previous one. Compare what it was resolved
      // FOR against what is selected NOW rather than assuming they agree.
      activeDescribesAnotherLanguage: activeDescribesAnotherLanguage)
  }

  /// Installed Apple packs, read LIVE from the model rather than snapshotted.
  ///
  /// The reactivity is the founder's actual requirement, not an implementation
  /// detail: "if they download it from the bottom selection table, it should then
  /// pop up into the selector." `install(tag:)` republishes the loaded list on its
  /// way out, so a computed property re-evaluates and the sheet's next open — or
  /// its current render — sees the new language. A stored copy taken when the page
  /// appeared would show a language the user just downloaded as still missing.
  ///
  /// Empty while loading or on a read failure, which is correct: `.failed` means we
  /// could not ask macOS, and offering a language we cannot confirm is installed is
  /// the claim this page is not allowed to make.
  private var installedPackTags: [String] {
    guard case .loaded(let packs) = self.packs.state else { return [] }
    return packs.filter(\.isInstalled).map(\.tag)
  }

  /// **The ONE place the streaming refusal is read, for the same reason
  /// `currentActive` is the one place staleness is decided.**
  ///
  /// Two consumers now: the hero summary, and the universal language row, which
  /// must stop promising output while the resolver is refusing. Read live rather
  /// than snapshotted because the resolver reads it live — a snapshot taken at
  /// view build time can disagree with what pressing record actually does.
  private var heartIsStreaming: Bool {
    WhisperPreviewDeliveryWiring.heartIsStreaming(settings: settings)
  }

  /// Readiness for the universal row, from the same owner the hero reads. Never
  /// re-derive this from a blocker here: r8 and r9 were both a surface deciding
  /// readiness for itself and reaching a different answer from the card above it.
  private var universalWillProduceOutput: Bool {
    LivePreviewStatusMapping.universalWillProduceOutput(
      exists: universalExists, state: universalState, heartIsStreaming: heartIsStreaming)
  }

  /// **The ONE place staleness is decided, and every consumer of the resolved
  /// language reads THIS rather than `packs.active`.**
  ///
  /// #2154, cloud review r3. An earlier fix guarded only the status card, so the
  /// language panel still unwrapped `packs.active` directly and the "In use"
  /// badge still derived from it — meaning a value known to describe the
  /// PREVIOUS language kept driving two other surfaces. Three consumers with one
  /// guard between them is not a fix, it is the first of three review rounds.
  ///
  /// nil means "we do not currently know", which every consumer already handles:
  /// the card refuses, the panel hides, the badge marks nothing in use.
  private var currentActive: LivePreviewPacksModel.ActiveLanguage? {
    guard let mode = packs.resolvedMode, mode == settings.languageMode else { return nil }
    return packs.active
  }

  /// True when the resolved value exists but describes a language the user has
  /// since moved away from — the state the card reports rather than hides.
  private var activeDescribesAnotherLanguage: Bool {
    guard let mode = packs.resolvedMode else { return false }
    return mode != settings.languageMode
  }

  private var showsApplePacks: Bool {
    LivePreviewEnginePresentation.showsApplePacks(
      isAppleSupported: isAppleSupported, isUsingApple: isUsingApple)
  }

  // MARK: - Body

  var body: some View {
    @Bindable var settings = settings
    return SettingsContentView {
      statusBar
      engineSection
      languageSection
      packsSection
    }
    // **Keyed on the language, not merely on appearance.**
    //
    // A plain `.task` runs once per appearance, and the dictation language can
    // change while this page stays open: the passive suggestion chip locks a
    // language straight into settings (`WisprBootstrapper`), the language sheet
    // does, and since #2154 so does this page's own Change button. The summary
    // would otherwise describe the new mode while the resolved language and the
    // "In use" badge still named the old one — the page contradicting itself in
    // two places at once.
    //
    // Keyed on the VALUE rather than wired to those call sites, so a writer
    // added later is covered without knowing this page exists.
    // `swiftui-view-patterns.md` RULE: swiftui-task-id-cancellation.
    .task(id: settings.languageMode) {
      guard isAppleSupported else { return }
      // Re-read on EVERY appearance. The model outlives this page, so without
      // this a returning user would see the snapshot from whenever they last
      // opened it — past a download that finished meanwhile, past a macOS purge
      // of a staged asset. The catalogue exists precisely because this state is
      // not ours to cache.
      packs.useMode { settings.languageMode }
      await packs.load()
    }
    .sheet(isPresented: $showLanguageSheet) {
      // The same sheet the Transcription page opens, restricted to the same
      // codes through the shared owner. Reproducing that rule here would be a
      // silent failure: an unclaimed code maps to no vendor language and the
      // decoder falls back to auto-detect while the user believes they are
      // locked (#1678).
      LanguageLockSheet(
        lockableCodes: LanguageLockOptions.previewLockableCodes(
          backend: settings.selectedBackend,
          previewEngine: settings.livePreviewEngine,
          installedPackTags: installedPackTags))
    }
  }

  // MARK: - Hero card

  // MARK: - Status bar

  /// What is happening, which language, and the switch — on one line (#2436).
  ///
  /// Replaces the hero card, its status column and the toggle row. Those three said
  /// the same sentence three times before the page said anything: the page header
  /// already carries "See your words on screen while you are still speaking"
  /// (`SettingsSection.swift:92`), the hero repeated it, and the toggle repeated the
  /// hero. Founder, 2026-08-25: "the current live preview page is just information
  /// overload."
  ///
  /// **Carried verbatim from `heroCard`, whose two columns this row replaces:**
  ///
  /// > Two columns because they answer different questions and a returning user
  /// > only needs the right one. The left half is read once, on the first visit;
  /// > the right half is the reason anybody comes back.
  ///
  /// That reasoning is why the left half is gone rather than shrunk: what it said
  /// once now lives one line above in the page header, and what the right half said
  /// is the only thing left here.
  ///
  /// Composition is `LivePreviewStatusBarPresentation`, not this body, so the rules
  /// about what may be named in which state are testable without rendering.
  private var statusBar: some View {
    @Bindable var settings = settings
    let bar = LivePreviewStatusBarPresentation.bar(
      summary: status, engine: settings.livePreviewEngine,
      appleActive: currentActive, languageMode: settings.languageMode)

    return BrandedSection {
      BrandedRow(showDivider: false) {
        HStack(alignment: .center, spacing: 12) {
          VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
              ProviderStatusChip(status: status.chip)
            }
            Text(bar.detail).settingsHelperCopy()
          }
          Spacer(minLength: 12)

          if let language = bar.language {
            Button {
              showLanguageSheet = true
            } label: {
              VStack(alignment: .trailing, spacing: 1) {
                Text(language.name).settingsRowLabel()
                Text(language.provenance).settingsHelperCopy()
              }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityLabel("Change dictation language: \(language.name)")
          }

          // **The reason lives in the hero card now, and only there.**
          // This row used to repeat `needsNewerMacOS` whenever neither engine
          // could run — but that condition is an OR of two independent causes,
          // so on macOS 14 with a defective build it told the user to upgrade
          // macOS when upgrading would not have helped. The status card above
          // states the SELECTED engine's own reason, which is specific by
          // construction, and two places saying why is how they come to
          // disagree.
          //
          // #2436: "the hero card" is now this same row's left half, so the rule
          // is unchanged and its one-owner property is stronger — there is no
          // longer a second container that could drift.
          Toggle("", isOn: $settings.livePreviewEnabled)
            .labelsHidden()
            .toggleStyle(BrandedToggleStyle())
            .disabled(!anyEngineAvailable)
            // The visible label is gone; this is the only thing naming the switch
            // for VoiceOver, which is why `toggleLabel` survives the copy cull.
            .accessibilityLabel(LivePreviewSettingsCopy.toggleLabel)
        }
      }

      // **The remedy button lands in C4, with the sheet it opens.**
      //
      // `bar.action` is computed and tested from C1; nothing renders it yet, and
      // that is deliberate rather than an omission. Until C4 the inline pack table
      // is still on this page, so `statusNeedsLanguageDetail`'s "Use Browse
      // downloads below" is satisfied by what is genuinely below. Shipping a button
      // here would mean shipping one that opens nothing for the length of a chunk.

    } footer: {
      // Always visible: never gated on engine, toggle, Apple support or pack state.
      Text(LivePreviewSettingsCopy.previewPrivacyFooter).settingsHelperCopy()
    }
  }

  // MARK: - Engine picker

  /// Which engine draws the preview.
  ///
  /// Above the pack list, because it decides whether that list is even relevant:
  /// the packs belong to Apple's engine only.
  ///
  /// Laid out exactly like the Transcription page's picker — bare eyebrow, then
  /// a two-column grid of the shared `EngineCard` — because the two pages sit
  /// next to each other under Record and were solving the same problem in two
  /// visibly different shapes (#2136).
  ///
  /// Both cards ALWAYS render, including one that cannot run here. Hiding the
  /// unavailable option reads as a bug — the user knows the app has two engines
  /// — and the card is where the reason lives.
  private var engineSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text(LivePreviewEngineCopy.sectionHeader.uppercased())
          .font(.stSectionHeader)
          .tracking(0.6)
          .foregroundStyle(.stAccent)
          .padding(.leading, 4)
        Spacer(minLength: 12)
        // The first link from a settings page to the Help Centre. The two
        // engines differ in OS floor, language coverage and download size, and
        // a card cannot carry that comparison without becoming the article.
        Link(destination: URL(string: LivePreviewEngineCopy.learnMoreURL)!) {
          HStack(spacing: 4) {
            Text(LivePreviewEngineCopy.learnMoreLabel)
            Image(systemName: "arrow.up.right")
          }
          .font(.stHelper)
        }
        .foregroundStyle(.stAccent)
      }

      LazyVGrid(
        columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
        spacing: 12
      ) {
        engineCard(
          LivePreviewEnginePresentation.appleCard(
            isSelected: settings.livePreviewEngine == .apple,
            isSupported: isAppleSupported),
          icon: "apple.logo",
          choice: .apple)
        engineCard(
          LivePreviewEnginePresentation.universalCard(
            isSelected: settings.livePreviewEngine == .universal,
            routeExists: universalExists,
            state: universalState),
          icon: "globe",
          choice: .universal)
      }
    }
  }

  /// One engine card.
  ///
  /// **Selecting is separate from acting, and the structure enforces it.**
  /// Tapping the card chooses the engine; the footer button downloads, cancels,
  /// resumes, retries or removes. Choosing an engine must never start a 217 MB
  /// download by itself — the founder's Gate 1 decision on #2123. The footer is
  /// a sibling of `EngineCard`'s selection button rather than a child, because
  /// that button combines its accessibility children and anything actionable
  /// inside it would be merged into the same element.
  @ViewBuilder
  private func engineCard(
    _ card: LivePreviewEnginePresentation.Card,
    icon: String,
    choice: LivePreviewEngineChoice
  ) -> some View {
    EngineCard(
      icon: icon,
      title: card.title,
      tagline: card.description,
      unavailability: card.unavailability,
      isSelected: card.isSelected,
      onSelect: { settings.livePreviewEngine = choice },
      footer: {
        if card.action != nil || card.progress != nil {
          VStack(alignment: .leading, spacing: 8) {
            if let progress = card.progress {
              ProgressView(value: progress)
            }
            if let action = card.action {
              // Removal is bordered, everything else prominent: the destructive
              // action should not be the most inviting thing on the card.
              if action == .remove {
                Button(Self.label(for: action)) { perform(action) }
                  .buttonStyle(.bordered)
              } else {
                Button(Self.label(for: action)) { perform(action) }
                  .buttonStyle(.borderedProminent)
              }
            }
          }
          .padding(.horizontal, 16)
          .padding(.bottom, 16)
        }
      })
  }

  private static func label(for action: LivePreviewEnginePresentation.Action) -> String {
    switch action {
    case .download: return "Download"
    case .cancelDownload: return "Cancel"
    case .resumeDownload: return "Resume"
    case .retryDownload: return "Try Again"
    case .remove: return "Remove"
    }
  }

  private func perform(_ action: LivePreviewEnginePresentation.Action) {
    guard let modelDelivery else { return }
    switch action {
    // Download, resume and retry are one operation to the delivery layer; only
    // the word on the button differs, and the card already chose it.
    case .download, .resumeDownload, .retryDownload:
      modelDelivery.startPreviewDownload()
    case .cancelDownload:
      modelDelivery.cancelPreviewDownload()
    case .remove:
      modelDelivery.removePreviewModel()
    }
  }

  // MARK: - Preview language

  /// Which language the words will appear in, and where that came from.
  ///
  /// **Only while the preview is actually on, and only on Apple's engine.** The
  /// toggle defaults to OFF, so without the first gate the DEFAULT state of the
  /// page announced "Your words will appear in English" for something that
  /// cannot run. Without the second, it would state confidently which Apple
  /// pack is producing words while the universal engine is the one drawing them.
  @ViewBuilder
  private var languageSection: some View {
    // `currentActive`, never `packs.active` — a value resolved for a language the
    // user has left must not describe this panel either.
    // **The language control is NOT Apple-specific, and gating it on the pack
    // list stranded universal users.** `showsApplePacks` correctly hides Apple's
    // PACK TABLE on the other engine — those are Apple's languages. But the
    // universal engine honours a LOCK too (`WhisperPreviewEngineResolver` maps
    // `.locked(code)` straight through and only `.auto` becomes nil), so a user
    // locked to the wrong language had no way to see or change it from the page
    // that was telling them the preview was ready. Review r7.
    if isPreviewOn, !isUsingApple {
      universalLanguageSection
    }
    if showsApplePacks, isPreviewOn, let active = currentActive {
      // **TWO containers, not one — founder 2026-08-18, comparing the shipped
      // page against his mockup: "you combined it into 1 container instead of
      // keeping it 2 containers."** The language row is a CONTROL you act on; the
      // explainer is background you read once. Folding them into a single card
      // made the row look like a paragraph with a button in it, and buried the
      // thing the user came here to change.
      //
      // Always visible rather than behind a disclosure: the whole problem was not
      // knowing where the language comes from, and an explanation you must first
      // discover does not solve that.
      BrandedSection(header: LivePreviewSettingsCopy.activeHeader) {
        BrandedRow(showDivider: false) {
          activeSummary(active)
        }
      }
      InsetNotice(text: LivePreviewSettingsCopy.activeExplainer)
    }
  }

  /// The universal engine's language row.
  ///
  /// Deliberately simpler than Apple's: there is no pack to resolve, so there is
  /// no needs-download or unsupported state to describe. What it must NOT do is
  /// stay silent — this engine follows a lock, and the whole point of the row is
  /// that a user locked to the wrong language can see it and change it.
  @ViewBuilder
  private var universalLanguageSection: some View {
    BrandedSection(header: LivePreviewSettingsCopy.activeHeader) {
      BrandedRow(showDivider: false) {
        HStack(alignment: .top, spacing: 11) {
          SettingsRowIcon(systemName: "globe")
          VStack(alignment: .leading, spacing: 4) {
            switch settings.languageMode {
            case .locked(let code):
              let entry = LanguageCatalog.entry(for: code)
              // Describe the lock while paused; promise output only when the
              // resolver would actually deliver it. The help line is unchanged
              // because it states where the setting lives, which stays true.
              Text(
                LivePreviewEnginePresentation.universalRowLabel(
                  languageName: entry.englishName, engineWillProduceOutput: universalWillProduceOutput)
              )
              .settingsRowLabel()
              Text(LivePreviewSettingsCopy.universalLockedHelp).settingsHelperCopy()
            case .auto:
              Text(
                LivePreviewEnginePresentation.universalRowLabel(
                  languageName: nil, engineWillProduceOutput: universalWillProduceOutput)
              )
              .settingsRowLabel()
              Text(LivePreviewSettingsCopy.universalAutoHelp).settingsHelperCopy()
            }
          }
          Spacer(minLength: 8)
          VStack(alignment: .trailing, spacing: 3) {
            Button(LivePreviewSettingsCopy.changeLanguageButton) { showLanguageSheet = true }
              .controlSize(.small)
            Text(LivePreviewSettingsCopy.changeLanguageHelp)
              .settingsHelperCopy()
              .multilineTextAlignment(.trailing)
              .frame(maxWidth: 190, alignment: .trailing)
          }
        }
      }
    }
  }

  /// States the resolved language plainly, and where it came from, so "what is
  /// active" is readable without inferring it from the list.
  @ViewBuilder
  private func activeSummary(_ active: LivePreviewPacksModel.ActiveLanguage) -> some View {
    HStack(alignment: .top, spacing: 11) {
      SettingsRowIcon(systemName: "globe")
      VStack(alignment: .leading, spacing: 4) {
        switch active {
        case .ready(_, let name):
          Text(LivePreviewSettingsCopy.activeReady(name)).settingsRowLabel()
          Text(LivePreviewSettingsCopy.activeSource(settings.languageMode)).settingsHelperCopy()
        case .needsDownload(let name):
          Text(LivePreviewSettingsCopy.activeNeedsDownload(name)).settingsRowLabel()
          Text(LivePreviewSettingsCopy.activeNeedsDownloadHelp).settingsHelperCopy()
        case .unsupportedLanguage:
          Text(LivePreviewSettingsCopy.activeUnsupportedLanguage).settingsRowLabel()
          Text(LivePreviewSettingsCopy.activeUnsupportedLanguageHelp).settingsHelperCopy()
        case .unsupportedSystem:
          Text(LivePreviewSettingsCopy.needsNewerMacOS).settingsReadingCopy()
        }
      }
      Spacer(minLength: 8)
      // #2154. The panel used to state the language and point at another page,
      // which is a dead end for the one thing somebody reading it wants to
      // change. The help line under the button says the consequence out loud:
      // this sets the DICTATION language, not a preview-only one. Founder
      // decision, one language in one place — two settings that can disagree
      // hand the user a mismatch they cannot diagnose.
      VStack(alignment: .trailing, spacing: 3) {
        Button(LivePreviewSettingsCopy.changeLanguageButton) { showLanguageSheet = true }
          .controlSize(.small)
        Text(LivePreviewSettingsCopy.changeLanguageHelp)
          .settingsHelperCopy()
          .multilineTextAlignment(.trailing)
          .frame(maxWidth: 190, alignment: .trailing)
      }
    }
  }

  // MARK: - Language table

  /// Every language available to the preview, as ONE table.
  ///
  /// Hidden entirely below macOS 26 (no Apple packs exist to manage, and an
  /// empty list under a disabled toggle reads as something being broken) and on
  /// the universal engine, which carries its own languages and has no packs.
  ///
  /// The catalogue LOAD is deliberately NOT gated the same way: its `.task` is
  /// keyed on the dictation language, so adding the engine to the condition
  /// without adding it to the key would leave a user who switches back to Apple
  /// looking at a snapshot from before.
  ///
  /// **One table, replacing the two cards #2080 shipped.** Those cards existed
  /// to make the installed/downloadable boundary visible after ten rows, which a
  /// Source column does better: it aligns, it scans, and it does not split the
  /// list in half. Group ORDER is preserved — installed first — so
  /// `LivePreviewPackPresentation.groups(from:)` still owns the policy and its
  /// tests still mean something.
  ///
  /// No drag handles and no per-row overflow menu, both of which the mockup
  /// drew: nothing in the app orders languages, and Apple's packs are not ours
  /// to delete, so each would be a control with nothing behind it (founder,
  /// Gate 1).
  @ViewBuilder
  private var packsSection: some View {
    if showsApplePacks {
      BrandedSection(header: LivePreviewSettingsCopy.packsHeader) {
        BrandedRow(showDivider: !visibleRows.isEmpty) {
          VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
              Text(LivePreviewSettingsCopy.packsDescription)
                .settingsReadingCopy()
              Spacer(minLength: 8)
              // Only once there is a list to search: a search box over a spinner
              // or over the "could not read" message is a control that does nothing.
              if case .loaded = packs.state { searchField }
            }
            nonListState
          }
        }
        if !visibleRows.isEmpty {
          tableHeader
          ForEach(Array(visibleRows.enumerated()), id: \.element.id) { index, pack in
            BrandedRow(showDivider: index < visibleRows.count - 1) {
              packRow(pack)
            }
          }
        }
      }
    }
  }

  private var tableHeader: some View {
    BrandedRow(showDivider: true) {
      HStack(spacing: 10) {
        Text(LivePreviewSettingsCopy.tableColumnLanguage)
          .settingsHelperCopy()
          .frame(maxWidth: .infinity, alignment: .leading)
        Text(LivePreviewSettingsCopy.tableColumnSource)
          .settingsHelperCopy()
          .frame(width: Self.sourceColumnWidth, alignment: .leading)
        Text(LivePreviewSettingsCopy.tableColumnStatus)
          .settingsHelperCopy()
          .frame(width: Self.statusColumnWidth, alignment: .leading)
      }
      .accessibilityHidden(true)  // column labels; each row states its own values
    }
  }

  private static let sourceColumnWidth: CGFloat = 90
  private static let statusColumnWidth: CGFloat = 130

  /// Same shape as `LanguageLockSheet.searchField`, deliberately: the app
  /// already has a language search and a second visual idiom for the same job
  /// would read as a different feature.
  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.stTextSecondary)
      TextField(LivePreviewSettingsCopy.packsSearchPlaceholder, text: $searchText)
        .textFieldStyle(.plain)
        .accessibilityLabel("Search languages")
    }
    .frame(maxWidth: 240)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    // Recessed surface WITH a border, matching `InsetNotice` on this same page.
    // The sheet this was ported from underlines its field instead, which works
    // there because it spans the sheet's full width at the top. Inside a card
    // that underline reads as no container at all (founder, 2026-08-16).
    .background(Color.stPageBg, in: RoundedRectangle(cornerRadius: 9))
    .overlay(
      RoundedRectangle(cornerRadius: 9).strokeBorder(Color.stDivider, lineWidth: 1)
    )
  }

  /// Loading, unreadable, or nothing matching the search.
  @ViewBuilder
  private var nonListState: some View {
    switch packs.state {
    case .loading:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        // `packsLoading`, NOT `packInstalling` — this spinner is a local
        // inventory read. The per-row spinner below is the one that means a transfer.
        Text(LivePreviewSettingsCopy.packsLoading).settingsHelperCopy()
      }
    case .failed:
      Text(LivePreviewSettingsCopy.packsUnavailable).settingsHelperCopy()
    case .loaded:
      if visibleRows.isEmpty {
        Text(LivePreviewSettingsCopy.packsNoSearchMatch).settingsHelperCopy()
      }
    }
  }

  /// Search first, then group, then flatten — installed rows first, so the
  /// grouping policy survives the move to one table without a visible split.
  private var visibleRows: [LivePreviewPack] {
    guard case .loaded(let rows) = packs.state else { return [] }
    let groups = LivePreviewPackPresentation.groups(
      from: LivePreviewPackPresentation.matching(rows, query: searchText))
    return groups.installed + groups.available
  }

  /// Gated on the toggle because "In use" is a claim about a running preview,
  /// and nothing runs while the feature is off. Gated on the ENGINE because
  /// these are Apple's packs: with the universal engine selected the badge would
  /// name a language that is not the one on screen. Both terms read the same
  /// values the section above does, so the two cannot disagree.
  private func isActive(_ pack: LivePreviewPack) -> Bool {
    // Same reason: an "In use" badge is a claim about the language running NOW.
    guard isUsingApple, isPreviewOn, case .ready(let tag, _) = currentActive else { return false }
    return tag == pack.tag
  }

  @ViewBuilder
  private func packRow(_ pack: LivePreviewPack) -> some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(pack.localizedName).settingsRowLabel()
        if pack.nativeName != pack.localizedName {
          Text(pack.nativeName).settingsHelperCopy()
        }
        // The failure needs WORDS, not just a relabelled button. "Try again"
        // alone leaves the user guessing whether the download broke, whether
        // they did something wrong, or whether the language is unavailable — and
        // the remedy is the same for every cause, so one sentence answers all.
        if packs.failedTag == pack.tag {
          Text(LivePreviewSettingsCopy.packInstallFailed).settingsHelperCopy()
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Text(LivePreviewPackPresentation.availability(for: pack))
        .settingsHelperCopy()
        .frame(width: Self.sourceColumnWidth, alignment: .leading)

      statusCell(pack)
        .frame(width: Self.statusColumnWidth, alignment: .leading)
    }
  }

  @ViewBuilder
  private func statusCell(_ pack: LivePreviewPack) -> some View {
    if isActive(pack) {
      // "Ready" says the bytes are here; it never said WHICH language you are
      // actually previewing in. With nine installed, that was the whole confusion.
      ProviderStatusChip(
        status: ProviderStatus(label: LivePreviewSettingsCopy.packInUse, tone: .ready))
    } else if pack.isInstalled {
      ProviderStatusChip(
        status: ProviderStatus(
          label: LivePreviewSettingsCopy.packInstalled, tone: .unavailable))
    } else if packs.installingTag == pack.tag {
      // A spinner, never a percentage. Apple's progress object yields two
      // distinct values across a whole install, so a bar would be a fabrication.
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text(LivePreviewSettingsCopy.packInstalling).settingsHelperCopy()
      }
    } else {
      Button(
        packs.failedTag == pack.tag
          ? LivePreviewSettingsCopy.packRetry
          : LivePreviewSettingsCopy.packInstall
      ) {
        packs.install(tag: pack.tag)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .disabled(packs.installingTag != nil)
    }
  }
}
