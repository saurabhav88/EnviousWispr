import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// Modal sheet that lets users pin the active engine to a specific language.
///
/// Surfaces the engine's supported languages with a search field and an
/// optional "Recent" section driven by the persisted `SessionLanguageMemory`
/// usage cache. Tapping a row sets `languageMode = .locked(lockCode)` (and, for the two
/// English rows, the English spelling first, #3124); the
/// Auto row above them sets `.auto`, so the sheet can both set and clear a lock.
/// Either way it dismisses. The sheet is a settings detail, never an interrupt: nothing
/// here blocks dictation.
///
/// #4320: the sheet renders only from a `LanguagePickerContent`. The dictation initializer
/// builds today's content (`LanguagePickerContent.dictation`); `init(content:)` takes a
/// caller's own rows and actions (EnviousMeet's Live Preview and transcript languages), which
/// write only the caller's setting: no dictation write, recents or lock telemetry.
struct LanguageLockSheet: View {
  @Environment(SettingsManager.self) private var settings
  @Environment(\.dismiss) private var dismiss

  /// Codes this engine may be locked to, or nil for "no restriction" (the
  /// multilingual engine's full catalogue).
  ///
  /// #1678: the fast engine claims 25 European languages, so the sheet must not
  /// offer the rest. A code outside the engine's set is a SILENT failure — it
  /// maps to no vendor language, the decoder falls back to auto-detect, and the
  /// user sees a lock they set and are not getting. Filtering the list is what
  /// makes the setting mean what it says.
  let lockableCodes: Set<String>?

  /// One line of caller context under the title, or nil for none (#2436).
  ///
  /// Live Preview passes the dictation caveat; the Transcription page passes
  /// nothing and is unchanged by construction, since the parameter is defaulted.
  /// The sentence lives HERE rather than beside the button that opens this sheet
  /// because it states a consequence of the action, and a consequence belongs at
  /// the moment it becomes true.
  let contextSubtitle: String?

  /// #3124: false only when the caller's list must name what runs RIGHT NOW and English (UK)
  /// cannot (`LanguageLockOptions.previewOffersEnglishUK`). The Transcription page passes nothing.
  let offersEnglishUK: Bool

  /// #4320: a caller's own content, built during rendering from the current search, so it
  /// follows the caller's live state. `dismiss` closes this window; call it after a choice.
  typealias ContentBuilder =
    @MainActor (_ query: String, _ dismiss: @escaping @MainActor () -> Void) ->
    LanguagePickerContent

  /// nil for the dictation window.
  private let customContent: ContentBuilder?

  init(
    lockableCodes: Set<String>? = nil, contextSubtitle: String? = nil, offersEnglishUK: Bool = true
  ) {
    self.lockableCodes = lockableCodes
    self.contextSubtitle = contextSubtitle
    self.offersEnglishUK = offersEnglishUK
    self.customContent = nil
  }

  /// #4320: a window over a caller's own rows and actions.
  init(content: @escaping ContentBuilder) {
    self.lockableCodes = nil
    self.contextSubtitle = nil
    self.offersEnglishUK = true
    self.customContent = content
  }

  /// What this render shows. Resolved here, after environment injection, never frozen at init.
  private var content: LanguagePickerContent {
    let close: @MainActor () -> Void = { dismiss() }
    if let customContent { return customContent(searchText, close) }
    return LanguagePickerContent.dictation(
      mode: settings.languageMode, stored: settings.englishSpelling,
      lockableCodes: lockableCodes, contextSubtitle: contextSubtitle,
      offersEnglishUK: offersEnglishUK, query: searchText, recents: recents
    ) { entry in
      LanguagePickerContent.commitDictation(
        entry, to: settings,
        track: { from, to, reason in
          TelemetryService.shared.trackManualLockUsed(fromLang: from, toLang: to, reason: reason)
        },
        dismiss: close)
    }
  }

  @State private var searchText: String = ""

  /// Recents are loaded once when the sheet appears. We intentionally do not
  /// observe UserDefaults live: the sheet lifetime is short and W2 owns the
  /// persistence contract.
  @State private var recents: [LanguageCatalog.Entry] = []

  private let maxRecents = 5

  var body: some View {
    let content = content
    // **Same chrome as `LivePreviewPackCatalogSheet`, for the same reason.**
    // `.navigationTitle` renders through AppKit's title chrome, whose inset this
    // sheet does not control — measured here at ~178pt from the sheet edge while
    // the body copy under it started at ~115pt, so the title read as belonging to
    // a different container (founder, 2026-08-26, on both sheets independently).
    // One shared inset makes them line up by construction.
    VStack(spacing: 0) {
      titleBar(content.title)
      Divider().overlay(Color.stDivider)

      VStack(alignment: .leading, spacing: 12) {
        if let contextSubtitle = content.contextSubtitle {
          // **Reading copy, not microcopy.** This was `stHelper`, the app's
          // smallest token, on the one sentence explaining that the choice reaches
          // dictation and not only the preview — "too wordy and too small to read"
          // (founder). The words are shorter now and the type is the reading size.
          Text(contextSubtitle).settingsReadingCopy()
        }
        searchField
      }
      .padding(Self.inset)

      Divider().overlay(Color.stDivider)

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if searchText.isEmpty, let autoRow = content.autoRow {
            autoDetectSection(autoRow)
          }
          if !content.recents.isEmpty && searchText.isEmpty {
            recentSection(content.recents)
          }
          allLanguagesSection(content)
        }
        .padding(.horizontal, Self.inset)
        .padding(.vertical, 12)
      }

      Divider().overlay(Color.stDivider)
      footer
    }
    .background(Color.stPageBg)
    .frame(minWidth: 420, minHeight: 520)
    .onAppear {
      // Recents are loaded once when the sheet appears, and only for the dictation window.
      if customContent == nil { loadRecents() }
    }
  }

  /// One inset shared by the title, the header and the list beneath them.
  private static let inset: CGFloat = 16

  /// The title comes from the content (the dictation title's reasons live with
  /// `LanguagePickerContent.dictation`).
  private func titleBar(_ title: String) -> some View {
    HStack(spacing: 8) {
      Text(title)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(Color.stTextPrimary)
      Spacer(minLength: 12)
      SettingsSheetCloseButton(
        accessibilityTitle: String(
          localized: "Close",
          comment: "Dictation language picker: VoiceOver name of the close button.")
      ) { dismiss() }
    }
    .padding(.horizontal, Self.inset)
    .padding(.vertical, 12)
  }

  /// `Cancel`, not `Done`: this sheet COMMITS on row selection, so the bottom
  /// action is an abandon rather than a confirm. Kept alongside the close control
  /// because the word is what says nothing was changed.
  private var footer: some View {
    HStack {
      Spacer(minLength: 0)
      // **Outlined, not filled, and not a bare accent word.** The catalogue
      // sheet's `Done` became a filled primary and this was left as coloured
      // text — one sheet's exit polished, its twin untouched, in the same change
      // (founder, 2026-08-26). Same control now, one emphasis lower: leaving
      // WITHOUT choosing is a secondary action here, because the rows are the
      // primary one. `Done` on the catalogue sheet is filled because nothing
      // competes with it there.
      SettingsActionButton(title: "Cancel", isEnabled: true, shortcut: .cancelAction) {
        dismiss()
      }
    }
    .padding(.horizontal, Self.inset)
    .padding(.vertical, 12)
  }

  // MARK: - Subviews

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.stTextSecondary)
      TextField("Search by name or code", text: $searchText)
        .textFieldStyle(.plain)
        .accessibilityLabel("Search languages")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    // **Was full-bleed with an underline**, which put it flush against the
    // sentence above with no gap and made it read as part of that paragraph
    // rather than as a control ("placement and size feels weird", founder).
    // Same recessed bordered field the catalogue sheet uses: one idiom for one
    // job, across both language sheets.
    .background(Color.stSectionBg, in: RoundedRectangle(cornerRadius: 9))
    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.stDivider, lineWidth: 1))
  }

  /// **The way BACK. Without it this sheet is a one-way door.**
  ///
  /// Cloud review r11: #2154 put a Change button on the Live Preview page that
  /// opens this sheet, and every row here assigns `.locked(code)`. So a user on
  /// Auto could lock a language from that page and had no way to undo it there —
  /// the only Auto control lives on the Transcription page as a separate toggle,
  /// which is a different page they have no reason to look at. An affordance that
  /// can set a state and not clear it is worse than no affordance, because it
  /// strands the people who trusted it.
  ///
  /// Placed FIRST rather than in the list: it is not a language, and sorting it
  /// among them would hide the escape route in a long scroll. Hidden while
  /// searching for the same reason recents are — typing means looking for a
  /// specific language.
  @ViewBuilder
  private func autoDetectSection(_ autoRow: LanguagePickerAutoRow) -> some View {
    let isAuto = autoRow.isSelected

    VStack(alignment: .leading, spacing: 6) {
      Text("Automatic")
        .font(.stSectionHeader)
        .foregroundStyle(.stTextSecondary)

      VStack(spacing: 0) {
        Button {
          autoRow.action()
        } label: {
          HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
              Text("Auto-detect language")
                .settingsRowLabel()
              Text("Work out the language from what you say.")
                .font(.stHelper)
                .foregroundStyle(.stTextSecondary)
            }
            Spacer()
            if isAuto {
              Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.stAccent)
            }
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          // The TWIN of `LanguageLockRow`, and it was drifting from it in two
          // ways at once. Live UAT caught the first: every language row beneath
          // this one lit up under the pointer and this one did not, on the first
          // row of the list. The second was only visible once both were read
          // together -- the selected wash here was 0.06 against the rows' 0.10,
          // so "this is the current choice" was drawn two different strengths
          // depending on which kind of choice it was.
          .background(isAuto ? Color.stAccent.opacity(0.10) : Color.clear)
          .settingsHoverRow(cornerRadius: 0)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Auto-detect language")
        .accessibilityValue(
          isAuto
            ? String(
              localized: "selected",
              comment:
                "VoiceOver: a chosen segmented option; here, the Auto-detect row of the dictation language picker."
            )
            : "")
      }
      .background(Color.stSectionBg)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
  }

  @ViewBuilder
  private func recentSection(_ recents: [LanguagePickerRow]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("RECENT")
        .font(.stSectionHeader)
        .foregroundStyle(.stTextSecondary)
        .padding(.leading, 4)

      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(recents.enumerated()), id: \.element.id) { index, row in
          languageRow(row, showDivider: index < recents.count - 1)
        }
      }
      .background(Color.stSectionBg)
      .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius))
      .overlay(
        RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius)
          .strokeBorder(Color.stDivider, lineWidth: 1)
      )
    }
  }

  @ViewBuilder
  private func allLanguagesSection(_ content: LanguagePickerContent) -> some View {
    let filtered = content.rows

    VStack(alignment: .leading, spacing: 6) {
      // The heading comes from the content (the dictation heading's reasons, #2443, live with
      // `LanguagePickerContent.dictation`).
      Text(content.heading)
        .font(.stSectionHeader)
        .foregroundStyle(.stTextSecondary)
        .padding(.leading, 4)

      if filtered.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          HStack {
            Text(content.emptySearchText)
              .font(.stHelper)
              .foregroundStyle(.stTextSecondary)
            Spacer()
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 16)
        }
        .background(Color.stSectionBg)
        .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius))
        .overlay(
          RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius)
            .strokeBorder(Color.stDivider, lineWidth: 1)
        )
      } else {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(filtered.enumerated()), id: \.element.id) { index, row in
            languageRow(row, showDivider: index < filtered.count - 1)
          }
        }
        .background(Color.stSectionBg)
        .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius))
        .overlay(
          RoundedRectangle(cornerRadius: SettingsLayout.sectionRadius)
            .strokeBorder(Color.stDivider, lineWidth: 1)
        )
      }
    }
  }

  @ViewBuilder
  private func languageRow(_ row: LanguagePickerRow, showDivider: Bool) -> some View {
    VStack(spacing: 0) {
      // **Hover is what makes a row read as a row you can press.** These are the
      // only way to choose a language and nothing changed under the pointer, so
      // the list looked like a table of facts ("hovering over the languages
      // doesn't highlight so it doesn't feel like it's clickable", founder).
      // Extracted into a type because a hover needs its own `@State`, which a
      // `@ViewBuilder` function cannot hold.
      LanguageLockRow(row: row)

      if showDivider {
        Divider()
          .overlay(Color.stDivider)
          .padding(.leading, 14)
      }
    }
  }

  // MARK: - Recents

  /// Reads `SessionLanguageMemory.usage24h` from UserDefaults; the TTL, ordering, engine
  /// restriction and spelling rules live in `LanguagePickerContent.dictationRecents`.
  private func loadRecents() {
    recents = LanguagePickerContent.dictationRecents(
      memoryData: UserDefaults.standard.data(forKey: SessionLanguageMemory.userDefaultsKey),
      now: Date(), lockableCodes: lockableCodes, stored: settings.englishSpelling,
      offersEnglishUK: offersEnglishUK, maxRecents: maxRecents)
  }
}

// MARK: - Row

/// One selectable language.
///
/// A `View` rather than a builder function purely so it can own the hover state;
/// selection still lives with the caller, which is the only thing that knows what
/// is currently locked.
private struct LanguageLockRow: View {
  let row: LanguagePickerRow

  var body: some View {
    Button(action: row.action) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text(row.nativeName).settingsRowLabel()
          Text(row.subtitle)
            .font(.stHelper)
            .foregroundStyle(.stTextSecondary)
        }
        Spacer()
        if row.isSelected {
          Image(systemName: "checkmark")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.stAccent)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      // Selection outranks hover: a selected row keeps its accent wash even while
      // the pointer sits on a neighbour, so the current choice never disappears.
      // The hover tint composites ON TOP of that wash rather than replacing it,
      // so the selected row under the pointer reads as both.
      .background(row.isSelected ? Color.stAccent.opacity(0.10) : Color.clear)
      .settingsHoverRow(cornerRadius: 0)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    // #3124: the two English rows differ only by spelling, so VoiceOver says which
    // (`LanguagePickerContent.accessibilityLabel(for:)`).
    .accessibilityLabel(row.accessibilityLabel)
    .accessibilityValue(
      row.isSelected
        ? String(
          localized: "selected", comment: "Dictation language picker, VoiceOver: the chosen row.")
        : "")
  }
}

// The close control this file used to declare is now
// `SettingsSheetCloseButton` in `SettingsComponents.swift`, shared with
// `LivePreviewPackCatalogSheet`, which held a byte-identical copy.
