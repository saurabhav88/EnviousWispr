import Foundation
import Testing

@testable import EnviousWisprAppKit

/// #3482: the one extraction owner for Settings Map metadata outside the app. Opt-in: it runs only
/// when the runner sets `TEST_RUNNER_EW_SETTINGS_MAP_EXPORT=<output path>` (and, for one place,
/// `TEST_RUNNER_EW_SETTINGS_MAP_EXPORT_ID=<id>`). `scripts/settings-map/draft-vocabulary.sh` uses it
/// to build an isolated drafting brief; Chunk 5's exporter reuses it. English and German text
/// come from the compiled String Catalog in the app test host. It exports owned copy and static
/// structure only: a runtime-named title gives its resolver's name, never a sampled value, so no
/// device name, key draft, custom word or other live state can leave the machine through it.
@Suite(
  "Settings Map export (#3482, opt-in)", .tags(.harnessContract),
  .enabled(if: ProcessInfo.processInfo.environment["EW_SETTINGS_MAP_EXPORT"] != nil))
struct SettingsMapExportTests {
  /// The app this test target was built with: tests run unhosted, so `Bundle.main` is the test
  /// runner, and the compiled String Catalog lives in the sibling `EnviousWispr.app`.
  static let app = Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent()
    .appendingPathComponent("EnviousWispr.app")

  /// English as the source default; German read from the built app's compiled `de.lproj`
  /// table. Nil when that table has no entry for the key.
  static func localized(_ resource: LocalizedStringResource, _ code: String) -> String? {
    guard code != "en" else { return String(localized: resource) }
    guard let bundle = Bundle(url: app.appendingPathComponent("Contents/Resources/\(code).lproj"))
    else { return nil }
    let missing = "\u{0}missing"
    let value = bundle.localizedString(forKey: resource.key, value: missing, table: resource.table)
    return value == missing ? nil : value
  }

  static func json(_ text: String?) -> Any { text ?? NSNull() }

  static func text(_ title: SettingsMapTitle) -> [String: Any] {
    switch title {
    case .resource(let resource):
      ["source": "resource", "en": json(localized(resource, "en")), "de": json(localized(resource, "de"))]
    case .verbatim(let text): ["source": "verbatim", "text": text]
    case .dynamic(let resolver): ["source": "dynamic", "resolver": "\(resolver)"]
    }
  }

  static func text(_ description: SettingsMapDescription?) -> Any {
    switch description {
    case .resource(let resource)?:
      ["source": "resource", "en": json(localized(resource, "en")), "de": json(localized(resource, "de"))]
    case .runtime?: ["source": "runtime"]
    case nil: NSNull()
    }
  }

  static func export(_ entry: SettingsSearchCatalog.Entry) -> [String: Any] {
    let node = entry.node
    var context: [[String: Any]] = []
    var parent = node.parent
    while let id = parent, id != .windowSettings {
      let ancestor = SettingsMap.node(id)
      context.insert(
        ["id": id.rawValue, "structure": "\(ancestor.structure)", "title": text(ancestor.title)],
        at: 0)
      parent = ancestor.parent
    }
    return [
      "id": entry.id,
      "kind": entry.kind.rawValue,
      "context": context,
      "title": text(node.title),
      "description": text(node.description),
      "destination": node.destination.map { "\($0)" } ?? NSNull(),
      "dictionaryTab": node.dictionaryTab.map { "\($0)" } ?? NSNull(),
      "visibility": "\(node.visibility)",
      "target": node.target?.rawValue ?? NSNull(),
      "fallbacks": node.fallbacks.map(\.rawValue),
    ]
  }

  @Test("export the searchable places' metadata")
  func exportMetadata() throws {
    let environment = ProcessInfo.processInfo.environment
    let output = URL(fileURLWithPath: try #require(environment["EW_SETTINGS_MAP_EXPORT"]))
    // The built app must hold the German catalog, or every German field would silently be English.
    let page = try #require(SettingsPage.dictation.labelResource)
    guard let german = Self.localized(page, "de"), german == "Diktateinstellungen" else {
      Issue.record("the built app has no German catalog at \(Self.app.path)")
      return
    }

    var entries = SettingsSearchCatalog.entries
    if let id = environment["EW_SETTINGS_MAP_EXPORT_ID"] {
      guard let entry = entries.first(where: { $0.id == id }) else {
        let structural = SettingsMap.nodes.contains { $0.id.rawValue == id }
        Issue.record(
          structural
            ? "\(id) is a structural Settings Map node; it has no vocabulary"
            : "\(id) is not a searchable Settings Map id (unknown, renamed or exempt)")
        return
      }
      entries = [entry]
    }
    let document: [String: Any] = [
      "schema": "settings-map-export", "version": 1, "entries": entries.map(Self.export),
    ]
    let data = try JSONSerialization.data(
      withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    let staging = output.appendingPathExtension("partial")
    try data.write(to: staging)
    try? FileManager.default.removeItem(at: output)
    try FileManager.default.moveItem(at: staging, to: output)
  }

  private final class BundleMarker {}
}
