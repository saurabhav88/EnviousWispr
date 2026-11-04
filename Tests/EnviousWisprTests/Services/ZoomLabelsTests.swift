import Foundation
import Testing

@testable import EnviousWisprServices

/// #4350: when these fail, a Zoom call in German, Japanese or another Zoom language gives
/// "Speaker N" instead of names, a nickname such as `Anna (EU)` is taken for the user, or a
/// broken Zoom file makes an English Zoom call lose names it has today.
///
/// Fixtures `Resources/ZoomStrings/<lang>/Localizable.strings` (no `.lproj`: SwiftPM would treat it as a localized resource) are our own minimal copies of the listed keys
/// from Zoom 7.1.9 (88375). Expected values are literals from the live receipt
/// (`20261103-131437-4350-zoom-languages-discovery-83ca/receipt.md`), never read back through
/// `ZoomLabels`.
@Suite("Zoom labels in every Zoom language", .tags(.productOutcome))
struct ZoomLabelsTests {
  static let fixtureLanguages = ["de", "en", "ja", "zh-Hans", "zh-Hant"]

  static func fixtureTable(_ language: String) throws -> [String: String] {
    let url = RepoRoot.url.appending(
      path: "Tests/EnviousWisprTests/Resources/ZoomStrings/\(language)/Localizable.strings")
    return try #require(NSDictionary(contentsOf: url) as? [String: String])
  }

  static func fixtures() throws -> ZoomLabels {
    ZoomLabels(tables: try fixtureLanguages.map { ($0, try fixtureTable($0)) })
  }

  // MARK: - Built-in floor

  @Test("Every English word read today is in the built-in floor")
  func englishFloor() {
    let labels = ZoomLabels.builtIn
    let expected: [(ZoomLabels.Role, String)] = [
      (.audioMuted, "Computer audio muted"), (.audioUnmuted, "Computer audio unmuted"),
      (.noAudio, "No audio connected"), (.videoOn, "Video on"), (.videoOff, "Video off"),
      (.activeSpeaker, "active speaker"), (.participantsList, "Participants list"),
      (.tagHost, "Host"), (.tagCoHost, "Co-host"), (.tagGuest, "Guest"), (.tagMe, "me"),
      (.shareContent, "Share content"), (.compactHide, "Hide thumbnail video"),
      (.compactShowActive, "Show active speaker video"), (.muteMyAudio, "Mute my audio"),
      (.unmuteMyAudio, "Unmute my audio"),
    ]
    for (role, word) in expected {
      #expect(labels.matches(role, word), "\(role) \(word)")
    }
    #expect(labels.participantCount("Participants (4)") == 4)
    #expect(
      labels.binds(.moreOptionsCollapsed, label: "More options for Bea, collapsed", name: "Bea"))
    #expect(
      labels.binds(.moreOptionsExpanded, label: "More options for Bea, expanded", name: "Bea"))
    #expect(labels.talkingNames("Talking: Bea Chen") == ["Bea Chen"])
    #expect(labels.talkingNames("Talking: ") == [""])
    // Granola's active-speaker list is a floor too (Zoom builds that flag in code).
    #expect(labels.matches(.activeSpeaker, "Aktiver Sprecher"))
    #expect(labels.matches(.activeSpeaker, "アクティブ スピーカー"))
  }

  @Test("Widening rules: no-space count, extra spaces after Talking")
  func wideningRules() {
    let labels = ZoomLabels.builtIn
    #expect(labels.participantCount("Participants(4)") == 4)
    #expect(labels.talkingNames("Talking:  Bea") == ["Bea"])
    #expect(labels.showsCount("Participants (12)"))
    #expect(labels.showsCount("Participants(12)"))
    #expect(labels.showsCount("Participants list") == false)
  }

  // MARK: - Normalisation

  @Test("Normalisation: NFKC, one space, trimmed, case kept")
  func normalisation() {
    let fullWidth = ZoomLabels.normalized("参加者（１）")
    #expect(
      Array(fullWidth.unicodeScalars.map(\.value)) == [0x53C2, 0x52A0, 0x8005, 0x28, 0x31, 0x29])
    #expect(ZoomLabels.normalized("La parole est à\u{00A0}:  ") == "La parole est à :")
    #expect(ZoomLabels.normalized("  a \t\n b ") == "a b")
    #expect(ZoomLabels.normalized("ME") == "ME")
    #expect(ZoomLabels.normalizedPiece("More options for ") == "More options for ")
  }

  @Test("Tags compare case-sensitively: ME and Ben are not tags")
  func tagsCaseSensitive() throws {
    let labels = try Self.fixtures()
    #expect(labels.matches(.tagMe, "me"))
    #expect(labels.matches(.tagMe, "Ich"))
    #expect(labels.matches(.tagMe, "自分"))
    #expect(labels.matches(.tagMe, "ME") == false)
    #expect(labels.matches(.tagMe, "ich") == false)
    #expect(labels.matches(.tagHost, "Ben") == false)
    #expect(labels.words(.tagMe, in: "de") == ["Ich"])
    #expect(labels.words(.tagHost, in: "ja") == ["ホスト"])
  }

  // MARK: - Fixture tables

  @Test("German and Japanese words load for every keyed role")
  func germanAndJapanese() throws {
    let labels = try Self.fixtures()
    #expect(labels.report.missing.isEmpty, "\(labels.report.missing)")
    #expect(labels.report.collisions == 0)
    #expect(labels.matches(.audioMuted, "Bei Computeraudio Stummschaltung aktiviert"))
    #expect(labels.matches(.audioMuted, "ミュートされたコンピュータ オーディオ"))
    #expect(labels.matches(.unmuteMyAudio, "Stummschaltung für Audio aufheben"))
    #expect(labels.matches(.unmuteMyAudio, "自分のオーディオをミュート解除する"))
    #expect(labels.languages(.participantsList, matching: "Teilnehmerliste") == ["de"])
    #expect(labels.languages(.participantsList, matching: "参加者リスト") == ["ja"])
    #expect(labels.matches(.compactHide, "Videominiaturansicht ausblenden"))
    #expect(labels.matches(.compactShowActive, "Aktives Sprechervideo anzeigen"))
    #expect(labels.matches(.compactHide, "サムネイル ビデオの非表示"))
    #expect(labels.matches(.compactShowActive, "アクティブ スピーカー ビデオを表示"))
    #expect(labels.participantCount("Teilnehmer (1)") == 1)
    #expect(labels.participantCount("参加者 (1)") == 1)
    #expect(labels.participantCount("参加者（3）") == 3)
    #expect(labels.participantCount("参会者(2)") == 2)
    #expect(labels.participantCount("Teilnehmer (x)") == nil)
    #expect(labels.talkingNames("Sprechen: ") == [""])
    #expect(labels.talkingNames("発言中:") == [""])
    #expect(labels.talkingNames("Sprechen: Jonas Weber") == ["Jonas Weber"])
    #expect(labels.talkingNames("発言中: Dana") == ["Dana"])
    #expect(labels.talkingNames("Dana spricht") == [])
    // English stays English: the video state Zoom keeps in English is still read.
    #expect(labels.matches(.videoOff, "Video off"))
    #expect(labels.matches(.videoOff, "Video aus"))
    // Coverage report: languages × roles (printed for the receipt).
    let matrix = labels.coverage()
    for language in Self.fixtureLanguages {
      let roles = matrix[language] ?? [:]
      for role in ZoomLabels.Role.allCases {
        print("ZoomLabels fixture \(language) \(role.rawValue)=\(roles[role] ?? 0)")
      }
    }
    print("ZoomLabels fixture missing=\(labels.report.missing) refused=\(labels.report.refused)")
    #expect(labels.report.refused.isEmpty)
    let keyed = ZoomLabels.Role.allCases.filter { !$0.keys.isEmpty }
    for language in ["de", "ja"] {
      let missing = keyed.filter { matrix[language]?[$0] == nil }
      #expect(missing.isEmpty, "\(language) missing \(missing)")
    }
  }

  @Test("Row menu: name-first ja, zh-Hans, zh-Hant and German bind the original name")
  func rowMenuTemplates() throws {
    let labels = try Self.fixtures()
    #expect(
      labels.binds(
        .moreOptionsCollapsed, label: "Weitere Optionen für Saurabh A Vaish, eingeklappt",
        name: "Saurabh A Vaish"))
    #expect(
      labels.binds(
        .moreOptionsCollapsed, label: "Saurabh A Vaish のその他のオプション、折りたたみ済み",
        name: "Saurabh A Vaish"))
    #expect(labels.binds(.moreOptionsCollapsed, label: "Dana的更多选项，已收起", name: "Dana"))
    #expect(labels.binds(.moreOptionsCollapsed, label: "更多Dana選項，已摺疊", name: "Dana"))
    // The original name, never normalised: two spaces and full-width letters stay.
    #expect(
      labels.binds(
        .moreOptionsCollapsed, label: "More options for Bea  Chen, collapsed", name: "Bea  Chen"))
    #expect(
      labels.binds(
        .moreOptionsCollapsed, label: "More options for Bea  Chen, collapsed", name: "Bea Chen")
        == false)
    #expect(labels.binds(.moreOptionsCollapsed, label: "Ｄａｎａ的更多选项，已收起", name: "Ｄａｎａ"))
    #expect(labels.binds(.moreOptionsCollapsed, label: "Ｄａｎａ的更多选项，已收起", name: "Dana") == false)
    // A name holding template-like words still binds only as a whole.
    let tricky = "More options for More options for Bea, collapsed"
    #expect(labels.binds(.moreOptionsCollapsed, label: tricky, name: "More options for Bea"))
    #expect(labels.binds(.moreOptionsCollapsed, label: tricky, name: "Bea") == false)
    // Restricted to one language's templates.
    #expect(
      labels.binds(
        .moreOptionsCollapsed, label: "Weitere Optionen für Bea, eingeklappt", name: "Bea",
        in: ["ja"]) == false)
  }

  // MARK: - Shape refusals and collisions

  @Test("Wrong placeholder shapes are refused for that role")
  func placeholderRefusals() {
    let labels = ZoomLabels(tables: [
      (
        "xx",
        [
          "LN_Accessibility_More_Managing_Options_58425": "%@ und %@",
          "LN_PBO_Panelist_Count_353951": "Leute",
          "LN_Plist_Accessibility_VoIP_Muted_20044": "stumm %d",
          "LN_Accessibility_Active_Speaker_Name_69648": "Redet: %1$@",
        ]
      )
    ])
    #expect(
      labels.report.refused.contains(
        "xx:moreOptionsCollapsed:LN_Accessibility_More_Managing_Options_58425"))
    #expect(labels.report.refused.contains("xx:participantsCount:LN_PBO_Panelist_Count_353951"))
    #expect(labels.report.refused.contains("xx:audioMuted:LN_Plist_Accessibility_VoIP_Muted_20044"))
    #expect(labels.matches(.audioMuted, "stumm %d") == false)
    #expect(labels.talkingNames("Redet: Bea") == ["Bea"])
  }

  @Test("A word meaning two roles is dropped from both; a floor word keeps its role")
  func collisions() {
    let labels = ZoomLabels(tables: [
      ("xx", ["me": "Gast", "Guest": "Gast"]),
      ("yy", ["Host": "Computer audio muted"]),
    ])
    #expect(labels.report.collisions == 2)
    #expect(labels.matches(.tagMe, "Gast") == false)
    #expect(labels.matches(.tagGuest, "Gast") == false)
    #expect(labels.matches(.audioMuted, "Computer audio muted"))
    #expect(labels.matches(.tagHost, "Computer audio muted") == false)
  }

  @Test("Granola's translated active-speaker words lose a collision; English floor words win")
  func granolaFloorCollision() {
    let labels = ZoomLabels(tables: [
      ("de", ["LN_Plist_Accessibility_VoIP_Muted_20044": "Aktiver Sprecher"]),
      ("en", ["LN_Plist_Accessibility_VoIP_Unmuted_20044": "active speaker"]),
    ])
    #expect(labels.matches(.activeSpeaker, "Aktiver Sprecher") == false)
    #expect(labels.matches(.audioMuted, "Aktiver Sprecher") == false)
    #expect(labels.matches(.activeSpeaker, "active speaker"))
    #expect(labels.matches(.audioUnmuted, "active speaker") == false)
    #expect(labels.report.collisions == 2)
  }

  @Test("Talking: two valid readings give two names; numeric and unsupported placeholders")
  func templateAmbiguityAndPlaceholders() {
    let labels = ZoomLabels(tables: [
      ("xx", ["LN_Accessibility_Active_Speaker_Name_69648": "A: %@"]),
      ("yy", ["LN_Accessibility_Active_Speaker_Name_69648": "A: B: %@"]),
      ("c1", ["LN_PBO_Panelist_Count_353951": "Leute (%ld)"]),
      ("c2", ["LN_PBO_Panelist_Count_353951": "Gente (%lu)"]),
      ("c3", ["LN_PBO_Panelist_Count_353951": "Volk (%s)"]),
      ("c4", ["LN_Accessibility_More_Managing_Options_58425": "Mehr für %s"]),
      ("c5", ["LN_Accessibility_More_Managing_Options_58425": "100%% für %@"]),
    ])
    #expect(labels.talkingNames("A: B: Dana") == ["B: Dana", "Dana"])
    #expect(labels.participantCount("Leute (3)") == 3)
    #expect(labels.participantCount("Gente(4)") == 4)
    #expect(labels.participantCount("Volk (5)") == nil)
    #expect(labels.report.refused.contains("c3:participantsCount:LN_PBO_Panelist_Count_353951"))
    #expect(
      labels.report.refused.contains(
        "c4:moreOptionsCollapsed:LN_Accessibility_More_Managing_Options_58425"))
    #expect(labels.binds(.moreOptionsCollapsed, label: "100% für Bea", name: "Bea"))
  }

  @Test("A list label two languages share names both languages")
  func sharedOutlineLabel() {
    let labels = ZoomLabels(tables: [
      (
        "es",
        ["LN_Meeting_Slide_Remote_Control_Plist_AX_Description_424289": "Lista de participantes"]
      ),
      (
        "pt-PT",
        ["LN_Meeting_Slide_Remote_Control_Plist_AX_Description_424289": "Lista de participantes"]
      ),
    ])
    #expect(
      labels.languages(.participantsList, matching: "Lista de participantes") == ["es", "pt-PT"])
  }

  // MARK: - Loading and cache

  final class FakeSource: @unchecked Sendable {
    let lock = NSLock()
    var bundle: URL? = URL(fileURLWithPath: "/Applications/zoom.us.app")
    var version: String? = "7.1.9.88375"
    var files: [ZoomStringsSource.File] = []
    var tables: [String: [String: String]] = [:]
    var reads = 0

    func file(_ language: String, size: Int64 = 100, modified: Double = 1) -> ZoomStringsSource.File
    {
      ZoomStringsSource.File(
        language: language, path: "/z/\(language).lproj/Localizable.strings", fileID: 7,
        size: size, modified: modified)
    }

    var source: ZoomStringsSource {
      ZoomStringsSource(
        locate: { self.lock.withLock { self.bundle } },
        version: { _ in self.lock.withLock { self.version } },
        files: { _ in self.lock.withLock { self.files } },
        read: { file in
          self.lock.withLock {
            self.reads += 1
            return self.tables[file.language]
          }
        })
    }
  }

  @Test("Cache: unchanged files parse once; a change, a removal or a repair reloads")
  func cache() async throws {
    let fake = FakeSource()
    fake.files = [fake.file("de")]
    fake.tables = ["de": try Self.fixtureTable("de")]
    let store = ZoomLabelsStore(source: fake.source)

    let first = await store.current()
    #expect(first.matches(.tagMe, "Ich"))
    #expect(fake.reads == 1)
    _ = await store.current()
    #expect(fake.reads == 1)

    // Modified with the same Zoom version.
    fake.files = [fake.file("de", size: 101, modified: 2)]
    fake.tables = ["de": ["me": "Selbst"]]
    let second = await store.current()
    #expect(fake.reads == 2)
    #expect(second.matches(.tagMe, "Selbst"))
    #expect(first.matches(.tagMe, "Ich"))  // an earlier value never changes

    // Added file.
    fake.files.append(fake.file("ja"))
    fake.tables["ja"] = try Self.fixtureTable("ja")
    let third = await store.current()
    #expect(fake.reads == 4)
    #expect(third.matches(.tagMe, "自分"))

    // Removed file.
    fake.files = [fake.file("ja")]
    let fourth = await store.current()
    #expect(fourth.matches(.tagMe, "Selbst") == false)

    // Unreadable, then repaired with the same identity.
    fake.tables["ja"] = nil
    fake.files = [fake.file("ja", modified: 9)]
    let broken = await store.current()
    #expect(broken.report.failures == 1)
    #expect(broken.matches(.tagMe, "自分") == false)
    #expect(broken.matches(.tagMe, "me"))  // English floor stays
    fake.tables["ja"] = try Self.fixtureTable("ja")
    let repaired = await store.current()
    #expect(repaired.matches(.tagMe, "自分"))

    // Each key part alone reloads: identity, size, modification time, version, bundle path.
    let base = fake.file("ja", modified: 9)
    let variants: [() -> Void] = [
      { fake.files = [ZoomStringsSource.File(language: "ja", path: base.path, fileID: 8, size: base.size, modified: base.modified)] },
      { fake.files = [ZoomStringsSource.File(language: "ja", path: base.path, fileID: 8, size: 555, modified: base.modified)] },
      { fake.files = [ZoomStringsSource.File(language: "ja", path: base.path, fileID: 8, size: 555, modified: 77)] },
      { fake.version = "7.2.0" },
      { fake.bundle = URL(fileURLWithPath: "/Applications/Zoom Copy.app") },
    ]
    for change in variants {
      let before = fake.reads
      _ = await store.current()
      #expect(fake.reads == before)  // unchanged: reused
      change()
      _ = await store.current()
      #expect(fake.reads == before + 1)  // changed: parsed again
    }
  }

  @Test("No Zoom installed: the built-in floor")
  func noZoom() async {
    let fake = FakeSource()
    fake.bundle = nil
    let labels = await ZoomLabelsStore(source: fake.source).current()
    #expect(labels.words == ZoomLabels.builtIn.words)
    #expect(labels.templates == ZoomLabels.builtIn.templates)
    #expect(labels.countHeads == ZoomLabels.builtIn.countHeads)
    #expect(fake.reads == 0)
  }

  @Test("A malformed table is skipped; the others load")
  func malformed() async throws {
    let fake = FakeSource()
    fake.files = [fake.file("de"), fake.file("ja")]
    fake.tables = ["ja": try Self.fixtureTable("ja")]
    let labels = await ZoomLabelsStore(source: fake.source).current()
    #expect(labels.report.failures == 1)
    #expect(labels.matches(.tagMe, "自分"))
    #expect(labels.matches(.tagMe, "Ich") == false)
  }
}

/// #4350: the installed Zoom's real tables (real boundary: reads `/Applications/zoom.us.app`).
@Suite(
  "Zoom labels from the installed Zoom", .tags(.productOutcome, .realBoundary), .realBoundaryRun,
  .enabled(if: FileManager.default.fileExists(atPath: "/Applications/zoom.us.app")))
struct ZoomLabelsInstalledTests {
  @Test("Every installed language loads, no collisions, cold load under 150 ms")
  func installed() async throws {
    let store = ZoomLabelsStore(source: .live)
    let start = ContinuousClock.now
    let labels = await store.current()
    let elapsed = ContinuousClock.now - start
    let version = ZoomStringsSource.live.locate().flatMap(ZoomStringsSource.live.version) ?? "?"
    print(
      "ZoomLabels installed: version=\(version) languages=\(labels.report.languages.count) elapsed=\(elapsed)"
    )
    print("ZoomLabels missing=\(labels.report.missing) refused=\(labels.report.refused)")
    let matrix = labels.coverage()
    for language in labels.report.languages {
      let roles = matrix[language] ?? [:]
      let absent = ZoomLabels.Role.allCases.filter { !$0.keys.isEmpty && roles[$0] == nil }
      print(
        "ZoomLabels installed \(language): roles=\(roles.count) absent=\(absent.map(\.rawValue))")
      for role in ZoomLabels.Role.allCases {
        print("ZoomLabels installed \(language) \(role.rawValue)=\(roles[role] ?? 0)")
      }
    }
    #expect(labels.report.failures == 0)
    #expect(labels.report.languages.count >= 17)
    #expect(labels.report.collisions == 0)
    #expect(labels.matches(.tagMe, "Ich"))
    #expect(labels.languages(.participantsList, matching: "参加者リスト").contains("ja"))
    #expect(elapsed < .milliseconds(150))
  }
}
