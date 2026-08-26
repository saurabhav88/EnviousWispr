import EnviousWisprLivePreview
import SwiftUI

/// The Apple language catalogue, as a sheet rather than fifty-four rows on the page (#2436).
///
/// **Why it left the page.** Founder, 2026-08-25: the settings page had "a super long
/// never ending scrolling language selector". Measured on his Mac the day #2080 shipped:
/// one language installed, fifty-three downloadable, so the tallest thing on a page about
/// switching a feature on was fifty-three downloads nobody asked for.
///
/// **The split it preserves is the founder's, not a new one** (`live-preview.md`
/// RULE: the-picker-offers-what-works-now-the-table-is-the-catalogue): the picker answers
/// "what can I switch to right now" and lists installed languages only; THIS is the
/// catalogue, the only place a language is acquired. #2436 makes that split physical —
/// two sheets — instead of a sheet and an inline table.
///
/// Carried verbatim from `packsSection`, on why the Source column existed and why it does
/// not need to any more:
///
/// > **One table, replacing the two cards #2080 shipped.** Those cards existed
/// > to make the installed/downloadable boundary visible after ten rows, which a
/// > Source column does better: it aligns, it scans, and it does not split the
/// > list in half. Group ORDER is preserved — installed first — so
/// > `LivePreviewPackPresentation.groups(from:)` still owns the policy and its
/// > tests still mean something.
///
/// The boundary is now the FILTER, which does the same job in a place where it can also
/// be the default: this sheet opens on `Not on this Mac`, because acquiring is the only
/// reason to be here. `groups(from:)` still owns the policy and still supplies both counts.
///
/// Also carried, and still binding:
///
/// > No drag handles and no per-row overflow menu, both of which the mockup
/// > drew: nothing in the app orders languages, and Apple's packs are not ours
/// > to delete, so each would be a control with nothing behind it (founder,
/// > Gate 1).
struct LivePreviewPackCatalogSheet: View {
  @Environment(\.dismiss) private var dismiss

  /// **Owned by the WINDOW, not by this sheet.** The install workflow outlives any
  /// presentation: dismissing this sheet mid-download must not cancel it, which is why
  /// the model is passed in rather than created here.
  let packs: LivePreviewPacksModel

  /// Seeded by the status bar's remedy with the missing language's NAME, so the row a
  /// user was sent here for is already on screen. Empty from the Languages row, where
  /// there is no particular language in question.
  /// **No `activeTag` any more, and it is removed rather than defaulted.** It fed
  /// the "In use" badge, which only ever rendered on an installed row — a row this
  /// sheet no longer shows. A defaulted-but-ignored parameter would have left every
  /// call site passing a value nothing reads, which is how a dead argument survives
  /// a migration.
  init(packs: LivePreviewPacksModel, initialSearch: String = "") {
    self.packs = packs
    _searchText = State(initialValue: initialSearch)
  }

  /// View-local: a search box is about what this SHEET is showing, not about the
  /// catalogue, so the model has no reason to know it exists.
  @State private var searchText: String

  var body: some View {
    // **No `NavigationStack`, and that is the fix rather than a simplification.**
    // `.navigationTitle` renders through AppKit's own title chrome, which insets
    // the text by a value this sheet does not control — measured sitting ~64pt
    // from the sheet edge while the body copy below it starts at 16pt, so the
    // title read as belonging to a different container than everything under it
    // (founder, 2026-08-26). A plain header row shares ONE inset constant with
    // the body, which is what makes them line up by construction rather than by
    // a number someone has to keep matching.
    //
    // Losing the navigation bar also loses the toolbar that carried the only
    // dismissal, so `titleBar` provides both the title and an explicit close.
    VStack(spacing: 0) {
      titleBar
      Divider().overlay(Color.stDivider)
      header
      Divider().overlay(Color.stDivider)
      content
      Divider().overlay(Color.stDivider)
      // **Explicit, because dropping `NavigationStack` dropped the toolbar that
      // used to render this.** `Done` lived in a `confirmationAction` toolbar
      // item; removing the navigation chrome to fix the title's inset would have
      // silently removed the sheet's primary exit with it. Kept alongside the
      // close control rather than replaced by it: `Done` is where a keyboard user
      // lands by default, and it is what the earlier screenshots trained.
      footer
    }
    .frame(minWidth: 460, minHeight: 420)
    .background(Color.stPageBg)
    // **A failed read must be retryable, or the message is a dead end.**
    // `packsUnavailable` tells the user to reopen; nothing reloaded when they did,
    // so reopening produced the same failure forever. Only on `.failed`, so an
    // ordinary open does not re-read an inventory the page already has.
    .task {
      if case .failed = packs.state { await packs.load() }
    }
  }

  // MARK: - Title bar

  /// The sheet's own title row, sharing `Self.inset` with the body beneath it.
  ///
  /// **The close control is not decoration.** Before this the only way out was
  /// the `Done` button at the far bottom-right, which on a long scrolled list is
  /// off-screen and reads as "commit" rather than "leave" — nothing here is
  /// committed, so a user looking for the ordinary way to abandon a sheet found
  /// none (founder, 2026-08-26). Escape already dismissed it, but an invisible
  /// keyboard-only exit is not an affordance.
  private var titleBar: some View {
    HStack(spacing: 8) {
      Text(LivePreviewSettingsCopy.packsHeader)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(Color.stTextPrimary)
      Spacer(minLength: 12)
      CatalogCloseButton { dismiss() }
    }
    .padding(.horizontal, Self.inset)
    .padding(.vertical, 12)
  }

  // MARK: - Header

  /// One inset for the title and for everything under it. Shared rather than
  /// repeated, because the defect this replaced was two containers disagreeing
  /// about their left edge.
  private static let inset: CGFloat = 16

  private var footer: some View {
    HStack {
      Spacer(minLength: 0)
      // Filled, where the row actions are outlined: one primary, many secondaries.
      // NOT `.borderedProminent`, which rendered filled while it lived in the
      // navigation toolbar and grey the moment it moved into a plain row — the
      // same container-dependence measured on `Browse`.
      SettingsActionButton(
        title: LivePreviewSettingsCopy.catalogDoneButton,
        isEnabled: true,
        emphasis: .filled
      ) {
        dismiss()
      }
      .keyboardShortcut(.defaultAction)
    }
    .padding(.horizontal, Self.inset)
    .padding(.vertical, 12)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(LivePreviewSettingsCopy.packsDescription).settingsReadingCopy()

      // Only once there is a list to search: a search box over a spinner or over
      // the "could not read" message is a control that does nothing.
      if case .loaded = packs.state {
        searchField
      }
    }
    .padding(Self.inset)
  }

  /// Carried verbatim from the page's own search box, whose shape this keeps:
  ///
  /// > Same shape as `LanguageLockSheet.searchField`, deliberately: the app
  /// > already has a language search and a second visual idiom for the same job
  /// > would read as a different feature.
  ///
  /// The recessed-with-a-border treatment came from the same decision:
  ///
  /// > there because it spans the sheet's full width at the top. Inside a card
  /// > that underline reads as no container at all (founder, 2026-08-16).
  ///
  /// This IS a sheet now, so the underline would have been available again — kept as a
  /// bordered field anyway, because the third idiom for one job is the cost this comment
  /// was written to avoid.
  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").foregroundStyle(.stTextSecondary)
      TextField(LivePreviewSettingsCopy.packsSearchPlaceholder, text: $searchText)
        .textFieldStyle(.plain)
        .accessibilityLabel("Search languages")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color.stSectionBg, in: RoundedRectangle(cornerRadius: 9))
    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.stDivider, lineWidth: 1))
  }

  // **The installed half is GONE, and that is a scope change, not a tidy-up.**
  // Two chips asked the user to understand a split before they could act, on a
  // sheet that exists for exactly one reason: acquiring a language you do not
  // have (founder, 2026-08-26 — "remove on this mac part because that is the
  // confusing part"). What is already installed is answerable from the language
  // control at the top of the page, which lists precisely the installed
  // languages you can switch to.
  //
  // Consequence, stated rather than discovered later: a pack that is installed
  // but NOT lockable for dictation now appears in neither place. That is
  // reachable only when Apple ships a preview pack for a language the
  // transcription backend cannot lock, and such a pack cannot be selected or
  // used, so nothing is lost but its visibility.

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    switch packs.state {
    case .loading:
      // `packsLoading`, NOT `packInstalling` — this spinner is a local inventory
      // read. The per-row spinner below is the one that means a transfer.
      centered {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text(LivePreviewSettingsCopy.packsLoading).settingsHelperCopy()
        }
      }
    case .failed:
      centered { Text(LivePreviewSettingsCopy.packsUnavailable).settingsHelperCopy() }
    case .loaded:
      if visibleRows.isEmpty {
        // **An empty FILTER is not a failed SEARCH.** With every pack installed the
        // default half is empty and no query was typed, so blaming the search would
        // accuse the user of something they did not do.
        centered { Text(emptyMessage).settingsHelperCopy() }
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(visibleRows, id: \.id) { pack in
              packRow(pack)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
              Divider().overlay(Color.stDivider).padding(.leading, 16)
            }
          }
        }
      }
    }
  }

  private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack {
      Spacer()
      content()
      Spacer()
    }.frame(maxWidth: .infinity)
  }

  /// Which nothing-here message applies: the search found nothing, or every
  /// language is already installed.
  ///
  /// **Still two cases, and the distinction is the one that shipped wrong once.**
  /// An empty list because you searched for "qqq" and an empty list because there
  /// is genuinely nothing left to install are different facts, and blaming the
  /// search for the second is the defect this branch exists to prevent.
  private var emptyMessage: String {
    guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return LivePreviewSettingsCopy.packsNoSearchMatch
    }
    return LivePreviewSettingsCopy.catalogNothingToInstall
  }

  private var loadedPacks: [LivePreviewPack] {
    guard case .loaded(let rows) = packs.state else { return [] }
    return rows
  }

  /// The searched grouping. Carried from when it also fed two filter chips:
  ///
  /// > **One searched grouping feeds BOTH the chips and the rows.** Computing them
  /// > separately is how the chips came to count the full catalogue while the rows
  /// > showed only matches — a chip reading "Not on this Mac 53" above one row is
  /// > worse than no chip.
  ///
  /// The chips are gone, so that particular disagreement is no longer reachable —
  /// kept as one call anyway, because `groups(from:matching:)` owning the split is
  /// what makes the classification testable independently of this view.
  private var visibleGroups: LivePreviewPackPresentation.Groups {
    LivePreviewPackPresentation.groups(from: loadedPacks, matching: searchText)
  }

  /// Always the not-installed half. `groups(from:matching:)` still owns the
  /// split and still applies the search to both, so the classification and its
  /// tests are untouched; this sheet simply renders one side of it.
  private var visibleRows: [LivePreviewPack] {
    visibleGroups.available
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

      statusCell(pack)
    }
  }

  /// **Two branches were deleted here, not left unreachable.** `packInUse` and
  /// `packInstalled` could only render for a pack this sheet no longer lists, so
  /// keeping them would have been dead code that reads as live coverage — and the
  /// next person to add a state would copy the shape. The claims they made still
  /// exist where they are true: which language is actually previewing is the
  /// status bar's job, and what is installed is the language control's.
  @ViewBuilder
  private func statusCell(_ pack: LivePreviewPack) -> some View {
    if packs.installingTag == pack.tag {
      // A spinner, never a percentage. Apple's progress object yields two
      // distinct values across a whole install, so a bar would be a fabrication.
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text(LivePreviewSettingsCopy.packInstalling).settingsHelperCopy()
      }
    } else {
      // **`.bordered` was the defect, not the size.** On this dark surface AppKit
      // renders a bordered button as a low-contrast grey capsule that is very
      // nearly the app's own disabled treatment — so the one action on every row
      // read as unavailable, and hovering changed nothing to contradict that
      // (founder, 2026-08-26). It was ALSO genuinely disabled whenever any other
      // install was running, which meant "looks disabled" and "is disabled" were
      // indistinguishable at exactly the moment the difference mattered.
      //
      // `SettingsActionButton` carries an accent tint, a hover fill, and a
      // disabled state that is visibly different from both.
      SettingsActionButton(
        title: packs.failedTag == pack.tag
          ? LivePreviewSettingsCopy.packRetry
          : LivePreviewSettingsCopy.packInstall,
        isEnabled: packs.installingTag == nil
      ) {
        packs.install(tag: pack.tag)
      }
    }
  }
}

// MARK: - Catalogue controls

/// The sheet's close control.
///
/// Deliberately a symbol rather than a second worded button: `Done` at the
/// bottom already carries the words, and two worded exits invite the reading
/// that they do different things. Nothing in this sheet is committed on exit,
/// so both simply leave.
private struct CatalogCloseButton: View {
  let action: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(hovering ? Color.stTextPrimary : Color.stTextSecondary)
        .frame(width: 22, height: 22)
        .background(
          Circle().fill(hovering ? Color.stSectionBg : Color.clear)
        )
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
    .accessibilityLabel(LivePreviewSettingsCopy.catalogCloseLabel)
  }
}
