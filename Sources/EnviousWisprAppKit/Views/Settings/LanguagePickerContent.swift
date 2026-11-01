import EnviousWisprCore
import EnviousWisprServices
import Foundation

/// #4320: what `LanguageLockSheet` shows and what each row does. The sheet renders only from this
/// value, so the same window serves dictation (`dictation(...)`, today's behaviour) and callers
/// that own a different setting (EnviousMeet's Live Preview and transcript languages), which
/// supply their own rows and actions.
struct LanguagePickerContent {
  var title: String
  /// One line of caller context under the title, or nil for none (#2436).
  var contextSubtitle: String?
  /// The Automatic row, or nil when the caller has no Auto choice in this window.
  var autoRow: LanguagePickerAutoRow?
  /// The Recent rows, already capped; empty hides the section.
  var recents: [LanguagePickerRow]
  /// The heading over the main list.
  var heading: String
  /// The text shown when the search matches nothing.
  var emptySearchText: String
  /// The main list, already filtered by the current search.
  var rows: [LanguagePickerRow]
}

/// One selectable language.
struct LanguagePickerRow: Identifiable {
  /// Stable row identity (the catalog row code for dictation, so the two English rows differ).
  let id: String
  /// The code a choice of this row writes (an exact tag such as `en-US` for Apple's engine).
  let code: String
  let nativeName: String
  let englishName: String
  /// The name in the interface language.
  let displayName: String
  let subtitle: String
  let isSelected: Bool
  let accessibilityLabel: String
  let action: @MainActor () -> Void
}

/// The Automatic row: whether Auto is the current choice, and what choosing it does.
struct LanguagePickerAutoRow {
  let isSelected: Bool
  let action: @MainActor () -> Void
}

// MARK: - Dictation

extension LanguagePickerContent {
  /// The dictation language window, exactly as it was before #4320: rows from
  /// `LanguageLockOptions.pickerRows` (the one owner of which rows the engine can honour and which
  /// match the search), selection from the stored mode and spelling, and every choice, Auto
  /// included, through `select` (nil is Auto).
  @MainActor
  static func dictation(
    mode: LanguageMode,
    stored: EnglishSpelling,
    lockableCodes: Set<String>?,
    contextSubtitle: String?,
    offersEnglishUK: Bool,
    query: String,
    recents: [LanguageCatalog.Entry],
    select: @escaping @MainActor (LanguageCatalog.Entry?) -> Void
  ) -> LanguagePickerContent {
    let isAuto: Bool = {
      if case .auto = mode { return true }
      return false
    }()
    func row(_ entry: LanguageCatalog.Entry) -> LanguagePickerRow {
      dictationRow(
        entry,
        isSelected: LanguageLockOptions.isSelected(entry, mode: mode, stored: stored)
      ) { select(entry) }
    }
    return LanguagePickerContent(
      // "Lock language" while the first row CLEARS the lock is the sheet
      // contradicting itself, the same defect r8 and r9 fixed on the page that
      // opens it. This title is true of both actions and of both presenters —
      // and it matches the Change button's copy, which already says out loud
      // that this sets the DICTATION language, not a preview-only one.
      title: String(localized: "Dictation language"),
      contextSubtitle: contextSubtitle,
      autoRow: LanguagePickerAutoRow(isSelected: isAuto) { select(nil) },
      recents: recents.map(row),
      // **`ALL LANGUAGES` was a claim wider than the list.** Opened from Live
      // Preview this sheet shows only the languages installed AND lockable — on a
      // stock Mac, one — under a heading saying all, so the app appeared to speak
      // one language (#2443). The caller knows whether its list is complete;
      // `lockableCodes == nil` is exactly "no filter applied".
      heading: lockableCodes == nil
        ? String(localized: "ALL LANGUAGES") : String(localized: "AVAILABLE ON THIS MAC"),
      emptySearchText: String(localized: "No language matches your search."),
      rows: LanguageLockOptions.pickerRows(
        lockableCodes: lockableCodes, query: query, offersEnglishUK: offersEnglishUK
      ).map(row))
  }

  /// A dictation row from a catalog entry.
  static func dictationRow(
    _ entry: LanguageCatalog.Entry, isSelected: Bool,
    action: @escaping @MainActor () -> Void
  ) -> LanguagePickerRow {
    LanguagePickerRow(
      id: entry.code, code: entry.lockCode, nativeName: entry.nativeName,
      englishName: entry.englishName, displayName: entry.displayName,
      subtitle: LanguageCatalog.pickerSubtitle(for: entry), isSelected: isSelected,
      accessibilityLabel: accessibilityLabel(for: entry), action: action)
  }

  /// #3124: the two English rows differ only by spelling, so VoiceOver says which.
  static func accessibilityLabel(for entry: LanguageCatalog.Entry) -> String {
    entry.spelling == nil
      ? String(
        localized: "\(entry.displayName), native \(entry.nativeName)",
        comment:
          "Dictation language picker, VoiceOver: a language row. The first %@ is the language's name, the second its name in its own language."
      )
      : String(
        localized: "language.picker.spellingAccessibility",
        defaultValue: "\(entry.displayName), \(LanguageCatalog.pickerSubtitle(for: entry))",
        comment:
          "Dictation language picker, VoiceOver: an English spelling row. The first %@ is the row's name, the second says which spelling it uses."
      )
  }

  /// The Recent entries: `SessionLanguageMemory.usage24h` (written by the detector stack in W2),
  /// newest first, mapped to catalog rows. Silently drops unknown codes. nil or undecodable data
  /// gives none (the section hides; there is no empty state).
  static func dictationRecents(
    memoryData: Data?,
    now: Date,
    lockableCodes: Set<String>?,
    stored: EnglishSpelling,
    offersEnglishUK: Bool,
    maxRecents: Int = 5
  ) -> [LanguageCatalog.Entry] {
    guard let memoryData,
      let memory = try? JSONDecoder().decode(SessionLanguageMemory.self, from: memoryData)
    else { return [] }

    // Honor the 24-hour TTL on SessionLanguageMemory.usage24h here in the
    // UI layer too, so a user who opens Settings after a day without
    // dictating does not see stale "Recent" langs. The detector's own
    // pruneExpiredUsage only runs when the detector does; this keeps the
    // UI consistent with the cache's expiration contract.
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
      .filter { LanguageLockOptions.isLockHonoured($0.key, in: lockableCodes) }
      .prefix(maxRecents)
      .compactMap { pair -> LanguageCatalog.Entry? in
        guard LanguageTypes.isSupported(pair.key) else { return nil }
        // #3124: a recent "en" is shown as the English the user has chosen, and only as a row
        // this sheet is allowed to offer.
        return LanguageLockOptions.recentRow(
          code: pair.key, stored: stored, offersEnglishUK: offersEnglishUK)
      }
    return Array(sorted)
  }

  /// One owner for the dictation write order and the telemetry decision
  /// (`LanguageLockOptions.apply`): the event is read before any mutation, and
  /// the spelling is written before the lock (#3124); then the event is reported,
  /// then the window closes. nil is Auto.
  @MainActor
  static func commitDictation(
    _ entry: LanguageCatalog.Entry?,
    to settings: SettingsManager,
    track: (_ fromLang: String, _ toLang: String, _ reason: String) -> Void,
    dismiss: () -> Void
  ) {
    let event = LanguageLockOptions.apply(entry, to: settings)
    track(event.fromLang, event.toLang, event.reason)
    dismiss()
  }
}

// MARK: - EnviousMeet

extension LanguagePickerContent {
  /// #4320: the EnviousMeet Live Preview language window. Rows are the chosen live engine's
  /// languages read now (`MeetingLiveWordsRowModel.languages(for:)`: Apple's exact runtime tags,
  /// such as `en-US` and `en-GB`, or Universal's catalogue codes). No Automatic (live text needs
  /// one language) and no Recent (dictation's recents are not meeting history). A choice writes
  /// only the meeting's live language (`selectLanguage`), never dictation's, and reports nothing.
  @MainActor
  static func meetingLive(
    model: MeetingLiveWordsRowModel, query: String,
    dismiss: @escaping @MainActor () -> Void
  ) -> LanguagePickerContent {
    guard let engine = model.selectedEngine else {
      return meetingLiveContent(rows: [], query: query)
    }
    let rows = model.languages(for: engine).map { option in
      let names = liveNames(engine: engine, option: option)
      return LanguagePickerRow(
        id: option.code, code: option.code, nativeName: names.native, englishName: names.english,
        displayName: option.name, subtitle: option.code,
        isSelected: option.code == model.selectedLanguage, accessibilityLabel: option.name
      ) {
        Task { await model.selectLanguage(option.code) }
        dismiss()
      }
    }
    return meetingLiveContent(rows: rows, query: query)
  }

  private static func meetingLiveContent(rows: [LanguagePickerRow], query: String)
    -> LanguagePickerContent
  {
    LanguagePickerContent(
      title: String(localized: MeetingsCopy.liveLanguageTitle), contextSubtitle: nil,
      autoRow: nil, recents: [], heading: String(localized: MeetingsCopy.liveLanguageListHeading),
      emptySearchText: String(localized: "No language matches your search."),
      rows: rows.filter { matches($0, query: query) })
  }

  /// A live row's native and English names, for search. Universal codes are catalogue entries;
  /// Apple's exact tags (such as `en-GB`) are named by the locale itself, region included, so two
  /// regions of one language stay two rows.
  static func liveNames(
    engine: LivePreviewEngineChoice, option: MeetingLiveWordsRowModel.LanguageOption
  ) -> (native: String, english: String) {
    switch engine {
    case .universal:
      let entry = LanguageCatalog.entry(for: option.code)
      return (entry.nativeName, entry.englishName)
    case .apple:
      let native =
        Locale(identifier: option.code).localizedString(forIdentifier: option.code) ?? option.name
      let english =
        Locale(identifier: "en").localizedString(forIdentifier: option.code) ?? option.name
      return (native, english)
    }
  }

  /// #4320: the EnviousMeet Transcript language window: the transcript engine's lockable
  /// languages through `LanguageLockOptions.pickerRows` (the same owner, search and order as
  /// `transcriptLanguageOptions`), no English (UK), no Automatic (the section's switch owns
  /// Auto) and no Recent. A choice locks only the meeting transcript's language.
  @MainActor
  static func meetingTranscript(
    model: MeetingLiveWordsRowModel, engine: MeetingEngineChoice, query: String,
    dismiss: @escaping @MainActor () -> Void
  ) -> LanguagePickerContent {
    let locked: String? = {
      if case .locked(let code) = model.transcriptLanguage { return code }
      return nil
    }()
    let rows = LanguageLockOptions.pickerRows(
      lockableCodes: LanguageLockOptions.lockableCodes(for: engine.backendType), query: query,
      offersEnglishUK: false
    ).map { entry in
      dictationRow(entry, isSelected: entry.lockCode == locked) {
        model.transcriptLanguage = .locked(entry.lockCode)
        dismiss()
      }
    }
    return LanguagePickerContent(
      title: String(localized: MeetingsCopy.transcriptLanguageTitle), contextSubtitle: nil,
      autoRow: nil, recents: [],
      heading: MeetingsCopy.transcriptLanguageListHeading(
        MeetingTranscriptEngineRowTitles.title(of: engine)
      ).uppercased(),
      emptySearchText: String(localized: "No language matches your search."), rows: rows)
  }

  /// Whether a caller-built row matches the search, by the fields `LanguageLockOptions.pickerRows`
  /// searches (shown, English and native names and the code), case-insensitive, ignoring
  /// surrounding whitespace. Apple's live tags are not catalogue entries, so they cannot go
  /// through `pickerRows` itself.
  static func matches(_ row: LanguagePickerRow, query: String) -> Bool {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !needle.isEmpty else { return true }
    return row.displayName.lowercased().contains(needle)
      || row.englishName.lowercased().contains(needle)
      || row.nativeName.lowercased().contains(needle)
      || row.code.lowercased().contains(needle)
  }
}
