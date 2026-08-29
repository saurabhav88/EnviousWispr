import EnviousWisprCore
import EnviousWisprPostProcessing
import SwiftUI

/// Full-pane editor for one vocabulary pack's word list (#2495). Opens from a
/// pack row's "See all" button, replacing the pack list in `VocabPacksSection`
/// (recorded UI decision on issue #2495: this used to be a small popup — it
/// now fills the same space the pack list sits in, so the per-word toggle,
/// alias editor, and Restore button have room). Every word can be turned off
/// individually, have its spoken variants (aliases) edited, and — once
/// changed — restored back to what the pack shipped.
///
/// File kept under its original name (`VocabularyPackDetailSheet.swift`) so
/// the git history for this feature stays in one file rather than a
/// delete-and-recreate; the type itself is no longer a sheet.
struct VocabularyPackDetailSection: View {
  let id: VocabularyPackID
  let onClose: () -> Void
  @Environment(VocabularyPackManager.self) private var packManager
  @State private var searchQuery: String = ""

  private var words: [VocabularyPackWordDisplay] { packManager.packWords(id) }

  private var filteredWords: [VocabularyPackWordDisplay] {
    let query = searchQuery.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return words }
    return words.filter { word in
      word.canonical.localizedCaseInsensitiveContains(query)
        || word.aliases.contains { $0.localizedCaseInsensitiveContains(query) }
    }
  }

  var body: some View {
    // Computed ONCE per body evaluation. `filteredWords` re-decodes and
    // re-sorts the whole pack (`packManager.packWords(id)`) on every access;
    // reading the computed property three times (emptiness check, ForEach,
    // divider count) tripled that cost per render for no reason.
    let displayedWords = filteredWords

    BrandedSection {
      BrandedRow(showDivider: true) { header }
      BrandedRow(showDivider: true) { searchRow }

      if let persistenceError = packManager.persistenceError {
        BrandedRow(showDivider: true) {
          Label(persistenceError, systemImage: "exclamationmark.triangle.fill")
            .font(.stHelper)
            .foregroundStyle(.stError)
        }
      }

      if displayedWords.isEmpty {
        BrandedRow(showDivider: false) {
          Text(
            searchQuery.isEmpty
              ? "This pack has no words."
              : "No matches for \"\(searchQuery)\"."
          )
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
        }
      } else {
        ForEach(Array(displayedWords.enumerated()), id: \.element.id) { index, word in
          BrandedRow(showDivider: index < displayedWords.count - 1) {
            PackWordRow(packID: id, word: word)
          }
        }
      }
    }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 12) {
      Button(action: onClose) {
        HStack(spacing: 4) {
          Image(systemName: "chevron.left")
            .font(.system(size: 11, weight: .semibold))
          Text("Packs")
        }
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
      }
      .buttonStyle(.plain)
      .settingsHoverQuiet()

      VStack(alignment: .leading, spacing: 2) {
        Text(id.displayName)
          .settingsRowTitle()
        Text("\(packManager.termCount(id)) words")
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
      }

      Spacer(minLength: 8)

      HStack(spacing: 8) {
        Text("Pack on")
          .font(.stHelper)
          .foregroundStyle(.stTextSecondary)
        Toggle(
          "",
          isOn: Binding(
            get: { packManager.isEnabled(id) },
            set: { packManager.setEnabled(id, $0) }
          )
        )
        .toggleStyle(BrandedToggleStyle())
        .labelsHidden()
        .accessibilityLabel("Enable \(id.displayName) pack")
      }
      .fixedSize()

      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 12, weight: .semibold))
          .settingsHoverQuiet()
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Close \(id.displayName) pack")
    }
  }

  private var searchRow: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.stTextSecondary)
        .font(.system(size: 12))
      TextField("Search \(id.displayName) words", text: $searchQuery)
        .textFieldStyle(.plain)
      if !searchQuery.isEmpty {
        Button {
          searchQuery = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.stTextSecondary)
            .font(.system(size: 12))
            .settingsHoverQuiet()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
      }
    }
  }
}

/// One pack word's row: name, an EDITED badge once it differs from shipped,
/// its alias chips (removable) plus an add-alias field, a per-word on/off
/// toggle, and — only once edited — a Restore button.
private struct PackWordRow: View {
  let packID: VocabularyPackID
  let word: VocabularyPackWordDisplay
  @Environment(VocabularyPackManager.self) private var packManager
  @State private var newAlias: String = ""

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 12) {
        info
        Spacer(minLength: 8)
        controls
      }
      VStack(alignment: .leading, spacing: 8) {
        info
        controls
      }
    }
    .opacity(word.isEnabled ? 1 : 0.5)
  }

  private var info: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Text(word.canonical)
          .settingsRowLabel()
        if word.isEdited {
          Text("EDITED")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.stWarning)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.stWarningSoft, in: Capsule())
        }
      }
      aliasChips
      addAliasRow
    }
  }

  private var controls: some View {
    HStack(spacing: 10) {
      if word.isEdited {
        SettingsActionButton(title: "Restore", isEnabled: true) {
          packManager.restoreWord(packID, canonical: word.canonical)
        }
      }
      Toggle(
        "",
        isOn: Binding(
          get: { word.isEnabled },
          set: { packManager.setWordEnabled(packID, canonical: word.canonical, enabled: $0) }
        )
      )
      .toggleStyle(BrandedToggleStyle())
      .labelsHidden()
      // BrandedToggleStyle's internal Spacer otherwise claims whatever width
      // this row hands it — with an empty label there is nothing to push
      // against, so the whole row's blank space becomes clickable.
      .fixedSize()
      .accessibilityLabel("Enable \(word.canonical)")
    }
  }

  private var sortedAliases: [String] {
    word.aliases.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
  }

  @ViewBuilder
  private var aliasChips: some View {
    if word.aliases.isEmpty {
      Text("No spoken variants")
        .font(.stHelper)
        .foregroundStyle(.stTextSecondary)
    } else {
      WrappingHStack(spacing: 6) {
        ForEach(sortedAliases, id: \.self) { alias in
          HStack(spacing: 3) {
            Text(alias)
              .font(.stHelper)
              .fixedSize(horizontal: false, vertical: true)
            Button {
              removeAlias(alias)
            } label: {
              Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .settingsHoverQuiet(inset: 2, tint: .stError)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel("Remove alias \(alias)")
          }
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
          .background(Color.stAccentLight)
          .clipShape(RoundedRectangle(cornerRadius: 4))
        }
      }
    }
  }

  private var addAliasRow: some View {
    HStack(spacing: 6) {
      TextField("Add alias (e.g. a mishearing you've noticed)", text: $newAlias)
        .textFieldStyle(.plain)
        .font(.stHelper)
        .onSubmit(addAlias)
      SettingsActionButton(
        title: "Add", isEnabled: !newAlias.trimmingCharacters(in: .whitespaces).isEmpty
      ) {
        addAlias()
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(Color.stPageBg)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(Color.stDivider, lineWidth: 1)
    )
  }

  private func addAlias() {
    let trimmed = newAlias.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    guard !word.aliases.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
    else {
      newAlias = ""
      return
    }
    packManager.setWordAliases(packID, canonical: word.canonical, aliases: word.aliases + [trimmed])
    newAlias = ""
  }

  private func removeAlias(_ alias: String) {
    var next = word.aliases
    next.removeAll { $0 == alias }
    packManager.setWordAliases(packID, canonical: word.canonical, aliases: next)
  }
}
