import EnviousWisprCore
import EnviousWisprServices
import SwiftUI

/// Modal sheet that lets users pin WhisperKit to a specific language.
///
/// Surfaces all 99 Whisper-supported languages with a search field and an
/// optional "Recent" section driven by the persisted `SessionLanguageMemory`
/// usage cache. Tapping a row sets `languageMode = .locked(code)` and
/// dismisses. The sheet is a settings detail, never an interrupt: nothing
/// here blocks dictation.
struct LanguageLockSheet: View {
  @Environment(SettingsManager.self) private var settings
  @Environment(\.dismiss) private var dismiss

  @State private var searchText: String = ""

  /// Recents are loaded once when the sheet appears. We intentionally do not
  /// observe UserDefaults live: the sheet lifetime is short and W2 owns the
  /// persistence contract.
  @State private var recents: [LanguageCatalog.Entry] = []

  private let maxRecents = 5

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        searchField

        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            if !recents.isEmpty && searchText.isEmpty {
              recentSection
            }
            allLanguagesSection
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 12)
        }
      }
      .background(Color.stPageBg)
      .navigationTitle("Lock language")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
    .frame(minWidth: 420, minHeight: 520)
    .onAppear(perform: loadRecents)
  }

  // MARK: - Subviews

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.stTextTertiary)
      TextField("Search by name or code", text: $searchText)
        .textFieldStyle(.plain)
        .accessibilityLabel("Search languages")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color.stSectionBg)
    .overlay(
      Rectangle()
        .fill(Color.stDivider)
        .frame(height: 1),
      alignment: .bottom
    )
  }

  @ViewBuilder
  private var recentSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("RECENT")
        .font(.stSectionHeader)
        .foregroundStyle(.stTextTertiary)
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
      Text("ALL LANGUAGES")
        .font(.stSectionHeader)
        .foregroundStyle(.stTextTertiary)
        .padding(.leading, 4)

      if filtered.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          HStack {
            Text("No language matches your search.")
              .font(.stHelper)
              .foregroundStyle(.stTextTertiary)
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
    let isSelected = isCurrentLock(entry.code)

    VStack(spacing: 0) {
      Button {
        select(entry)
      } label: {
        HStack(spacing: 10) {
          VStack(alignment: .leading, spacing: 2) {
            Text(entry.nativeName)
              .font(.system(size: 13, weight: .medium))
              .foregroundStyle(.primary)
            Text("\(entry.englishName) · \(entry.code)")
              .font(.system(size: 11))
              .foregroundStyle(.stTextTertiary)
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
        .contentShape(Rectangle())
        .background(isSelected ? Color.stAccent.opacity(0.06) : Color.clear)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("\(entry.englishName), native \(entry.nativeName)")
      .accessibilityValue(isSelected ? "selected" : "")

      if showDivider {
        Divider()
          .overlay(Color.stDivider)
          .padding(.leading, 14)
      }
    }
  }

  // MARK: - Filtering

  private var filteredLanguages: [LanguageCatalog.Entry] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else { return LanguageCatalog.sortedByEnglishName }
    return LanguageCatalog.sortedByEnglishName.filter { entry in
      entry.englishName.lowercased().contains(query)
        || entry.nativeName.lowercased().contains(query)
        || entry.code.lowercased().contains(query)
    }
  }

  // MARK: - Actions

  private func select(_ entry: LanguageCatalog.Entry) {
    // W6 telemetry: record the mode transition before we mutate settings so
    // we can read the prior value for `from_lang`.
    let fromLang: String
    switch settings.languageMode {
    case .auto:
      fromLang = "auto"
    case .locked(let prior):
      fromLang = prior
    }
    // Reason classification: the sheet only distinguishes "first_time" (never
    // locked before) from "preference" (user actively changing a lock). The
    // "after_bad_detect" path is reserved for the passive-chip CTA (future
    // hook) so we do not mis-label a Settings-driven change.
    let reason: String
    if case .auto = settings.languageMode {
      reason = "first_time"
    } else {
      reason = "preference"
    }

    settings.languageMode = .locked(entry.code)
    TelemetryService.shared.trackManualLockUsed(
      fromLang: fromLang,
      toLang: entry.code,
      reason: reason
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
      .prefix(maxRecents)
      .compactMap { pair -> LanguageCatalog.Entry? in
        guard LanguageTypes.isSupported(pair.key) else { return nil }
        return LanguageCatalog.entry(for: pair.key)
      }

    recents = Array(sorted)
  }
}
