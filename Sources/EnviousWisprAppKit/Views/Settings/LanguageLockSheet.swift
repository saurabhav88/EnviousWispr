import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// Modal sheet that lets users pin the active engine to a specific language.
///
/// Surfaces the engine's supported languages with a search field and an
/// optional "Recent" section driven by the persisted `SessionLanguageMemory`
/// usage cache. Tapping a language row sets `languageMode = .locked(code)`; the
/// Auto row above them sets `.auto`, so the sheet can both set and clear a lock.
/// Either way it dismisses. The sheet is a settings detail, never an interrupt: nothing
/// here blocks dictation.
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

  init(lockableCodes: Set<String>? = nil, contextSubtitle: String? = nil) {
    self.lockableCodes = lockableCodes
    self.contextSubtitle = contextSubtitle
  }

  @State private var searchText: String = ""

  /// Recents are loaded once when the sheet appears. We intentionally do not
  /// observe UserDefaults live: the sheet lifetime is short and W2 owns the
  /// persistence contract.
  @State private var recents: [LanguageCatalog.Entry] = []

  private let maxRecents = 5

  var body: some View {
    // **Same chrome as `LivePreviewPackCatalogSheet`, for the same reason.**
    // `.navigationTitle` renders through AppKit's title chrome, whose inset this
    // sheet does not control — measured here at ~178pt from the sheet edge while
    // the body copy under it started at ~115pt, so the title read as belonging to
    // a different container (founder, 2026-08-26, on both sheets independently).
    // One shared inset makes them line up by construction.
    VStack(spacing: 0) {
      titleBar
      Divider().overlay(Color.stDivider)

      VStack(alignment: .leading, spacing: 12) {
        if let contextSubtitle {
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
          if searchText.isEmpty {
            autoDetectSection
          }
          if !recents.isEmpty && searchText.isEmpty {
            recentSection
          }
          allLanguagesSection
        }
        .padding(.horizontal, Self.inset)
        .padding(.vertical, 12)
      }

      Divider().overlay(Color.stDivider)
      footer
    }
    .background(Color.stPageBg)
    .frame(minWidth: 420, minHeight: 520)
    .onAppear(perform: loadRecents)
  }

  /// One inset shared by the title, the header and the list beneath them.
  private static let inset: CGFloat = 16

  // "Lock language" while the first row CLEARS the lock is the sheet
  // contradicting itself, the same defect r8 and r9 fixed on the page that
  // opens it. This title is true of both actions and of both presenters —
  // and it matches the Change button's copy, which already says out loud
  // that this sets the DICTATION language, not a preview-only one.
  private var titleBar: some View {
    HStack(spacing: 8) {
      Text("Dictation language")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(Color.stTextPrimary)
      Spacer(minLength: 12)
      SettingsSheetCloseButton(accessibilityTitle: "Close") { dismiss() }
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
  private var autoDetectSection: some View {
    let isAuto: Bool = {
      if case .auto = settings.languageMode { return true }
      return false
    }()

    VStack(alignment: .leading, spacing: 6) {
      Text("Automatic")
        .font(.stSectionHeader)
        .foregroundStyle(.stTextSecondary)

      VStack(spacing: 0) {
        Button {
          selectAuto()
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
        .accessibilityValue(isAuto ? "selected" : "")
      }
      .background(Color.stSectionBg)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
  }

  @ViewBuilder
  private var recentSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("RECENT")
        .font(.stSectionHeader)
        .foregroundStyle(.stTextSecondary)
        .padding(.leading, 4)

      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(recents.enumerated()), id: \.element.code) { index, entry in
          languageRow(entry, showDivider: index < recents.count - 1)
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
  private var allLanguagesSection: some View {
    let filtered = filteredLanguages

    VStack(alignment: .leading, spacing: 6) {
      // **`ALL LANGUAGES` was a claim wider than the list.** Opened from Live
      // Preview this sheet shows only the languages installed AND lockable — on a
      // stock Mac, one — under a heading saying all, so the app appeared to speak
      // one language (#2443). The caller knows whether its list is complete;
      // `lockableCodes == nil` is exactly "no filter applied".
      Text(lockableCodes == nil ? "ALL LANGUAGES" : "AVAILABLE ON THIS MAC")
        .font(.stSectionHeader)
        .foregroundStyle(.stTextSecondary)
        .padding(.leading, 4)

      if filtered.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          HStack {
            Text("No language matches your search.")
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
          ForEach(Array(filtered.enumerated()), id: \.element.code) { index, entry in
            languageRow(entry, showDivider: index < filtered.count - 1)
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
  private func languageRow(_ entry: LanguageCatalog.Entry, showDivider: Bool) -> some View {
    VStack(spacing: 0) {
      // **Hover is what makes a row read as a row you can press.** These are the
      // only way to choose a language and nothing changed under the pointer, so
      // the list looked like a table of facts ("hovering over the languages
      // doesn't highlight so it doesn't feel like it's clickable", founder).
      // Extracted into a type because a hover needs its own `@State`, which a
      // `@ViewBuilder` function cannot hold.
      LanguageLockRow(
        entry: entry,
        isSelected: isCurrentLock(entry.code)
      ) {
        select(entry)
      }

      if showDivider {
        Divider()
          .overlay(Color.stDivider)
          .padding(.leading, 14)
      }
    }
  }

  // MARK: - Filtering

  /// The engine's offerable languages. Applied BEFORE the search filter so a
  /// search can never surface a language the active engine cannot honour.
  private var lockableLanguages: [LanguageCatalog.Entry] {
    guard let lockableCodes else { return LanguageCatalog.sortedByEnglishName }
    return LanguageCatalog.sortedByEnglishName.filter { lockableCodes.contains($0.code) }
  }

  private var filteredLanguages: [LanguageCatalog.Entry] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else { return lockableLanguages }
    return lockableLanguages.filter { entry in
      entry.englishName.lowercased().contains(query)
        || entry.nativeName.lowercased().contains(query)
        || entry.code.lowercased().contains(query)
    }
  }

  // MARK: - Actions

  private func select(_ entry: LanguageCatalog.Entry) {
    apply(.locked(entry.code))
  }

  /// The way back out of a lock. Same path as `select(_:)` so the two can never
  /// report differently.
  private func selectAuto() {
    apply(.auto)
  }

  /// Reads the telemetry decision BEFORE mutating settings, because both fields
  /// describe a transition and the prior value is gone afterwards.
  private func apply(_ next: LanguageMode) {
    let event = LanguageLockOptions.lockTelemetry(from: settings.languageMode, to: next)
    settings.languageMode = next
    TelemetryService.shared.trackManualLockUsed(
      fromLang: event.fromLang,
      toLang: event.toLang,
      reason: event.reason
    )
    dismiss()
  }

  private func isCurrentLock(_ code: String) -> Bool {
    if case .locked(let current) = settings.languageMode {
      return current == code
    }
    return false
  }

  // MARK: - Recents

  /// Reads `SessionLanguageMemory.usage24h` from UserDefaults (written by
  /// the detector stack in W2), sorts by `lastSeen` desc, and maps to
  /// catalog entries. Silently drops unknown codes. Hides the section if
  /// empty (does not show an empty state).
  private func loadRecents() {
    let key = SessionLanguageMemory.userDefaultsKey
    guard let data = UserDefaults.standard.data(forKey: key),
      let memory = try? JSONDecoder().decode(SessionLanguageMemory.self, from: data)
    else {
      recents = []
      return
    }

    // Honor the 24-hour TTL on SessionLanguageMemory.usage24h here in the
    // UI layer too, so a user who opens Settings after a day without
    // dictating does not see stale "Recent" langs. The detector's own
    // pruneExpiredUsage only runs when the detector does; this keeps the
    // UI consistent with the cache's expiration contract.
    let now = Date()
    let ttl = SessionLanguageMemory.usageCacheTTL
    let sorted = memory.usage24h
      .filter { now.timeIntervalSince($0.value.lastSeen) <= ttl }
      .sorted { $0.value.lastSeen > $1.value.lastSeen }
      // #1678: the engine restriction applies BEFORE the recency cap, not after.
      // Recents are cross-engine — a user who dictated Japanese on the
      // multilingual engine and then switched engines would otherwise be offered
      // Japanese here, which the fast engine cannot honour. Filtering after
      // `prefix` would also silently shorten the list instead of showing the
      // next eligible language.
      .filter { lockableCodes?.contains($0.key) ?? true }
      .prefix(maxRecents)
      .compactMap { pair -> LanguageCatalog.Entry? in
        guard LanguageTypes.isSupported(pair.key) else { return nil }
        return LanguageCatalog.entry(for: pair.key)
      }

    recents = Array(sorted)
  }
}

// MARK: - Row

/// One selectable language.
///
/// A `View` rather than a builder function purely so it can own the hover state;
/// selection still lives with the caller, which is the only thing that knows what
/// is currently locked.
private struct LanguageLockRow: View {
  let entry: LanguageCatalog.Entry
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text(entry.nativeName).settingsRowLabel()
          Text("\(entry.englishName) · \(entry.code)")
            .font(.stHelper)
            .foregroundStyle(.stTextSecondary)
        }
        Spacer()
        if isSelected {
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
      .background(isSelected ? Color.stAccent.opacity(0.10) : Color.clear)
      .settingsHoverRow(cornerRadius: 0)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(entry.englishName), native \(entry.nativeName)")
    .accessibilityValue(isSelected ? "selected" : "")
  }
}

// The close control this file used to declare is now
// `SettingsSheetCloseButton` in `SettingsComponents.swift`, shared with
// `LivePreviewPackCatalogSheet`, which held a byte-identical copy.
