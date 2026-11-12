import AppKit
import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import EnviousWisprServices
import SwiftUI
import Testing

@testable import EnviousWisprAppKit

/// Settings window geometry shared by the layout tests and render harnesses (#4506 moved it here
/// from the retired `AppearanceRenderHarness`, unchanged).
enum SettingsRenderGeometry {
  /// The page host's width for a window width, with the current shell: the window minus three
  /// `SettingsLayout.windowFrameInset` gutters and the 200pt sidebar. 750 gives 508, the 820
  /// default 578, 1300 gives 1058. That is the PAGE, before `SettingsContentView`'s own
  /// `SettingsLayout.contentH` margins; rows, cards and previews are narrower again.
  ///
  /// #3385: corrects the old note here ("the 820pt default leaves ~530 inside after the
  /// sidebar and insets"), which was the content width after the margins, not the page.
  static func pageWidth(window: CGFloat) -> CGFloat {
    window - 3 * SettingsLayout.windowFrameInset - 200
  }
}

/// The design-book render instrument (#4506), successor to `AppearanceRenderHarness`.
///
/// `render-manifest.json` is the authority: it names every expected capture and its fixture,
/// geometry, appearance, locale and state, and a run must produce exactly those PNGs. Two runs are
/// compared with `scripts/design/pixel-diff.py`, which compares decoded pixels, not PNG bytes.
/// Before a comparison counts, two runs of the same revision in fresh test processes must show
/// zero differences (repeatability qualification).
///
/// What the predecessor recorded, kept:
///
/// Renders the real Appearance page to PNG so a human can LOOK at it (#2435), and since #3385
/// the Recording Pill tab the pill controls moved to.
///
/// **Harness Contract. It asserts almost nothing and is not a test of the
/// product** — it is an instrument, and it exists because this page's whole
/// subject is PAINT, which every other instrument here is blind to.
/// `NSHostingView.fittingSize` measures layout; `RenderedPillHarness` records
/// that it cannot see icon, colour, corner shape or `scaleEffect`. A flat level
/// meter, a pill drawn at the wrong size, a clipped theme title and a capsule
/// frozen at the wrong opacity are all invisible to every size assertion in this
/// target — and three of those four actually happened on this change.
///
/// **It is NOT a substitute for Live UAT and must never be cited as one.** It
/// renders SwiftUI views in a test process: no window server chrome, no real
/// scroll interaction, no accessibility tree, no running app. What it does give,
/// on a machine where the screen is LOCKED and no input can be driven, is a true
/// picture of what the layout code produces at a given width — which is the half
/// of a design review that does not need a person clicking.
///
/// **Gated OFF by default**, so CI never renders and no absolute geometry is ever frozen:
///
///     TEST_RUNNER_EW_RENDER_DESIGN=1 scripts/xcode-test.sh \
///       --filter EnviousWisprTests/DesignRenderHarness
///
/// Each run writes a fresh `build/design-render/run-*/` folder with the PNGs and
/// `run-metadata.json` (machine, macOS build, toolchain, configuration, locale, backing scale,
/// revision and working-tree identity). Pinned per capture: `en_US` locale (German fit sheets are
/// labelled as fit evidence), the declared page width, light or dark appearance, isolated
/// defaults, animations disabled, and backing scale 2 (checked, never resized). A capture is taken
/// only after layout has converged: the fitting size measured after layout must equal the size the
/// frame was sized from. A skipped receipt is not a passed receipt: when this suite is skipped it
/// has proven nothing at all. Active system-control paint is not represented: the capture window
/// is offscreen and never key.
@MainActor
@Suite(.tags(.harnessContract))
struct DesignRenderHarness {

  init() { _ = NSApplication.shared }

  nonisolated static let enabled = ProcessInfo.processInfo.environment["EW_RENDER_DESIGN"] == "1"
  static let manifestURL = RepoRoot.url.appending(
    path: "Tests/EnviousWisprTests/Design/render-manifest.json")
  static let pixelDiffURL = RepoRoot.url.appending(path: "scripts/design/pixel-diff.py")

  // MARK: - Manifest

  struct Manifest: Decodable {
    let version: Int
    let entries: [Entry]
  }

  struct Entry: Decodable, Hashable {
    let name: String
    let producer: String
    let fixture: String
    let window: Int?
    let pageWidth: Double
    let appearance: String
    let locale: String
    let state: String?
    /// Pages (`page:<label>` fixtures, #4506 Phase 2): the reference viewport height and which
    /// scroll position, from 0, this capture is.
    let viewport: Double?
    let scroll: Int?
  }

  static func loadManifest() throws -> Manifest {
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
    #expect(!manifest.entries.isEmpty, "the manifest lists no captures")
    #expect(
      Set(manifest.entries.map(\.name)).count == manifest.entries.count, "a capture name repeats")
    for entry in manifest.entries {
      #expect(entry.producer == "DesignRenderHarness", "\(entry.name): unknown producer")
      #expect(["light", "dark"].contains(entry.appearance), "\(entry.name): appearance")
      if let window = entry.window {
        #expect(
          SettingsRenderGeometry.pageWidth(window: CGFloat(window)) == CGFloat(entry.pageWidth),
          "\(entry.name): page width does not match its window")
      }
      if entry.fixture.hasPrefix("page:") {
        #expect(
          entry.viewport.map { CGFloat($0) } == DesignPageCaptures.viewport && entry.scroll != nil
            && entry.window != nil,
          "\(entry.name): a page capture needs its window, the reference viewport and a scroll position")
      }
    }
    return manifest
  }

  // MARK: - Fixtures (ported from AppearanceRenderHarness)

  private static func model(_ capability: PillWordsCapability) -> (
    SettingsManager, PillAppearanceModel, String
  ) {
    let name = "ew.appearanceRender." + UUID().uuidString
    let suite = TestDefaults.suite(name)!
    suite.removePersistentDomain(forName: name)
    let settings = SettingsManager(defaults: suite)
    return (settings, PillAppearanceModel(settings: settings, capability: { capability }), name)
  }

  /// All four App Settings pages, both readers, and retained PR1 Recording Pill coverage.
  enum Page: String {
    case appearance, permissions, privacy, licenses, licenseReader, noticesReader, pill
  }

  static func capability(_ state: String?) throws -> PillWordsCapability {
    switch state {
    case nil, "available": return .available
    case "previewOff": return .previewOff
    case "engineUnsupported": return .engineUnsupported
    case "modelBeingRemoved": return .modelBeingRemoved
    default: throw RenderError("unknown pill state \(state ?? "")")
    }
  }

  struct RenderError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }

  /// One App Settings page or the Recording Pill tab, with its fixtures. `capture` renders it.
  ///
  /// Pages have no header (#3385, which removed the shell's header injection), the Pill
  /// page gets a harmless navigation closure, and Appearance's language and relaunch are never
  /// touched: the page only READS the preference and relaunches on a user's confirmation.
  static func pageView(_ page: Page, pageWidth: CGFloat, capability: PillWordsCapability)
    -> (view: AnyView, suite: String)
  {
    let (settings, pill, suite) = model(capability)
    let content: AnyView =
      switch page {
      case .appearance:
        AnyView(AppSettingsView(selection: .constant(.appearance)).frame(height: 650))
      case .permissions:
        AnyView(AppSettingsView(selection: .constant(.permissions)).frame(height: 650))
      case .privacy: AnyView(AppSettingsView(selection: .constant(.privacy)).frame(height: 850))
      case .licenses: AnyView(AppSettingsView(selection: .constant(.licenses)).frame(height: 650))
      case .licenseReader: AnyView(LicenseDocumentReader(document: .license))
      case .noticesReader: AnyView(LicenseDocumentReader(document: .notices))
      case .pill: AnyView(PillSettingsView().environment(\.settingsPR1Density, true))
      }
    let permissions = PermissionsService(
      accessibilityReader: { false }, microphoneReader: { .denied },
      openMicrophoneSettings: { _ in })
    let root =
      content
      .environment(permissions)
      .environment(settings)
      .environment(pill)
      .environment(\.settingsNavigate, { _ in })
      .frame(width: pageWidth)
    return (AnyView(root), suite)
  }

  /// Fit evidence only: read German from the source catalog, never call an English
  /// fallback a German lookup. New PR1 copy is still pending the integrator's catalog
  /// pass; the three marked drafts below are NOT reviewed translations or app lookup.
  static func germanFitSheet(pageWidth: CGFloat) throws -> AnyView {
    let catalogURL = RepoRoot.url.appending(
      path: "Sources/EnviousWispr/Resources/Localizable.xcstrings")
    let json = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
    let strings = try #require(json["strings"] as? [String: Any])
    let drafts = [
      "A compact pill with a dot and level meter.":
        "Eine kompakte Anzeige mit Punkt und Pegelmesser.",
      "A slim rail that follows your volume.": "Ein schmaler Balken, der deiner Lautstärke folgt.",
      "Shows words as you speak. Turns Live Preview on.":
        "Zeigt Wörter beim Sprechen. Aktiviert die Live-Vorschau.",
    ]
    func german(_ key: String) throws -> String {
      if let entry = strings[key] as? [String: Any],
        let localizations = entry["localizations"] as? [String: Any],
        let de = localizations["de"] as? [String: Any],
        let unit = de["stringUnit"] as? [String: String], let value = unit["value"], !value.isEmpty
      {
        print(
          "GERMAN source-catalog lookup key=\(key) value=\(value) state=\(unit["state"] ?? "unknown"); not a Bundle.main lookup"
        )
        return value
      }
      let value = try #require(drafts[key], "no German lookup or labelled draft for \(key)")
      print("GERMAN UNREVIEWED DRAFT key=\(key) value=\(value)")
      return value
    }
    let pillWidth =
      (pageWidth - 2 * SettingsLayout.contentH - 2 * SettingsLayout.rowPaddingH - 24) / 3
    let chimeWidth = (pageWidth - 2 * SettingsLayout.contentH - 36) / 4
    var rows: [AnyView] = []
    for design in RecordingPillAppearancePanel.displayOrder {
      let name = try german(design.displayName)
      let caption = try german(
        String(localized: DictationSettingsCopy.Pill.shortDescription(for: design)))
      let text = VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: name).font(.stRowLabel).padding(.trailing, 26)
        Text(verbatim: caption).font(.stRowHelper)
      }.fixedSize(horizontal: false, vertical: true)
      let size = PillSettingsLayoutTests.fitting(
        text, width: pillWidth - PillSettingsLayoutTests.captionInset)
      print(
        "GERMAN Pill fit card=\(pillWidth) textWidth=\(pillWidth - PillSettingsLayoutTests.captionInset) fullTextHeight=\(size.height) containsFullText=\(size.width <= pillWidth - PillSettingsLayoutTests.captionInset + 0.5)"
      )
      rows.append(AnyView(text.frame(width: pillWidth - PillSettingsLayoutTests.captionInset)))
    }
    for pairing in RecordingSoundPairing.allCases {
      let name = try german(RecordingChimeCatalog.name(for: pairing))
      let caption = try german(RecordingChimeCatalog.description(for: pairing))
      // Match the new header's minimum-width geometry. These are source text
      // fit checks, still NOT a localized production card or Bundle.main proof.
      let nameWidth = chimeWidth >= 150 ? chimeWidth - 52 : chimeWidth - 48
      let descriptionWidth = chimeWidth >= 150 ? chimeWidth - 52 : chimeWidth - 8
      let text = VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: name).font(.stRowLabel).frame(width: nameWidth, alignment: .leading)
        Text(verbatim: caption).font(.stRowHelper).frame(
          width: descriptionWidth, alignment: .leading)
      }.fixedSize(horizontal: false, vertical: true)
      let size = PillSettingsLayoutTests.fitting(text, width: descriptionWidth)
      print(
        "GERMAN Chime fit \(pairing.rawValue) card=\(chimeWidth) nameWidth=\(nameWidth) descriptionWidth=\(descriptionWidth) fullTextHeight=\(size.height) containsFullText=\(size.width <= descriptionWidth + 0.5)"
      )
      rows.append(AnyView(text.frame(width: chimeWidth - 8)))
    }
    // App Settings' shared rows in the catalog's German (the same values the app ships),
    // including the actionable relaunch copy. Fit evidence, not a saved language change.
    let appKeys = [
      "Appearance",
      "Permissions",
      "Privacy",
      "Licenses",
      "Theme",
      "Choose how EnviousWispr looks.",
      "Choose System to follow your Mac, or choose Light or Dark.",
      "System",
      "Light",
      "Dark",
      "Language",
      "The language of the app interface.",
      "This changes only EnviousWispr. The new language applies after relaunch. System default follows your Mac.",
      "System default",
      "EnviousWispr uses the new language after it relaunches.",
      "Relaunch to apply",
      "Show app in Dock",
      "Keep EnviousWispr in your Dock.",
      "When off, the Dock icon appears only while an EnviousWispr window is open. The menu bar icon always stays.",
    ]
    var de: [String: String] = [:]
    for key in appKeys { de[key] = try german(key) }
    let appRows = VStack(alignment: .leading, spacing: 10) {
      Text(verbatim: "App Settings: catalog German").font(.stRowHelper)
      SettingsTabStrip(
        items: [
          SettingsTabItem(
            id: AppSettingsTab.appearance, icon: "circle.lefthalf.filled",
            label: LocalizedStringResource(stringLiteral: de["Appearance"]!),
            map: .appSettingsTabAppearance),
          SettingsTabItem(
            id: .permissions, icon: "hand.raised",
            label: LocalizedStringResource(stringLiteral: de["Permissions"]!),
            map: .appSettingsTabPermissions),
          SettingsTabItem(
            id: .privacy, icon: "lock.shield",
            label: LocalizedStringResource(stringLiteral: de["Privacy"]!),
            map: .appSettingsTabPrivacy),
          SettingsTabItem(
            id: .licenses, icon: "doc.text",
            label: LocalizedStringResource(stringLiteral: de["Licenses"]!),
            map: .appSettingsTabLicenses),
        ], selection: .constant(.appearance))
      BrandedSection {
        BrandedRow {
          SettingsRow(
            fixtureTitle: de["Theme"]!, icon: "circle.lefthalf.filled",
            resolvedShort: de["Choose how EnviousWispr looks."]!,
            resolvedHelp: de["Choose System to follow your Mac, or choose Light or Dark."]!
          ) {
            BrandedSegmentedPicker(
              options: [
                (de["System"]!, nil, AppearancePreference.system), (de["Light"]!, nil, .light),
                (de["Dark"]!, nil, .dark),
              ], selection: .constant(.system)
            ).fixedSize()
          }
        }
        BrandedRow {
          SettingsRow(
            fixtureTitle: de["Language"]!, icon: "globe",
            resolvedShort: de["The language of the app interface."]!,
            resolvedHelp: de[
              "This changes only EnviousWispr. The new language applies after relaunch. System default follows your Mac."
            ]!
          ) {
            Picker(de["Language"]!, selection: .constant("")) {
              Text(verbatim: de["System default"]!).tag("")
            }.labelsHidden().fixedSize()
          }.rowStatus {
            Text(verbatim: de["EnviousWispr uses the new language after it relaunches."]!)
              .font(.stRowHelper).fixedSize(horizontal: false, vertical: true)
            SettingsActionButton(verbatimTitle: de["Relaunch to apply"]!, isEnabled: true) {}
          }
        }
        BrandedRow(showDivider: false) {
          SettingsRow(
            fixtureTitle: de["Show app in Dock"]!, icon: "dock.rectangle",
            resolvedShort: de["Keep EnviousWispr in your Dock."]!,
            resolvedHelp: de[
              "When off, the Dock icon appears only while an EnviousWispr window is open. The menu bar icon always stays."
            ]!
          ) {
            Toggle("", isOn: .constant(true)).toggleStyle(BrandedToggleStyle()).fixedSize()
          }
        }
      }
    }.frame(width: pageWidth - 32)
    rows.append(AnyView(appRows))
    // This sheet is deliberately labelled fit evidence, not a German page render.
    let sheet = VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: "German text fit: source-catalog values + UNREVIEWED Pill drafts")
        .font(.stRowHelper)
      ForEach(rows.indices, id: \.self) { rows[$0] }
    }.padding(16).frame(width: pageWidth).background(Color.stPageBg)
    return AnyView(sheet)
  }

  // MARK: - Capture

  struct Capture {
    let url: URL
    let pixelsWide: Int
    let pixelsHigh: Int
  }

  /// Render one manifest entry to `<name>.png`, after layout has converged, at backing scale 2.
  static func capture(_ entry: Entry, into directory: URL) throws -> Capture {
    let width = CGFloat(entry.pageWidth)
    let dark = entry.appearance == "dark"
    var suite: String?
    let view: AnyView
    if entry.fixture == "germanFit" {
      view = try germanFitSheet(pageWidth: width)
    } else if entry.fixture.hasPrefix("pill-") {
      // pill-<design>-<rest|locked>
      let parts = entry.fixture.split(separator: "-").map(String.init)
      let design = try #require(
        parts.count == 3 ? RecordingPillDesign(rawValue: parts[1]) : nil,
        "\(entry.name): unknown pill fixture \(entry.fixture)")
      view = DesignPageCaptures.pill(design, locked: parts[2] == "locked")
    } else if entry.fixture.hasPrefix("parts-") {
      let sheet = try #require(
        DesignPartsSheets.sheet(String(entry.fixture.dropFirst("parts-".count))),
        "\(entry.name): unknown parts sheet \(entry.fixture)")
      view = AnyView(sheet.frame(width: width))
    } else {
      let page = try #require(
        Page(rawValue: entry.fixture), "\(entry.name): unknown fixture \(entry.fixture)")
      let made = pageView(page, pageWidth: width, capability: try capability(entry.state))
      view = made.view
      suite = made.suite
    }
    defer {
      // Isolated defaults: remove the capture's own suite once it is written.
      if let suite { TestDefaults.suite(suite)?.removePersistentDomain(forName: suite) }
    }

    let root =
      view
      .environment(\.locale, Locale(identifier: "en_US"))
      .transaction { $0.disablesAnimations = true }
    let host = NSHostingView(rootView: AnyView(root))
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    // The size a measurement asks for: German sheets and pills take their own size; pages keep
    // the declared width and the predecessor's 400pt minimum height.
    let ownSize = ["germanFit", "pill-"].contains { entry.fixture.hasPrefix($0) }
    func target(_ fitting: CGSize) -> CGSize {
      ownSize ? fitting : CGSize(width: width, height: max(fitting.height, 400))
    }
    var size = target(host.fittingSize)
    host.frame = NSRect(origin: .zero, size: size)

    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = host.appearance
    window.contentView = host
    defer {
      window.contentView = nil
      window.close()
    }
    // Readiness: lay out at the measured size and measure again. Some pages measure a few
    // points taller once laid out at their real width (text wrapping), and the window can
    // resize the host to fit, so the capture waits until the measured size, the host's bounds
    // and the size it was laid out at all agree. Bounded: a page that has not settled after
    // five layout passes fails instead of being captured.
    var converged = false
    var passes: [CGSize] = []
    for _ in 0..<5 {
      window.setContentSize(size)
      host.frame = NSRect(origin: .zero, size: size)
      host.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      let measured = target(host.fittingSize)
      passes.append(measured)
      if measured == size && host.bounds.size == size {
        converged = true
        break
      }
      size = measured
    }
    try #require(converged, "\(entry.name): layout did not settle: \(passes)")
    if entry.fixture == "parts-controls" { try focusTheFocusedField(in: host, window: window) }

    return try writePNG(of: host, size: size, name: entry.name, into: directory)
  }

  /// Write what `host` draws now to `<name>.png` at backing scale 2, and check it decodes.
  static func writePNG(of host: NSView, size: CGSize, name: String, into directory: URL) throws
    -> Capture
  {
    let rep = try #require(
      host.bitmapImageRepForCachingDisplay(in: host.bounds),
      "\(name): the host produced no bitmap rep, so this render proved nothing")
    host.cacheDisplay(in: host.bounds, to: rep)
    #expect(
      rep.pixelsWide == Int(size.width * 2) && rep.pixelsHigh == Int(size.height * 2),
      "\(name): backing scale is not 2 (\(rep.pixelsWide)x\(rep.pixelsHigh) for \(size))")
    let png = try #require(rep.representation(using: .png, properties: [:]), "\(name): no PNG")
    let url = directory.appending(path: name + ".png")
    #expect(
      FileManager.default.fileExists(atPath: url.path) == false,
      "\(url.lastPathComponent) rendered twice")
    try png.write(to: url)
    let decoded = try #require(
      NSBitmapImageRep(data: try Data(contentsOf: url)), "\(url.path) does not decode")
    #expect(decoded.pixelsWide > 0 && decoded.pixelsHigh > 0, "\(url.path) is empty")
    return Capture(url: url, pixelsWide: decoded.pixelsWide, pixelsHigh: decoded.pixelsHigh)
  }

  static func editableField(showing text: String, in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField, field.isEditable, field.stringValue == text {
      return field
    }
    for child in view.subviews {
      if let field = editableField(showing: text, in: child) { return field }
    }
    return nil
  }

  /// Stage keyboard focus on the parts sheet's focused field (precedent:
  /// `SettingsTabStopCountTests`, first responder in a borderless test window), then wait for
  /// SwiftUI to report it. The wait is on that signal, bounded by a fixed number of run-loop
  /// turns; no clock. Focus that never arrives fails the capture instead of photographing an
  /// unfocused field.
  static func focusTheFocusedField(in host: NSView, window: NSWindow) throws {
    DesignPartsSheets.focusObserved = false
    let field = try #require(
      editableField(showing: DesignPartsSheets.focusedFieldText, in: host),
      "the parts sheet has no focused-field fixture")
    try #require(window.makeFirstResponder(field), "the field refused first responder")
    var turns = 0
    while !DesignPartsSheets.focusObserved && turns < 50 {
      RunLoop.main.run(mode: .default, before: Date())
      turns += 1
    }
    try #require(
      DesignPartsSheets.focusObserved, "SwiftUI never reported focus on the field (\(turns) turns)")
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
  }

  // MARK: - Run metadata

  static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  static func metadata(manifest: Manifest) -> [String: String] {
    let repo = RepoRoot.url.path
    let status = run("/usr/bin/git", ["-C", repo, "status", "--porcelain"]).output
    let diff = run("/usr/bin/git", ["-C", repo, "diff", "HEAD"]).output
    #if DEBUG
      let configuration = "Debug"
    #else
      let configuration = "Release"
    #endif
    return [
      "machine": run("/usr/sbin/sysctl", ["-n", "hw.model"]).output
        .trimmingCharacters(in: .whitespacesAndNewlines),
      "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
      "toolchain": run("/usr/bin/xcrun", ["swift", "--version"]).output
        .split(separator: "\n").first.map(String.init) ?? "unknown",
      "configuration": configuration,
      "locale": "en_US (German fit sheets: source-catalog values and labelled drafts)",
      "backingScale": "2 (checked per capture)",
      "manifestVersion": String(manifest.version),
      "revision": run("/usr/bin/git", ["-C", repo, "rev-parse", "HEAD"]).output
        .trimmingCharacters(in: .whitespacesAndNewlines),
      "workingTreeChanges": status.isEmpty ? "none" : status,
      "workingTreeDiffBytes": String(diff.utf8.count),
    ]
  }

  // MARK: - The run

  @Test("render every manifest capture once, and nothing else", .enabled(if: enabled))
  func renderManifest() async throws {
    let manifest = try Self.loadManifest()
    let directory = RepoRoot.url.appending(
      path:
        "build/design-render/run-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    var made: [Capture] = []
    var pagesDone: Set<String> = []
    for entry in manifest.entries {
      if entry.fixture.hasPrefix("page:") {
        // One render per page, width and appearance; every scroll position in manifest order.
        let key = "\(entry.fixture)|\(entry.window ?? 0)|\(entry.appearance)"
        guard pagesDone.insert(key).inserted else { continue }
        let shots = manifest.entries.filter {
          $0.fixture == entry.fixture && $0.window == entry.window
            && $0.appearance == entry.appearance
        }
        #expect(
          shots.map(\.scroll) == Array(0..<shots.count).map { Optional($0) },
          "\(key): scroll positions are not 0..<\(shots.count) in order")
        let captures = try await DesignPageCaptures.capturePage(
          label: String(entry.fixture.dropFirst("page:".count)), width: CGFloat(entry.pageWidth),
          dark: entry.appearance == "dark", names: shots.map(\.name), into: directory)
        for (shot, capture) in zip(shots, captures) {
          print("RENDERED \(shot.name): png \(capture.pixelsWide)x\(capture.pixelsHigh)")
        }
        made += captures
        continue
      }
      let capture = try Self.capture(entry, into: directory)
      print("RENDERED \(entry.name): png \(capture.pixelsWide)x\(capture.pixelsHigh)")
      made.append(capture)
    }

    let meta = try JSONSerialization.data(
      withJSONObject: Self.metadata(manifest: manifest), options: [.prettyPrinted, .sortedKeys])
    try meta.write(to: directory.appending(path: "run-metadata.json"))

    let written = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { $0.hasSuffix(".png") }
    #expect(
      Set(written) == Set(manifest.entries.map { $0.name + ".png" }),
      "the run folder does not match the manifest")
    #expect(
      made.count == manifest.entries.count,
      "rendered \(made.count) of \(manifest.entries.count) captures")
    print("DESIGN RENDER RUN: \(made.count) captures -> \(directory.path)")
  }

  // MARK: - Comparator controls (the real pixel-diff.py on temporary fixtures)

  /// A PNG written from exact, unpremultiplied RGBA samples.
  /// With `alpha: false` the samples are RGB, three per pixel, and the PNG has no alpha channel.
  static func writePNG(
    _ pixels: [UInt8], width: Int, height: Int, alpha: Bool = true, to url: URL
  ) throws {
    let samples = alpha ? 4 : 3
    let rep = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
        samplesPerPixel: samples, hasAlpha: alpha, isPlanar: false, colorSpaceName: .deviceRGB,
        bitmapFormat: alpha ? [.alphaNonpremultiplied] : [], bytesPerRow: width * samples,
        bitsPerPixel: samples * 8))
    let base = try #require(rep.bitmapData)
    for (index, value) in pixels.enumerated() { base[index] = value }
    try #require(rep.representation(using: .png, properties: [:])).write(to: url)
  }

  static func pixelDiff(_ before: URL, _ after: URL, manifest: URL) -> (
    status: Int32, output: String
  ) {
    run(
      "/usr/bin/python3",
      [
        pixelDiffURL.path, before.path, after.path, "--manifest", manifest.path,
        "--diff-dir", after.path + "-diff",
      ])
  }

  @Test("pixel-diff.py passes equal pixels and fails every bad input", .enabled(if: enabled))
  func comparatorControls() throws {
    let root = TestTemporaryDirectory.url.appending(path: "design-pixel-diff-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = root.appending(path: "manifest.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data(#"{"entries": [{"name": "a"}, {"name": "b"}]}"#.utf8).write(to: manifest)

    let base: [UInt8] = [10, 20, 30, 255, 40, 50, 60, 255, 70, 80, 90, 255, 100, 110, 120, 255]
    func folder(
      _ name: String, b: [UInt8]? = base, bSize: (Int, Int) = (2, 2)
    ) throws -> URL {
      let url = root.appending(path: name)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      try Self.writePNG(base, width: 2, height: 2, to: url.appending(path: "a.png"))
      if let b {
        try Self.writePNG(b, width: bSize.0, height: bSize.1, to: url.appending(path: "b.png"))
      }
      return url
    }
    let reference = try folder("reference")

    let equal = Self.pixelDiff(reference, try folder("equal"), manifest: manifest)
    #expect(equal.status == 0, "equal pixels must pass: \(equal.output)")

    var changed = base
    changed[4] = 41
    let oneChanged = Self.pixelDiff(
      reference, try folder("changed", b: changed), manifest: manifest)
    #expect(
      oneChanged.status == 1 && oneChanged.output.contains("b.png: 1 differing pixels"),
      "\(oneChanged.output)")

    // Partial alpha: two colours at alpha 1/255 that 8-bit premultiplication would round together.
    let faintA: [UInt8] = [10, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    var faintB = faintA
    faintB[0] = 11
    let faint = Self.pixelDiff(
      try folder("faint-reference", b: faintA), try folder("faint", b: faintB), manifest: manifest)
    #expect(
      faint.status == 1 && faint.output.contains("b.png: 1 differing pixels"),
      "partial alpha lost: \(faint.output)")

    let missing = Self.pixelDiff(reference, try folder("missing", b: nil), manifest: manifest)
    #expect(missing.status == 2 && missing.output.contains("missing"), "\(missing.output)")

    let extraFolder = try folder("extra")
    try Self.writePNG(base, width: 2, height: 2, to: extraFolder.appending(path: "c.png"))
    let extra = Self.pixelDiff(reference, extraFolder, manifest: manifest)
    #expect(extra.status == 2 && extra.output.contains("extra"), "\(extra.output)")

    let emptyFolder = try folder("empty", b: nil)
    try Data().write(to: emptyFolder.appending(path: "b.png"))
    let empty = Self.pixelDiff(reference, emptyFolder, manifest: manifest)
    #expect(empty.status == 2 && empty.output.contains("cannot decode"), "\(empty.output)")

    let resized = Self.pixelDiff(
      reference, try folder("resized", b: base + base, bSize: (2, 4)), manifest: manifest)
    #expect(resized.status == 2 && resized.output.contains("size"), "\(resized.output)")

    // The same opaque pixels stored with and without an alpha channel compare equal.
    let rgbFolder = try folder("rgb-storage", b: nil)
    let rgb = stride(from: 0, to: base.count, by: 4).flatMap { base[$0..<($0 + 3)] }
    try Self.writePNG(
      rgb, width: 2, height: 2, alpha: false, to: rgbFolder.appending(path: "b.png"))
    let storage = Self.pixelDiff(reference, rgbFolder, manifest: manifest)
    #expect(
      storage.status == 0, "equal pixels in another storage format must pass: \(storage.output)")
  }

  // MARK: - Parts coverage (independent of what the run emits)

  /// Every name in DESIGN.md's "Approved parts" table must be shown on a parts sheet, and every
  /// parts sheet must have a light and a dark manifest entry. Reads DESIGN.md, so it exists only
  /// on revisions that have the design book.
  @Test("the parts sheets show every DESIGN.md approved part, in light and dark")
  func partsSheetsCoverTheBook() throws {
    let book = try String(contentsOf: RepoRoot.url.appending(path: "DESIGN.md"), encoding: .utf8)
    let section = try #require(
      book.components(separatedBy: "## Approved parts").dropFirst().first?
        .components(separatedBy: "\n## ").first, "DESIGN.md has no Approved parts section")
    var listed: Set<String> = []
    for line in section.split(separator: "\n") where line.hasPrefix("| `") {
      let firstColumn = line.split(separator: "|", omittingEmptySubsequences: true).first ?? ""
      for (index, piece) in firstColumn.split(separator: "`", omittingEmptySubsequences: false)
        .enumerated() where index % 2 == 1 && !piece.hasSuffix(".swift")
      {
        listed.insert(String(piece))
      }
    }
    #expect(listed.count >= 20, "suspiciously few approved parts parsed: \(listed.sorted())")
    let missing = listed.subtracting(DesignPartsSheets.coverage.keys).sorted()
    let unknown = Set(DesignPartsSheets.coverage.keys).subtracting(listed).sorted()
    #expect(missing.isEmpty, "DESIGN.md approved parts not on a parts sheet: \(missing)")
    #expect(unknown.isEmpty, "parts-sheet entries not in DESIGN.md: \(unknown)")

    let manifest = try Self.loadManifest()
    for sheet in Set(DesignPartsSheets.coverage.values) {
      #expect(DesignPartsSheets.sheet(sheet) != nil, "no builder for parts sheet \(sheet)")
      for mode in ["light", "dark"] {
        #expect(
          manifest.entries.contains { $0.fixture == "parts-\(sheet)" && $0.appearance == mode },
          "manifest has no \(mode) capture of parts sheet \(sheet)")
      }
    }
  }
}
