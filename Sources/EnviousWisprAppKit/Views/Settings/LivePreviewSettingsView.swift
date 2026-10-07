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

  private typealias PreviewCopy = DictationSettingsCopy.Preview

  /// #2123: the preview model's download lifecycle. Optional for the same
  /// reason the speech-engine page's is — a preview or a test may render this
  /// page with no delivery home in the environment.
  @Environment(ModelDeliveryHome.self) private var modelDelivery: ModelDeliveryHome?

  /// #2154: the dictation-language picker, opened by the Change button.
  @State private var showLanguageSheet: Bool = false

  /// #3385: whether the two preview-engine cards are open under the summary.
  @State private var showPreviewEngineChoices: Bool = false

  init(packs: LivePreviewPacksModel, choicesExpanded: Bool = false) {
    self.packs = packs
    _showPreviewEngineChoices = State(initialValue: choicesExpanded)
  }

  /// #2436: the pack catalogue, opened by the Languages row or the bar's remedy.
  ///
  /// **One piece of state, not two, and that is the whole point.** This started as
  /// a `Bool` beside a separate `catalogSearchSeed` string, written together in one
  /// button action. Live UAT measured the seed arriving EMPTY at the sheet on every
  /// presentation, including the first one in a freshly launched process: with
  /// `.sheet(isPresented:)` the content closure reads the seed through a second,
  /// independent `@State` at content-build time, and the value it saw was the one
  /// from before the write. The remedy therefore opened on all 52 rows rather than
  /// the one language the user was sent here for — the entire value grounded review
  /// r2 finding C4 added, silently absent.
  ///
  /// `.sheet(item:)` closes the class rather than the instance: the seed TRAVELS
  /// with the presentation instead of being read back out of view state, so there
  /// is no second value that can be stale. The fresh `id` per request also gives
  /// each presentation its own view identity, which is what lets the sheet's
  /// `State(initialValue:)` take effect more than once.
  ///
  /// Nothing here is testable from a unit test — presentation is SwiftUI's, not
  /// ours — so `#2436` item 6 in the Live UAT spec is this fix's binding evidence,
  /// and it is stated rather than implied.
  @State private var catalogRequest: CatalogRequest?

  /// One catalogue presentation, carrying what it needs to open correctly.
  ///
  /// The bar's remedy seeds `search` with the missing language's NAME so the row a
  /// user was sent here for is already on screen; the Languages row passes nothing,
  /// because no particular language is in question there.
  ///
  /// `id` is fresh per request rather than derived from `search`: two consecutive
  /// remedies for the SAME language must still be two presentations, and an id
  /// equal to the search string would silently make the second one reuse the
  /// first's view identity — the exact failure this type exists to remove.
  private struct CatalogRequest: Identifiable {
    let id = UUID()
    let search: String
  }

  // MARK: - Derived state

  /// Whether APPLE's engine can run here. Still the gate for the pack list and
  /// the active-language summary, which are about Apple's packs specifically.
  @Environment(\.applePreviewSupported) private var isAppleSupported

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
  /// says about a live preview is false while this is off. The shipped default is
  /// `SettingsDefaultValues.livePreviewEnabled` and is not restated here.
  private var isPreviewOn: Bool { settings.livePreviewEnabled }

  private var universalState: DeliveryState {
    modelDelivery?.whisperPreviewState ?? .notReady
  }

  /// The status card's answer. One call, so the chip and its detail line can
  /// never describe different states.
  private var status: LivePreviewStatusMapping.Summary {
    previewStatus(isEnabled: isPreviewOn)
  }

  /// Capability for the selected engine even while the feature is switched off.
  /// Same readiness owner, including language, install and stale guards.
  private var engineReadiness: LivePreviewStatusMapping.Summary {
    previewStatus(isEnabled: true)
  }

  private func previewStatus(isEnabled: Bool) -> LivePreviewStatusMapping.Summary {
    LivePreviewStatusMapping.summary(
      isEnabled: isEnabled,
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

  // `universalWillProduceOutput` was deleted with the row that asked it (#2436).
  // Readiness now has exactly one consumer — the status text — and it reads the
  // mapping's `Summary` directly. A second local property re-deriving it, even an
  // unused one, is the shape r8 and r9 of #2154 cost two rounds to remove.

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
    guard let mode = packs.resolvedMode, mode == previewMode else { return nil }
    return packs.active
  }

  /// #3124: the language the preview itself resolves against, "en-GB" under English (UK)
  /// (`LivePreviewInstaller.previewLanguageMode`). The packs card must describe the pack the
  /// preview will actually use, so it resolves this, never the bare dictation lock.
  private var previewMode: LanguageMode {
    LivePreviewInstaller.previewLanguageMode(
      languageMode: settings.languageMode, stored: settings.englishSpelling)
  }

  /// True when the resolved value exists but describes a language the user has
  /// since moved away from — the state the card reports rather than hides.
  private var activeDescribesAnotherLanguage: Bool {
    guard let mode = packs.resolvedMode else { return false }
    return mode != previewMode
  }

  private var showsApplePacks: Bool {
    LivePreviewEnginePresentation.showsApplePacks(
      isAppleSupported: isAppleSupported, isUsingApple: isUsingApple)
  }

  // MARK: - Body

  var body: some View {
    @Bindable var settings = settings
    return SettingsContentView {
      // #3385: the privacy sentence belongs to the PREVIEW, so its short form is
      // this section's note and never a Dictation-wide or shared-component claim.
      VStack(alignment: .leading, spacing: SettingsPR1Layout.headingGap) {
      SettingsSectionHeading(map: .id(.sectionLivePreview), casing: .uppercased) {
        Text(PreviewCopy.privacyNote)
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
      }
      statusBar
      }
      engineSection
      packsSection
    }
    .environment(\.settingsPR1Density, true)
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
    .task(id: previewMode) {
      guard isAppleSupported else { return }
      // Re-read on EVERY appearance. The model outlives this page, so without
      // this a returning user would see the snapshot from whenever they last
      // opened it — past a download that finished meanwhile, past a macOS purge
      // of a staged asset. The catalogue exists precisely because this state is
      // not ours to cache.
      packs.useMode {
        LivePreviewInstaller.previewLanguageMode(
          languageMode: settings.languageMode, stored: settings.englishSpelling)
      }
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
          installedPackTags: installedPackTags),
        // Re-homed from the help line under the old Change button (#2436): the
        // consequence belongs where the action is taken. **Engine-specific**, because
        // the Auto asymmetry is Apple's alone — telling a universal user their preview
        // "uses your Mac's language" is false about their own engine.
        contextSubtitle: settings.livePreviewEngine == .apple
          ? LivePreviewSettingsCopy.pickerAppleCaveat
          : LivePreviewSettingsCopy.pickerUniversalCaveat,
        // #3124: Apple's preview runs English (UK) only with the en-GB pack installed.
        offersEnglishUK: LanguageLockOptions.previewOffersEnglishUK(
          previewEngine: settings.livePreviewEngine, installedPackTags: installedPackTags))
    }
    .sheet(item: $catalogRequest) { request in
      // The retained model, never a copy: dismissing this sheet mid-install must not
      // cancel the install, because the workflow outlives any presentation.
      //
      // `request.search`, never a separately-read `@State`: see `catalogRequest`.
      LivePreviewPackCatalogSheet(
        packs: packs, initialSearch: request.search)
    }
  }

  // MARK: - Hero card

  // MARK: - Status bar

  /// What is happening, which language, and the switch — on one line (#2436).
  ///
  /// Historical #2436 reason, carried verbatim (current placement below):
  /// Replaces the hero card, its status column and the toggle row. Those three said
  /// the same sentence three times before the page said anything: the page header
  /// already carries "See your words on screen while you are still speaking"
  /// (`SettingsPage.swift:92`), the hero repeated it, and the toggle repeated the
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
  /// #3385: the page-header references above describe #2436's original layout.
  /// The header is now removed; the shared row's title, short line and help carry
  /// the explanation. The reason for removing duplicate prose still applies.
  ///
  /// Composition is `LivePreviewStatusBarPresentation`, not this body, so the rules
  /// about what may be named in which state are testable without rendering.
  private var statusBar: some View {
    @Bindable var settings = settings
    let bar = LivePreviewStatusBarPresentation.bar(
      summary: status, engine: settings.livePreviewEngine,
      appleActive: currentActive, languageMode: settings.languageMode)

    return BrandedSection {
      BrandedRow(showDivider: bar.action != nil) {
        VStack(alignment: .leading, spacing: 8) {
          // #3385: the switch has its visible name again, with the shared row's
          // short line and "?" (the tab has no page header to say what it does).
          SettingsRow(
            map: .id(.livePreview),
            icon: "text.viewfinder"
          ) {
            // Both sentences: the approved short help, and the original one whose
            // pasted-text half may not be dropped (`previewPrivacyFooter`).
            VStack(alignment: .leading, spacing: 8) {
              SettingsHelpText(text: String(localized: PreviewCopy.toggleHelp))
              SettingsHelpText(text: LivePreviewSettingsCopy.previewPrivacyFooter)
              SettingsHelpText(text: bar.detail)
            }
          } control: {
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
              // **`.fixedSize()` is load-bearing, and its absence was a real defect.**
              // `BrandedToggleStyle` lays out `HStack { label; Spacer(); track }` so that
              // on an ORDINARY settings row the whole row is the hit target and the switch
              // sits at its right edge. That is correct where a visible label owns the row.
              //
              // Historical #2436 measurement and reason, carried verbatim:
              // This row has no label — #2436 deleted it, because the page header above
              // already says what the switch does. The style's `Spacer` then claimed every
              // remaining point: Live UAT measured the checkbox at 738pt wide starting
              // immediately after the language chip, so the empty middle of the status bar
              // silently toggled Live Preview, and the chip rendered stranded a third of the
              // way across instead of beside the switch as designed.
              //
              // Sizing to the ideal width collapses the style's internal `Spacer` and lets
              // this row's own `Spacer(minLength: 12)` above do the pushing. Deliberately
              // NOT a `.frame(width:)`: the track's size belongs to `BrandedToggleTrack`,
              // and pinning a number here would be a second place to change it.
              // (#3385: the visible label is back as the shared row's title, but the
              // switch itself still carries no visible label of its own, so the same
              // hit-rectangle rule applies.)
              Toggle("", isOn: $settings.livePreviewEnabled)
              .labelsHidden()
              .toggleStyle(BrandedToggleStyle())
              .fixedSize()
              .disabled(!anyEngineAvailable)
              // The visible label is gone; this is the only thing naming the switch
              // for VoiceOver, which is why `toggleLabel` survives the copy cull.
              // (#3385: the name is visible again as the row's title, but the
              // switch itself still has none, so this still names it.)
              .accessibilityLabel(LivePreviewSettingsCopy.toggleLabel)
          }

          .rowTitleStatus {
            ProviderStatusChip(status: EngineSummaryPresentation.previewStatus(status), isHeadline: true)
          }
          .rowSupplementaryControl(belowWidth: 502) {
              if let language = bar.language {
                // **It has to LOOK like a control, and two stacked Texts did not.**
                // `.buttonStyle(.plain)` over a bare VStack renders as ordinary
                // right-aligned copy — the founder read the most important control on
                // the page as a status readout and did not know it could be pressed
                // (2026-08-26). A bordered container plus a disclosure chevron is the
                // platform's own vocabulary for "this opens a list", which is exactly
                // what it does.
                //
                // The provenance moves INSIDE the container rather than under it: it
                // describes the value, so leaving it outside made the control look
                // like it ended at the name.
                LivePreviewLanguageMenuButton(
                  name: SettingsMapRef.dynamic(.livePreviewLanguage, .previewLanguage(language))
                    .title,
                  provenance: language.provenance
                ) {
                  showLanguageSheet = true
                }
                // **The provenance is IN the label, not just on screen.** An explicit
                // `accessibilityLabel` REPLACES the child text announcement, so naming
                // only `language.name` dropped the second line entirely for VoiceOver —
                // and that line is the one carrying the Auto asymmetry, the distinction
                // between a language the Mac chose and one the user picked. A sighted
                // user reads both; a VoiceOver user heard one. Cloud review on PR #2440.
                .accessibilityLabel(
                  "Change dictation language: \(language.name), \(language.provenance)")
                .help(String(localized: PreviewCopy.languageShort))
                .settingsMapRegistration(.livePreviewLanguage)
              }

          }

          // #3385 founder supersedes the always-visible detail hierarchy: Ready/Off
          // stay compact; the full detail remains in help. Unhappy detail and remedies
          // remain visible because the reason is what a returning user needs.
          if EngineSummaryPresentation.showsDetail(status) {
            Text(bar.detail).font(.stHelper).foregroundStyle(.stTextSecondary)
              .fixedSize(horizontal: false, vertical: true)
              .padding(.leading, 37)
          }
        }
      }

      // The bar's one remedy, and the only button on the page. Every other unhappy
      // state is repaired where the control already lives: the engine cards own
      // download, cancel, resume, retry and remove, and Faster Transcription is
      // turned off on its own page. (#3385: the engine actions now sit in the
      // preview-engine summary's status region, visible whether or not the cards
      // are open.)
      if let action = bar.action {
        BrandedRow(showDivider: false) {
          HStack(spacing: 12) {
            Spacer(minLength: 0)
            switch action {
            case .browseDownloads(let initialSearch):
              // The last system-styled button left on this page after #2445
              // replaced the other three. Same fact, same fix.
              SettingsActionButton(
                verbatimTitle: LivePreviewSettingsCopy.browseDownloadsButton,
                isEnabled: true,
                emphasis: .filled
              ) {
                catalogRequest = CatalogRequest(search: initialSearch)
              }
              .settingsMapRegistration(.livePreviewBrowseDownloads)
            }
          }
        }
      }
    }
    // Always visible: never gated on engine, toggle, Apple support or pack state.
    // (#3385: the footer moved. Its short form is the Live Preview heading's note,
    // and the full sentence is the switch's "?" help above, still shown on every
    // engine and every Mac.)
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
  ///
  /// #3385: the two cards now open under a summary with Change, as on the
  /// Engine tab. Download, Cancel, Resume, Try Again, reasons and progress remain
  /// in `engineStatus`, reachable while the cards are closed. When Remove is
  /// Universal's only action, it appears in Universal's card footer after opening
  /// Change (founder, 2026-10-03: the engine stays one line).
  private var engineSection: some View {
    let apple = LivePreviewEnginePresentation.appleCard(
      isSelected: settings.livePreviewEngine == .apple,
      isSupported: isAppleSupported)
    let universal = LivePreviewEnginePresentation.universalCard(
      isSelected: settings.livePreviewEngine == .universal,
      routeExists: universalExists,
      state: universalState)
    let selected = isUsingApple ? apple : universal

    return VStack(alignment: .leading, spacing: SettingsPR1Layout.headingGap) {
      // The first link from a settings page to the Help Centre. The two
      // engines differ in OS floor, language coverage and download size, and
      // a card cannot carry that comparison without becoming the article.
      SettingsSectionHeading(map: .id(.sectionPreviewEngine), casing: .uppercased) {
        Link(destination: URL(string: LivePreviewEngineCopy.learnMoreURL)!) {
          HStack(spacing: 4) {
            Text(LivePreviewEngineCopy.learnMoreLabel)
            Image(systemName: "arrow.up.right")
          }
          .font(.stHelper)
        }
        .foregroundStyle(.stAccent)
        .settingsMapRegistration(.previewEngineCompare)
      }

      HStack(spacing: 6) {
        Text(PreviewCopy.engineShort)
          .font(.stRowHelper)
          .foregroundStyle(.stTextSecondary)
          .fixedSize(horizontal: false, vertical: true)
        SettingsInfoButton(
          rowTitle: LivePreviewEngineCopy.sectionHeader,
          tooltip: String(localized: PreviewCopy.engineHelp)
        ) {
          SettingsHelpText(text: String(localized: PreviewCopy.engineHelp))
        }
      }
      .padding(.leading, 4)

      SettingsSummaryCard(
        map: .id(.previewEngine),
        isExpanded: $showPreviewEngineChoices,
        changeAccessibilityLabel: PreviewCopy.changeEngine,
        change: .previewEngineChange,
        keepCurrent: .previewEngineKeepCurrent
      ) {
        engineSummary(selected)
      } status: {
        engineStatus(selected: selected, universal: universal)
      } choices: {
        engineChoices(apple: apple, universal: universal)
      }
      // An engine change made elsewhere leaves the summary describing the new
      // engine; close choices it made obsolete.
      .onChange(of: settings.livePreviewEngine) { _, _ in
        showPreviewEngineChoices = false
      }
    }
  }

  private func engineSummary(_ card: LivePreviewEnginePresentation.Card) -> some View {
    EngineSummaryContent(icon: isUsingApple ? "apple.logo" : "globe", name: card.title,
      short: String(localized: isUsingApple ? PreviewCopy.appleSummary : PreviewCopy.universalSummary),
      status: engineReadiness.kind == .active ? EngineSummaryPresentation.previewStatus(engineReadiness) : nil)
  }

  /// Reasons and actions, outside the disclosure. The selected engine's own
  /// reason first; then the Universal engine's state and its one action,
  /// whichever engine is in use, named so it is clear which engine they are for.
  @ViewBuilder
  private func engineStatus(
    selected: LivePreviewEnginePresentation.Card,
    universal: LivePreviewEnginePresentation.Card
  ) -> some View {
    if isUsingApple, let reason = selected.unavailability {
      Text(reason)
        .font(.stHelper)
        .foregroundStyle(.stWarning)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 4)
    }
    // A downloaded Universal engine whose only action is Remove shows no row here: its
    // Remove lives on its card under Change, so the engine stays one line (founder,
    // 2026-10-03: "why are we showing remove universal... This should be all 1 line").
    if universal.unavailability != nil || universal.progress != nil
      || (universal.action != nil && !Self.removeLivesOnCard(universal))
    {
          VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 11) {
              SettingsRowIcon(systemName: "globe")
              VStack(alignment: .leading, spacing: 2) {
                Text(universal.title).settingsRowLabel()
                if let reason = universal.unavailability {
                  Text(reason).font(.stHelper).foregroundStyle(.stTextSecondary).fixedSize(horizontal: false, vertical: true)
                }
              }
              Spacer(minLength: 8)
              if let action = universal.action {
                // **Same intent as before, on a control that renders it.** Kept
                // verbatim, because the reason still holds:
                //
                // > Removal is bordered, everything else prominent: the destructive
                // > action should not be the most inviting thing on the card.
                //
                // What changed is the mechanism. `.bordered` rendered `Remove` as a
                // flat grey capsule indistinguishable from this app's disabled
                // treatment, so "quieter than the primary" became "looks broken"
                // (Codex UX review, 2026-08-26) — the same defect already measured
                // on Download and Browse. Outlined is the quiet-but-alive rung, and
                // it has a hover state, which the flat one did not.
                SettingsActionButton(
                  verbatimTitle: Self.label(for: action),
                  isEnabled: true,
                  emphasis: action == .remove ? .quiet : .filled, shape: .roundedRect, size: .medium
                ) {
                  perform(action)
                }
                .settingsMapRegistration(Self.mapID(for: action))
              }
            }
            if let progress = universal.progress {
              ProgressView(value: progress)
                .padding(.leading, 37)
            }
          }
    }
  }

  private func engineChoices(
    apple: LivePreviewEnginePresentation.Card,
    universal: LivePreviewEnginePresentation.Card
  ) -> some View {
    // **`GridItem` defaults to `.center`, which is why the two cards did not
    // line up.** Measured on the live page: Apple 101.5pt tall starting at
    // y=341, Universal 82.5pt starting at y=330.5 — two cards presented as
    // equal choices, disagreeing on both edges, which reads as unfinished and
    // makes the taller one look more important (Codex UX review, 2026-08-26).
    //
    // Two changes, because one alone is not enough: `alignment: .top` settles
    // the top edge, and `maxHeight: .infinity` on the cards below makes them
    // fill the row so the bottoms agree too. The heights differ legitimately —
    // Apple's tagline runs to two lines and Universal carries a footer button —
    // so equalising is the fix rather than trimming copy to match.
    LazyVGrid(
      columns: [
        GridItem(.flexible(), spacing: 12, alignment: .top),
        GridItem(.flexible(), spacing: 12, alignment: .top),
      ],
      spacing: 12
    ) {
      // #3482: the Settings Map derives the preview engine choices from this same list.
      ForEach(Self.engineChoices, id: \.self) { choice in
        switch choice {
        case .apple: engineCard(apple, icon: "apple.logo", choice: .apple)
        case .universal: engineCard(universal, icon: "globe", choice: .universal)
        }
      }
    }
  }

  /// The preview engine cards, in the order the grid shows them.
  nonisolated static let engineChoices: [LivePreviewEngineChoice] = [.apple, .universal]

  /// One engine card.
  ///
  /// **Selecting is separate from acting, and the structure enforces it.**
  /// Tapping the card chooses the engine; the footer button downloads, cancels,
  /// resumes, retries or removes. Choosing an engine must never start a 217 MB
  /// download by itself — the founder's Gate 1 decision on #2123. The footer is
  /// a sibling of `EngineCard`'s selection button rather than a child, because
  /// that button combines its accessibility children and anything actionable
  /// inside it would be merged into the same element.
  ///
  /// #3385: the actions moved to the summary's status region (`engineStatus`), so
  /// they are reachable with the cards closed and are drawn once. The one exception
  /// is Universal's lone Remove, which this card's footer carries (see
  /// `removeLivesOnCard`); the separation above holds in both places, a sibling of
  /// the selection, never a child.

  /// The preview engine card's Settings Map choice (#3482). Exhaustive, so a new engine must be
  /// given a map node.
  nonisolated static func mapID(for choice: LivePreviewEngineChoice) -> SettingsMapID {
    switch choice {
    case .apple: .previewEngineApple
    case .universal: .previewEngineUniversal
    }
  }

  /// The preview engine card's name, which its map node carries: Apple's engine by its product
  /// name, Universal by its catalog title.
  nonisolated static func mapTitle(for choice: LivePreviewEngineChoice) -> SettingsMapTitle {
    switch choice {
    case .apple: .verbatim(LivePreviewEngineCopy.appleTitle)
    case .universal: .resource(LivePreviewEngineCopy.universalTitleResource)
    }
  }

  /// The line the preview engine card shows under its name, from the same copy owner.
  nonisolated static func mapDescription(for choice: LivePreviewEngineChoice)
    -> LocalizedStringResource
  {
    switch choice {
    case .apple: LivePreviewEngineCopy.appleDescriptionResource
    case .universal: LivePreviewEngineCopy.universalDescriptionResource
    }
  }

  private func engineCard(
    _ card: LivePreviewEnginePresentation.Card,
    icon: String,
    choice: LivePreviewEngineChoice
  ) -> some View {
    EngineCard(
      icon: icon,
      map: .id(Self.mapID(for: choice)),
      tagline: card.description,
      unavailability: card.unavailability,
      isSelected: card.isSelected,
      onSelect: {
        settings.livePreviewEngine = choice
        // Picking, including the engine already chosen, closes the cards.
        showPreviewEngineChoices = false
      },
      fillsHeight: true,
      footer: {
        if choice == .universal, Self.removeLivesOnCard(card),
          let action = card.action
        {
          // A sibling of the selection button, never a child (see above).
          SettingsActionButton(
            verbatimTitle: Self.label(for: action), isEnabled: true,
            emphasis: .quiet, shape: .roundedRect, size: .medium
          ) {
            perform(action)
          }
          .settingsMapRegistration(Self.mapID(for: action))
          .padding([.horizontal, .bottom], 16)
        }
      })
  }

  /// Whether the Universal engine's only action is Remove, so the button belongs on its
  /// card under Change rather than on a second line under the summary.
  static func removeLivesOnCard(_ universal: LivePreviewEnginePresentation.Card) -> Bool {
    // Whichever engine is in use: a separate Universal/Remove line under the summary
    // was the second line the founder asked to remove (2026-10-03).
    universal.action == .remove && universal.progress == nil
  }

  /// The Universal engine action's Settings Map identity; its button name comes from the map
  /// node (#3482). Exhaustive, so a new action must be given a node.
  static func mapID(for action: LivePreviewEnginePresentation.Action) -> SettingsMapID {
    switch action {
    case .download: .previewEngineUniversalDownload
    case .cancelDownload: .previewEngineUniversalCancel
    case .resumeDownload: .previewEngineUniversalResume
    case .retryDownload: .previewEngineUniversalRetry
    case .remove: .previewEngineUniversalRemove
    }
  }

  private static func label(for action: LivePreviewEnginePresentation.Action) -> String {
    SettingsMapRef.id(mapID(for: action)).title
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
  //
  // **The section is gone; the language moved into the status bar (#2436).** What
  // follows is every reason the three deleted members recorded, carried verbatim
  // rather than summarised, because each one still constrains the bar that replaced
  // them.
  //
  // From `languageSection`, on which value may describe the language:
  //
  // > `currentActive`, never `packs.active` — a value resolved for a language the
  // > user has left must not describe this panel either.
  //
  // Still binding, and `LivePreviewStatusBarPresentation.appleLanguage` is where it
  // now lives.
  //
  // From `languageSection`, on why the control may not be Apple-only:
  //
  // > **The language control is NOT Apple-specific, and gating it on the pack
  // > list stranded universal users.** `showsApplePacks` correctly hides Apple's
  // > PACK TABLE on the other engine — those are Apple's languages. But the
  // > universal engine honours a LOCK too (`WhisperPreviewEngineResolver` maps
  // > `.locked(code)` straight through and only `.auto` becomes nil), so a user
  // > locked to the wrong language had no way to see or change it from the page
  // > that was telling them the preview was ready. Review r7.
  //
  // The bar honours this by construction: the language region renders on BOTH
  // engines, and only `showsApplePacks` gates the pack table below.
  //
  // From `universalLanguageSection`, on what the universal row must not do:
  //
  // > Deliberately simpler than Apple's: there is no pack to resolve, so there is
  // > no needs-download or unsupported state to describe. What it must NOT do is
  // > stay silent — this engine follows a lock, and the whole point of the row is
  // > that a user locked to the wrong language can see it and change it.
  //
  // `universalLanguage` in the presentation is never nil for either language mode,
  // which is that requirement expressed as a return type rather than a habit, and
  // `chipNeverPromisesOutput`'s scenario table asserts it for both modes.
  //
  // From `activeSummary`, on where the Change button leads:
  //
  // > #2154. The panel used to state the language and point at another page,
  // > which is a dead end for the one thing somebody reading it wants to
  // > change. The help line under the button says the consequence out loud:
  // > this sets the DICTATION language, not a preview-only one. Founder
  // > decision, one language in one place — two settings that can disagree
  // > hand the user a mismatch they cannot diagnose.
  //
  // The button survives as the language region itself. The consequence sentence
  // moved into `LanguageLockSheet`'s context subtitle in this same chunk, next to the moment it
  // becomes true, rather than sitting under a button nobody has pressed yet.
  //
  // **The one reason NOT carried forward is the two-container rule**, and it is
  // superseded rather than dropped:
  //
  // > **TWO containers, not one — founder 2026-08-18, comparing the shipped
  // > page against his mockup: "you combined it into 1 container instead of
  // > keeping it 2 containers."**
  //
  // That rule separated a CONTROL from its EXPLAINER so the control was not buried
  // in a paragraph. #2436 deletes the explainer instead: the fact it carried (on
  // Auto the preview follows the Mac, not the dictation language) is now two words
  // under the language itself. There is no paragraph left for the control to be
  // buried in. Founder direction, 2026-08-25.

  // MARK: - Language table

  /// One row where fifty-four used to be (#2436).
  ///
  /// The catalogue moved to `LivePreviewPackCatalogSheet`, which carries every reason
  /// the table recorded. What stays here is the summary and the way in.
  ///
  /// Hidden entirely below macOS 26 (no Apple packs exist to manage, and an
  /// empty list under a disabled toggle reads as something being broken) and on
  /// the universal engine, which carries its own languages and has no packs.
  ///
  /// Carried verbatim, and still true of the LOAD even though the table is gone:
  ///
  /// > The catalogue LOAD is deliberately NOT gated the same way: its `.task` is
  /// > keyed on the dictation language, so adding the engine to the condition
  /// > without adding it to the key would leave a user who switches back to Apple
  /// > looking at a snapshot from before.
  @ViewBuilder
  private var packsSection: some View {
    if showsApplePacks {
      VStack(alignment: .leading, spacing: SettingsPR1Layout.headingGap) {
      SettingsSectionHeading(map: .id(.previewLanguages), casing: .uppercased) {
        // #3385 B14 supersedes the 2026-08-26 count removal: a quiet heading
        // note only from the currently loaded inventory, never a 7/54 guess.
        if case .loaded(let inventory) = packs.state {
          Text(EngineSummaryCopy.installedPacks(installed: inventory.filter(\.isInstalled).count, total: inventory.count))
            .font(.stHelper).foregroundStyle(.stTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      BrandedSection {
        // **The ROW is the button, not a card containing one** (founder,
        // 2026-08-26). Everything here did one thing: the title named the action,
        // the paragraph explained it, and a separate `Browse` performed it — so
        // the row was an explanation wrapped around a control, with two names for
        // one job and a small target at the far right.
        //
        // Collapsing them removes a control rather than restyling one, and it
        // dissolves the naming question with it: there is no longer a second word
        // to reconcile with "Install new languages".
        //
        // Pressable in EVERY state on purpose, including `.failed` — the sheet
        // re-reads the inventory when it opens, so pressing a row that says "could
        // not read the language list" is exactly the retry a user wants. A
        // disabled row there would be a dead end wearing a reason.
        //
        // #3385: the shared row's action variant. The row (icon, name, short
        // line, chevron) is the button; its "?" is a separate sibling control.
        // Carried from the deleted `LivePreviewInstallRow`: **a row whose title is
        // a verb should be pressable.** This replaced a card that contained a
        // `Browse` button: the title said "Install new languages", the body
        // explained downloads, and a small button at the far right did the only
        // thing available. That is two names for one job, and the smallest part of
        // the row was the only part that worked. The whole row is the target
        // (`swift-patterns.md` RULE: plain-button-content-shape, in `SettingsRow`).
        BrandedRow(showDivider: false) {
          SettingsRow(
            map: .dynamic(
              .previewLanguagesInstall,
              .livePreviewPacks(loading: packs.state == .loading, failed: packs.state == .failed)),
            icon: "arrow.down.circle",
            resolvedHelp: LivePreviewSettingsCopy.packsDescription,
            primaryAction: { catalogRequest = CatalogRequest(search: "") }
          ) {
            // The chevron replaces the button rather than joining it. A trailing
            // disclosure is the platform's own "this opens something" mark, and it
            // does not need a word that would then have to agree with the title.
            Image(systemName: "chevron.right")
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(Color.stTextTertiary)
              .accessibilityHidden(true)
          }
        }
      }
    }
      }
  }


}

// MARK: - Status-bar language control

/// The dictation-language control in the status bar, shaped like the pop-up menu
/// it behaves as.
///
/// **Why it is not an `NSPopUpButton` / SwiftUI `Menu`.** The list it opens is a
/// searchable sheet over fifty-plus entries with its own caveat subtitle
/// (`LanguageLockSheet`), which a menu cannot host. So this borrows the pop-up's
/// APPEARANCE — bordered container, value, disclosure chevron — while keeping the
/// sheet's behaviour. The chevron is `chevron.up.chevron.down`, the platform's
/// pop-up glyph, rather than a plain `chevron.down`, which reads as "expand a
/// section". It wears the input-field colours and the faint row hover, as the
/// microphone picker does.
struct LivePreviewLanguageMenuButton: View {
  let name: String
  let provenance: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 1) {
          Text(name)
            .font(.stRowLabel)
            .foregroundStyle(Color.stTextPrimary)
            .lineLimit(1)
          Text(provenance)
            .font(.stHelper)
            .foregroundStyle(Color.stTextSecondary)
            .lineLimit(1)
        }
        Image(systemName: "chevron.up.chevron.down")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(Color.stTextSecondary)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .background(Color.stInputBg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(Color.stInputBorder, lineWidth: 1)
          .allowsHitTesting(false)
      )
      .settingsHoverRow(cornerRadius: 8)
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
  }
}

/// Whether Apple's preview engine runs on this Mac (macOS 26 or later). In the app it is always
/// the system's own answer; the Settings render tests set it so each state renders the same on
/// every macOS, and render the unsupported page on purpose (#3482 adversarial review).
private struct ApplePreviewSupportedKey: EnvironmentKey {
  static var defaultValue: Bool { ApplePreviewEngineResolver.isSupportedOnThisSystem }
}

extension EnvironmentValues {
  var applePreviewSupported: Bool {
    get { self[ApplePreviewSupportedKey.self] }
    set { self[ApplePreviewSupportedKey.self] = newValue }
  }
}
