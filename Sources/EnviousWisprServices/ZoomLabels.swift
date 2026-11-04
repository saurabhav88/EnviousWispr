import AppKit
import EnviousWisprCore
import Foundation
import os

/// The words the Zoom Mac app draws on its call screen, in every language Zoom installs (#4350).
///
/// One owner of Zoom label words for the speaker reader and the Zoom mute rule. The values come
/// from Zoom's own translation files (`zoom.us.app/Contents/Resources/<lang>.lproj/
/// Localizable.strings`, read by Zoom's own keys) merged over a built-in floor: today's exact
/// English literals plus Granola's 17-language "Active speaker" list (Zoom builds that flag in
/// code). A label is accepted in ANY loaded language (plan §3.2: no language detection).
///
/// Words are compared after `normalized(_:)` (NFKC, whitespace runs to one space), never case
/// folded: `(ME)` and `(Ben)` are names, not tags. Names are never normalised: template checks
/// look at the original name in the original label and normalise only Zoom's words around it.
///
/// Plan: `docs/feature-requests/issue-4350-2026-11-03-zoom-languages.md` §3. Live receipt (de/ja,
/// Zoom 7.1.9): AgentArtifacts run `20261103-131437-4350-zoom-languages-discovery-83ca`.
package struct ZoomLabels: Sendable, Equatable {
  /// What a Zoom word means on the call screen.
  package enum Role: String, CaseIterable, Sendable {
    case audioMuted, audioUnmuted, noAudio, videoOn, videoOff, activeSpeaker
    case participantsList, participantsCount
    case tagHost, tagCoHost, tagGuest, tagMe
    case moreOptionsCollapsed, moreOptionsExpanded
    case shareContent, compactHide, compactShowActive, talking
    case muteMyAudio, unmuteMyAudio

    /// Zoom's table keys for this role (plan §10, checked against Zoom 7.1.9's tables).
    /// `moreOptionsExpanded` has none: its wording outside English is not observed yet.
    package var keys: [String] {
      switch self {
      case .audioMuted: ["LN_Plist_Accessibility_VoIP_Muted_20044"]
      case .audioUnmuted: ["LN_Plist_Accessibility_VoIP_Unmuted_20044"]
      case .noAudio: ["LN_Plist_Accessibility_No_Audio_20044", "LN_No_Audio_Connected_907832"]
      case .videoOn: ["LN_Plist_Accessibility_Video_On_20044"]
      case .videoOff: ["LN_Plist_Accessibility_Video_Off_20044"]
      case .activeSpeaker: []
      case .participantsList:
        ["Participants list", "LN_Meeting_Slide_Remote_Control_Plist_AX_Description_424289"]
      case .participantsCount: ["LN_PBO_Panelist_Count_353951"]
      case .tagHost: ["Host"]
      case .tagCoHost: ["Co-host", "Co-Host"]
      case .tagGuest: ["Guest", "LN_Plist_Guest_110290"]
      case .tagMe: ["me"]
      case .moreOptionsCollapsed: ["LN_Accessibility_More_Managing_Options_58425"]
      case .moreOptionsExpanded: []
      case .shareContent: ["LN_Meeting_Share_Content_Area_AX_422450"]
      case .compactHide: ["Hide thumbnail video"]
      case .compactShowActive: ["LN_Floating_Bar_Tip_Active_Video_68385"]
      case .talking: ["LN_Accessibility_Active_Speaker_Name_69648", "Talking: "]
      case .muteMyAudio: ["Mute My Audio"]
      case .unmuteMyAudio: ["Unmute My Audio"]
      }
    }

    enum Shape { case plain, name, count }

    var shape: Shape {
      switch self {
      case .moreOptionsCollapsed, .moreOptionsExpanded, .talking: .name
      case .participantsCount: .count
      default: .plain
      }
    }

    /// The bracket tags Zoom puts after a name in a participants-list row.
    package static let tags: [Role] = [.tagHost, .tagCoHost, .tagGuest, .tagMe]
  }

  /// A one-placeholder Zoom wording split around its name, both parts `normalizedPiece`d.
  /// `ja` puts the name first (empty prefix); `zh-Hant` has words on both sides.
  package struct Template: Sendable, Hashable {
    package let prefix: String
    package let suffix: String
  }

  /// What one load found, for the DEBUG line and the coverage report. Keys and counts only,
  /// never label text.
  package struct Report: Sendable, Equatable {
    package var languages: [String] = []
    /// `lang:key` pairs the table lacks.
    package var missing: [String] = []
    /// `lang:role:key` values dropped for a wrong placeholder shape.
    package var refused: [String] = []
    /// Normalised values that meant two roles and were removed (fail closed).
    package var collisions = 0
    /// Files that were absent, unreadable or did not parse.
    package var failures = 0
  }

  /// Built-in language code for the floor values.
  package static let floorLanguage = "en"

  /// language → role → accepted normalised words (plain roles).
  package let words: [String: [Role: Set<String>]]
  /// language → role → templates (name roles).
  package let templates: [String: [Role: Set<Template>]]
  /// language → heads of the `Participants (%d)` count wording, e.g. `Teilnehmer`, `参加者`.
  package let countHeads: [String: Set<String>]
  package let report: Report

  // MARK: - Built-in floor

  /// Today's exact English literals (the reader's and the mute rule's), including the forms Zoom
  /// builds in code. Never removed by a collision (only English floor words win; Granola's
  /// translations can be removed like any table word).
  static let englishFloor: [Role: [String]] = [
    .audioMuted: ["Computer audio muted"],
    .audioUnmuted: ["Computer audio unmuted"],
    .noAudio: ["No audio connected"],
    .videoOn: ["Video on"],
    .videoOff: ["Video off"],
    .activeSpeaker: ["active speaker"],
    .participantsList: ["Participants list"],
    .participantsCount: ["Participants (%d)"],
    .tagHost: ["Host"],
    .tagCoHost: ["Co-host"],
    .tagGuest: ["Guest"],
    .tagMe: ["me"],
    .moreOptionsCollapsed: ["More options for %@, collapsed"],
    .moreOptionsExpanded: ["More options for %@, expanded"],
    .shareContent: ["Share content"],
    .compactHide: ["Hide thumbnail video"],
    .compactShowActive: ["Show active speaker video"],
    .talking: ["Talking: %@"],
    .muteMyAudio: ["Mute my audio"],
    .unmuteMyAudio: ["Unmute my audio"],
  ]

  /// Granola 7.726.2's "Active speaker" per language (discovery `codex-competitors.txt` GRANOLA
  /// table). Zoom draws the tile flag in code, so its tables do not hold it.
  static let activeSpeakerFloor: [String: String] = [
    "de": "Aktiver Sprecher", "en": "Active speaker", "es": "Orador activo",
    "fr": "Intervenant actif", "id": "Pembicara aktif", "it": "Oratore attivo",
    "ja": "アクティブ スピーカー", "ko-KR": "현재 발표자", "nl": "Actieve spreker",
    "pl": "Aktywny mówca", "pt-PT": "Orador ativo", "ru": "Активный докладчик",
    "sv": "Aktiv talare", "tr": "Aktif konuşmacı", "vi": "Diễn giả đang hoạt động",
    "zh-Hans": "当前演讲者", "zh-Hant": "目前演講者",
  ]

  /// The floor alone: what the app uses when no Zoom file can be read.
  package static let builtIn = ZoomLabels(tables: [])

  // MARK: - Building

  /// Builds labels from the floor plus `tables` (language code → Zoom's key → value). A value
  /// with the wrong placeholder shape is dropped for that role; a normalised word meaning two
  /// roles is removed from both unless it is a floor word (which keeps its role).
  package init(tables: [(language: String, strings: [String: String])], failures: Int = 0) {
    var report = Report()
    report.failures = failures
    var words: [String: [Role: Set<String>]] = [:]
    var templates: [String: [Role: Set<Template>]] = [:]
    var heads: [String: Set<String>] = [:]
    var floorWords: Set<String> = []  // "role|word"

    func add(_ raw: String, role: Role, language: String, key: String, floor: Bool) {
      let placeholders = Self.placeholders(in: raw)
      switch role.shape {
      case .plain:
        let word = Self.normalized(raw)
        guard placeholders.isEmpty, !word.isEmpty else {
          report.refused.append("\(language):\(role.rawValue):\(key)")
          return
        }
        words[language, default: [:]][role, default: []].insert(word)
        if floor { floorWords.insert("\(role.rawValue)|\(word)") }
      case .name:
        if placeholders.count == 1, let only = placeholders.first, only.isName {
          let template = Template(
            prefix: Self.normalizedPiece(Self.literal(raw[..<only.range.lowerBound])),
            suffix: Self.normalizedPiece(Self.literal(raw[only.range.upperBound...])))
          templates[language, default: [:]][role, default: []].insert(template)
        } else if placeholders.isEmpty, role == .talking, !Self.normalized(raw).isEmpty {
          // Zoom's quiet form ("Talking: " with nobody named) is the prefix alone.
          templates[language, default: [:]][role, default: []].insert(
            Template(prefix: Self.normalizedPiece(Self.literal(raw[...])), suffix: ""))
        } else {
          report.refused.append("\(language):\(role.rawValue):\(key)")
        }
      case .count:
        let text = Self.normalized(raw)
        guard placeholders.count == 1, let only = placeholders.first, !only.isName,
          let open = text.lastIndex(of: "("),
          text[open...] == "(\(raw[only.range]))"
        else {
          report.refused.append("\(language):\(role.rawValue):\(key)")
          return
        }
        let head = String(text[..<open]).trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty else {
          report.refused.append("\(language):\(role.rawValue):\(key)")
          return
        }
        heads[language, default: []].insert(head)
      }
    }

    for (role, values) in Self.englishFloor {
      for value in values {
        add(value, role: role, language: Self.floorLanguage, key: "built-in", floor: true)
      }
    }
    for (language, value) in Self.activeSpeakerFloor {
      add(
        value, role: .activeSpeaker, language: language, key: "built-in",
        floor: language == Self.floorLanguage)
    }
    for table in tables {
      report.languages.append(table.language)
      for role in Role.allCases {
        for key in role.keys {
          guard let value = table.strings[key] else {
            report.missing.append("\(table.language):\(key)")
            continue
          }
          add(value, role: role, language: table.language, key: key, floor: false)
        }
      }
    }

    // Fail closed: a plain word that means two roles is removed from both, except where it is
    // a floor word for that role.
    var rolesByWord: [String: Set<Role>] = [:]
    for perRole in words.values {
      for (role, set) in perRole { for word in set { rolesByWord[word, default: []].insert(role) } }
    }
    for (word, roles) in rolesByWord where roles.count > 1 {
      report.collisions += 1
      for role in roles where !floorWords.contains("\(role.rawValue)|\(word)") {
        for language in words.keys { words[language]?[role]?.remove(word) }
      }
    }

    report.languages.sort()
    self.words = words
    self.templates = templates
    self.countHeads = heads
    self.report = report
  }

  // MARK: - Normalisation (Zoom words only, never names)

  /// NFKC, whitespace runs to one space, trimmed. Full-width brackets, colon and digits become
  /// ASCII; no case folding.
  package static func normalized(_ text: String) -> String {
    normalizedPiece(text).trimmingCharacters(in: .whitespaces)
  }

  /// `normalized` without the trim: for the words around a name, where the space next to the
  /// name is part of the wording (`More options for ` + name).
  static func normalizedPiece(_ text: String) -> String {
    var out = ""
    var lastWasSpace = false
    for character in text.precomposedStringWithCompatibilityMapping {
      if character.isWhitespace {
        if !lastWasSpace { out.append(" ") }
        lastWasSpace = true
      } else {
        out.append(character)
        lastWasSpace = false
      }
    }
    return out
  }

  /// Zoom's words around a placeholder as drawn: `%%` is a literal `%`.
  static func literal(_ text: Substring) -> String {
    text.replacingOccurrences(of: "%%", with: "%")
  }

  struct Placeholder {
    let range: Range<String.Index>
    let isName: Bool
  }

  /// Zoom's `%@`, `%1$@`, `%d`, `%ld`, `%lu` placeholders in `raw`.
  static func placeholders(in raw: String) -> [Placeholder] {
    var found: [Placeholder] = []
    var index = raw.startIndex
    while let percent = raw[index...].firstIndex(of: "%") {
      var cursor = raw.index(after: percent)
      // `%%` is a literal percent sign.
      if cursor < raw.endIndex, raw[cursor] == "%" {
        index = raw.index(after: cursor)
        continue
      }
      var digits = cursor
      while digits < raw.endIndex, raw[digits].isASCII, raw[digits].isNumber {
        digits = raw.index(after: digits)
      }
      if digits > cursor, digits < raw.endIndex, raw[digits] == "$" {
        cursor = raw.index(after: digits)
      }
      let rest = raw[cursor...]
      if rest.hasPrefix("@") {
        found.append(Placeholder(range: percent..<raw.index(after: cursor), isName: true))
      } else if rest.hasPrefix("ld") || rest.hasPrefix("lu") {
        found.append(Placeholder(range: percent..<raw.index(cursor, offsetBy: 2), isName: false))
      } else if rest.hasPrefix("d") {
        found.append(Placeholder(range: percent..<raw.index(after: cursor), isName: false))
      } else {
        // Any other `%x` in a label is a placeholder we do not read: count it so the value is
        // refused rather than half-matched.
        found.append(Placeholder(range: percent..<cursor, isName: false))
      }
      index = found.last!.range.upperBound
    }
    return found
  }

  // MARK: - Queries

  /// The languages in which `text` is a word for `role` (several when languages share one,
  /// e.g. es and pt-PT `Lista de participantes`). Empty when it is not.
  package func languages(_ role: Role, matching text: String) -> Set<String> {
    let word = Self.normalized(text)
    return Set(
      words.compactMap { language, roles in
        roles[role]?.contains(word) == true ? language : nil
      })
  }

  /// Whether `text` is a word for `role` in any loaded language.
  package func matches(_ role: Role, _ text: String) -> Bool {
    let word = Self.normalized(text)
    return words.values.contains { $0[role]?.contains(word) == true }
  }

  /// The words for `role` in `language` (normalised).
  package func words(_ role: Role, in language: String) -> Set<String> {
    words[language]?[role] ?? []
  }

  /// Whether `label` is a `role` template wrapped around exactly `name` (the original name,
  /// never normalised) in one of `languages` (all languages when `nil`). Zoom's words around
  /// the name are normalised before they are compared.
  package func binds(
    _ role: Role, label: String, name: String, in languages: Set<String>? = nil
  ) -> Bool {
    guard !name.isEmpty else { return false }
    let candidates = templates.filter { languages?.contains($0.key) ?? true }
      .flatMap { $0.value[role] ?? [] }
    guard !candidates.isEmpty else { return false }
    var search = label.startIndex
    while search < label.endIndex, let range = label.range(of: name, range: search..<label.endIndex)
    {
      let before = Self.normalizedPiece(String(label[..<range.lowerBound]))
      let after = Self.normalizedPiece(String(label[range.upperBound...]))
      if candidates.contains(where: { $0.prefix == before && $0.suffix == after }) { return true }
      search = label.index(after: range.lowerBound)
    }
    return false
  }

  /// The talker names a Talking label can mean, trimmed from the original text (plan §3.4):
  /// `Talking: Bea Chen` → {`Bea Chen`}; `Talking: ` or `発言中:` → {""} (nobody talking); any
  /// other text → {}. The template prefix is compared with its trailing space trimmed. More
  /// than one name means the label is ambiguous; the caller refuses it.
  package func talkingNames(_ label: String) -> Set<String> {
    let candidates = templates.values.flatMap { $0[.talking] ?? [] }
    guard !candidates.isEmpty else { return [] }
    // Every split of the original label into (Zoom's words, name, Zoom's words).
    let splits = Array(label.indices) + [label.endIndex]
    var names: Set<String> = []
    for (startOffset, start) in splits.enumerated() {
      let before = Self.trailingTrimmed(Self.normalizedPiece(String(label[..<start])))
      let matching = candidates.filter { Self.trailingTrimmed($0.prefix) == before }
      guard !matching.isEmpty else { continue }
      for end in splits[startOffset...] {
        let after = Self.normalizedPiece(String(label[end...]))
        if matching.contains(where: { $0.suffix == after }) {
          names.insert(String(label[start..<end]).trimmingCharacters(in: .whitespaces))
        }
      }
    }
    return names
  }

  static func trailingTrimmed(_ text: String) -> String {
    var text = text
    while text.last?.isWhitespace == true { text.removeLast() }
    return text
  }

  /// The count in a participants-panel heading: head, then zero or one space, then `(`, ASCII
  /// digits, `)` (live ja `参加者 (1)` against table `参加者（%d）`).
  package func participantCount(_ text: String) -> Int? {
    let text = Self.normalized(text)
    for head in countHeads.values.flatMap({ $0 }) where text.hasPrefix(head) {
      var rest = text.dropFirst(head.count)
      if rest.first == " " { rest = rest.dropFirst() }
      guard rest.first == "(", rest.last == ")", rest.count > 2 else { continue }
      let digits = rest.dropFirst().dropLast()
      guard digits.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(digits) else {
        continue
      }
      return value
    }
    return nil
  }

  /// Whether `text` starts like a participants count heading (`Teilnehmer (`), digits or not.
  package func showsCount(_ text: String) -> Bool {
    let text = Self.normalized(text)
    return countHeads.values.flatMap { $0 }.contains {
      text.hasPrefix($0 + "(") || text.hasPrefix($0 + " (")
    }
  }

  /// language × role → number of accepted words or templates, for the coverage report.
  package func coverage() -> [String: [Role: Int]] {
    var matrix: [String: [Role: Int]] = [:]
    for (language, roles) in words {
      for (role, set) in roles where !set.isEmpty {
        matrix[language, default: [:]][role] = set.count
      }
    }
    for (language, roles) in templates {
      for (role, set) in roles { matrix[language, default: [:]][role] = set.count }
    }
    for (language, set) in countHeads {
      matrix[language, default: [:]][.participantsCount] = set.count
    }
    return matrix
  }
}

// MARK: - Loading

/// Where Zoom's translation files come from. `live` reads the installed Zoom bundle; tests
/// inject their own.
package struct ZoomStringsSource: Sendable {
  /// One participating `<lang>.lproj/Localizable.strings` and its identity.
  package struct File: Sendable, Hashable {
    package let language: String
    package let path: String
    package let fileID: UInt64
    package let size: Int64
    package let modified: Double

    package init(language: String, path: String, fileID: UInt64, size: Int64, modified: Double) {
      self.language = language
      self.path = path
      self.fileID = fileID
      self.size = size
      self.modified = modified
    }
  }

  package var locate: @Sendable () -> URL?
  package var version: @Sendable (URL) -> String?
  package var files: @Sendable (URL) -> [File]
  package var read: @Sendable (File) -> [String: String]?

  package init(
    locate: @escaping @Sendable () -> URL?,
    version: @escaping @Sendable (URL) -> String?,
    files: @escaping @Sendable (URL) -> [File],
    read: @escaping @Sendable (File) -> [String: String]?
  ) {
    self.locate = locate
    self.version = version
    self.files = files
    self.read = read
  }

  package static let live = ZoomStringsSource(
    locate: {
      if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "us.zoom.xos") {
        return url
      }
      let fallback = URL(fileURLWithPath: "/Applications/zoom.us.app")
      return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    },
    version: { bundle in
      let info = bundle.appending(path: "Contents/Info.plist")
      return NSDictionary(contentsOf: info)?["CFBundleVersion"] as? String
    },
    files: { bundle in
      let resources = bundle.appending(path: "Contents/Resources")
      let names = (try? FileManager.default.contentsOfDirectory(atPath: resources.path)) ?? []
      return names.filter { $0.hasSuffix(".lproj") }.sorted().compactMap { name in
        let path = resources.appending(path: "\(name)/Localizable.strings").path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
          return nil
        }
        return File(
          language: String(name.dropLast(".lproj".count)), path: path,
          fileID: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
          size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
          modified: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
      }
    },
    read: { file in
      NSDictionary(contentsOf: URL(fileURLWithPath: file.path)) as? [String: String]
    })
}

/// The process-wide cache of `ZoomLabels` (plan §3.5). Loaded at recording start, off the main
/// actor, on its own worker queue; no capture tick reads a file. The cache key is the resolved
/// bundle path, its `CFBundleVersion` and the participating files' presence, identity, size and
/// modification time, so a Zoom update or a repaired file reloads at the next recording start.
package final class ZoomLabelsStore: Sendable {
  struct Key: Hashable, Sendable {
    let path: String?
    let version: String?
    let files: [ZoomStringsSource.File]
  }

  package static let shared = ZoomLabelsStore(source: .live)

  private let source: ZoomStringsSource
  private let worker = DispatchQueue(label: "com.enviouswispr.zoom-labels", qos: .utility)
  private let cache = OSAllocatedUnfairLock<(key: Key, labels: ZoomLabels)?>(initialState: nil)

  package init(source: ZoomStringsSource) {
    self.source = source
  }

  /// The labels for the Zoom installed now, parsing only when the cache key changed.
  package func current() async -> ZoomLabels {
    await withCheckedContinuation { continuation in
      worker.async { continuation.resume(returning: self.load()) }
    }
  }

  /// Synchronous load on the caller's thread (the worker queue in production).
  func load() -> ZoomLabels {
    let bundle = source.locate()?.resolvingSymlinksInPath().standardizedFileURL
    let key = Key(
      path: bundle?.path,
      version: bundle.flatMap(source.version),
      files: bundle.map(source.files) ?? [])
    // A load that lost a file is retried at the next start, so a repaired file comes back even
    // when its identity did not change.
    if let cached = cache.withLock({ $0 }), cached.key == key, cached.labels.report.failures == 0 {
      return cached.labels
    }
    let start = ContinuousClock.now
    // Parsing dominates the load (Zoom 7.1.9, M5 Max: 17 tables × ~10,000 keys, 157 ms one after
    // another, 25 ms side by side), so the files are read in parallel, each into its own slot.
    let files = key.files
    let slots = OSAllocatedUnfairLock(
      initialState: [[String: String]?](repeating: nil, count: files.count))
    let read = source.read
    DispatchQueue.concurrentPerform(iterations: files.count) { index in
      let strings = read(files[index])
      slots.withLock { $0[index] = strings }
    }
    let parsed = slots.withLock { $0 }
    var tables: [(language: String, strings: [String: String])] = []
    var failures = bundle == nil ? 1 : 0
    for (file, strings) in zip(files, parsed) {
      if let strings {
        tables.append((file.language, strings))
      } else {
        failures += 1
      }
    }
    let labels = ZoomLabels(tables: tables, failures: failures)
    cache.withLock { $0 = (key, labels) }
    #if DEBUG
      let elapsed = ContinuousClock.now - start
      let report = labels.report
      let line =
        "zoom labels loaded id=\(String(UInt32(truncatingIfNeeded: key.hashValue), radix: 16)) "
        + "languages=\(report.languages.count) roles=\(Set(labels.coverage().values.flatMap(\.keys)).count) "
        + "missing=\(report.missing.count) refused=\(report.refused.count) "
        + "collisions=\(report.collisions) failures=\(report.failures) "
        + "ms=\(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)"
      Task { await AppLogger.shared.log(line, level: .debug, category: "CallSpeakers") }
    #endif
    return labels
  }
}
