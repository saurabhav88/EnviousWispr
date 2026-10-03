import Foundation

/// #3385: summary vocabulary only. Delivery failures retain ModelDeliveryCopy's remedies.
enum EngineSummaryCopy {
  static let modelReady = String(localized: "Model ready", comment: "Settings: model files are currently admitted on this Mac.")
  static let modelNotSetUp = String(localized: "Model not set up", comment: "Settings: model files are not currently admitted.")
  static let checking = String(localized: "Checking model status...", comment: "Settings: a read-only model status check is running.")
  static let recheckFast: LocalizedStringResource = "Re-check Fast model status"
  static let ready = String(localized: "Ready", comment: "Settings: the selected preview engine can run for the current language.")
  static let off = String(localized: "Off", comment: "Settings: Live Preview is switched off.")
  static let auto = String(localized: "Auto", comment: "Settings: prefix identifying automatic language mode.")

  static func installedPacks(installed: Int, total: Int) -> String {
    String(localized: "\(installed) of \(total) installed on this Mac", comment: "Live Preview: actual installed and total language counts from the loaded macOS inventory.")
  }
}
