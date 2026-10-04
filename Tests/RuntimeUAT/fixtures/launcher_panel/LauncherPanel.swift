// Launcher-panel fixture for #3423 Live UAT (`paste_landing_uat.py` launcher phases).
//
// A floating launcher (Raycast, Alfred) shows a NON-ACTIVATING panel: it takes the keyboard focus
// while the Mac still reports the app behind it as the front application. This fixture is that
// window and nothing else: an accessory app (no Dock icon, `LSUIElement`) whose titled
// `.nonactivatingPanel` becomes key without activating the app.
//
// Two real text controls, so one take exercises each paste route:
// - field A accepts Accessibility writes, so the paste's direct write (Tier 1, `ax_direct`) lands.
// - field B is typed into normally but ignores Accessibility writes: the write call reports
//   success and the text and character count stay unchanged, so Tier 1 verifies no mutation and
//   the take reaches the key paste (Tier 2, `cgevent`), the route the ENVIOUSWISPR-6G report
//   ended on. (Measured 2026-10-03: `AXSelectedText` still reads as settable.)
//
// Usage: LauncherPanel <run-dir> <A|B>
// The fixture writes `<run-dir>/state.json` (atomically, on every change and every 100 ms):
// pid, bundle, ready, key, focused field, closed, and both fields' text. It polls `<run-dir>` for
// command files, each removed once handled:
//   `dismiss`            hide the panel (a launcher closed mid-take)
//   `select <field> <s>` select the first occurrence of <s> in that field (a user about to retype)
//   `quit`               terminate
// Build: `Tests/RuntimeUAT/fixtures/launcher_panel/build.sh` (output under the worktree's `build/`).
import AppKit

final class FixtureTextView: NSTextView {
  var refusesAccessibilityWrites = false
  var onChange: (() -> Void)?

  override func didChangeText() {
    super.didChangeText()
    onChange?()
  }

  private static let refusedSetters: Set<Selector> = [
    NSSelectorFromString("setAccessibilityValue:"),
    NSSelectorFromString("setAccessibilitySelectedText:"),
  ]

  override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
    if refusesAccessibilityWrites, Self.refusedSetters.contains(selector) { return false }
    return super.isAccessibilitySelectorAllowed(selector)
  }

  override func setAccessibilityValue(_ value: Any?) {
    if refusesAccessibilityWrites { return }
    super.setAccessibilityValue(value)
  }

  override func setAccessibilitySelectedText(_ text: String?) {
    if refusesAccessibilityWrites { return }
    super.setAccessibilitySelectedText(text)
  }
}

final class KeyPanel: NSPanel {
  override var canBecomeKey: Bool { true }
}

@MainActor
final class Fixture: NSObject, NSApplicationDelegate {
  let runDir: URL
  let focusName: String
  var panel: KeyPanel!
  var fields: [String: FixtureTextView] = [:]
  var closed = false
  /// The fields' text at the moment the panel closed; the state file keeps reporting it.
  var closedTexts: [String: String] = [:]
  var ready = false
  var lastWritten = Data()

  init(runDir: URL, focusName: String) {
    self.runDir = runDir
    self.focusName = focusName
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    panel = KeyPanel(
      contentRect: NSRect(x: 480, y: 420, width: 520, height: 170),
      styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.title = "EnviousWispr UAT launcher panel (#3423, safe to ignore)"
    panel.level = .floating
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    for (index, name) in ["A", "B"].enumerated() {
      let view = FixtureTextView(
        frame: NSRect(x: 12, y: 92 - CGFloat(index) * 80, width: 496, height: 66))
      view.isRichText = false
      view.isEditable = true
      view.font = .systemFont(ofSize: 14)
      view.refusesAccessibilityWrites = name == "B"
      view.setAccessibilityLabel("Launcher field \(name)")
      view.onChange = { [weak self] in self?.writeState() }
      panel.contentView?.addSubview(view)
      fields[name] = view
    }
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(fields[focusName] ?? fields["A"])
    ready = true
    writeState()
    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.handleCommands()
        self?.writeState()
      }
    }
  }

  func focusedField() -> String? {
    guard let responder = panel.firstResponder as? FixtureTextView else { return nil }
    return fields.first { $0.value === responder }?.key
  }

  func handleCommands() {
    let manager = FileManager.default
    if manager.fileExists(atPath: runDir.appendingPathComponent("dismiss").path) {
      try? manager.removeItem(at: runDir.appendingPathComponent("dismiss"))
      // A launcher's panel is torn down when it closes, so its fields' Accessibility elements stop
      // answering. Keep the last text for the oracle, then release the views.
      closedTexts = fields.mapValues { $0.string }
      for view in fields.values { view.removeFromSuperview() }
      fields = [:]
      panel.close()
      closed = true
    }
    let selectURL = runDir.appendingPathComponent("select")
    if let command = try? String(contentsOf: selectURL, encoding: .utf8) {
      try? manager.removeItem(at: selectURL)
      let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
      if parts.count == 2, let view = fields[parts[0]] {
        let range = (view.string as NSString).range(of: parts[1].trimmingCharacters(in: .newlines))
        if range.location != NSNotFound {
          panel.makeFirstResponder(view)
          view.setSelectedRange(range)
        }
      }
    }
    if manager.fileExists(atPath: runDir.appendingPathComponent("quit").path) {
      try? manager.removeItem(at: runDir.appendingPathComponent("quit"))
      writeState()
      NSApp.terminate(nil)
    }
  }

  func writeState() {
    let state: [String: Any] = [
      "pid": Int(ProcessInfo.processInfo.processIdentifier),
      "bundle": Bundle.main.bundleIdentifier ?? "",
      "ready": ready,
      "key": panel?.isKeyWindow ?? false,
      "app_active": NSApp.isActive,
      "focused": focusedField() ?? "",
      "closed": closed,
      "fields": closed ? closedTexts : fields.mapValues { $0.string },
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
      data != lastWritten
    else { return }
    let target = runDir.appendingPathComponent("state.json")
    let temp = runDir.appendingPathComponent(".state.json.tmp")
    do {
      try data.write(to: temp)
      _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
      lastWritten = data
    } catch {
      // A missed write is retried on the next tick; the harness waits for the value it needs.
    }
  }
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
  FileHandle.standardError.write(Data("usage: LauncherPanel <run-dir> <A|B>\n".utf8))
  exit(2)
}
let app = NSApplication.shared
let delegate = Fixture(runDir: URL(fileURLWithPath: arguments[1]), focusName: arguments[2])
app.delegate = delegate
app.run()
