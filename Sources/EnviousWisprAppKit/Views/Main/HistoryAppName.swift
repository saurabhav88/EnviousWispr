import AppKit

/// Resolves History's display label while its filter continues to match the saved identifier.
@MainActor
enum HistoryAppName {
  private static var namesByIdentifier: [String: String] = [:]

  static func label(for recordedApp: String) -> String {
    if let name = namesByIdentifier[recordedApp] { return name }
    let name = label(for: recordedApp, installedName: installedName(for:))
    namesByIdentifier[recordedApp] = name
    return name
  }

  static func label(for recordedApp: String, installedName: (String) -> String?) -> String {
    let name = recordedApp.trimmingCharacters(in: .whitespacesAndNewlines)
    // ChatGPT reports this identifier for Codex. History names the experience the user used.
    if name.lowercased() == "com.openai.codex" { return "Codex" }
    guard let lastComponent = bundleIDComponents(name)?.last else { return name }
    if let installed = installedName(name)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !installed.isEmpty, bundleIDComponents(installed) == nil
    {
      return installed
    }
    return lastComponent.split(separator: "-").map { word in
      word.prefix(1).uppercased() + word.dropFirst()
    }.joined(separator: " ")
  }

  private static func installedName(for identifier: String) -> String? {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
      return nil
    }
    let bundle = Bundle(url: url)
    for key in ["CFBundleDisplayName", "CFBundleName"] {
      if let name = bundle?.object(forInfoDictionaryKey: key) as? String,
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        bundleIDComponents(name) == nil
      {
        return name
      }
    }
    return url.deletingPathExtension().lastPathComponent
  }

  private static func bundleIDComponents(_ value: String) -> [Substring]? {
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count > 1, let domain = parts.first, domain == domain.lowercased(),
      parts.allSatisfy({ part in
        !part.isEmpty && part.allSatisfy { character in
          character.isASCII && (character.isLetter || character.isNumber || character == "-")
        }
      })
    else { return nil }
    return parts
  }
}
