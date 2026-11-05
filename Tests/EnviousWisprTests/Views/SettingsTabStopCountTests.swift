import AppKit
import SwiftUI
import Testing

/// The Settings tab-stop counter (`SettingsMapRenderingTests.keyViewCount`) counts what a page
/// declares, whether or not a text field holds focus at the counting instant (#4224).
@MainActor
@Suite("Settings tab-stop count ignores focus (#4224)", .tags(.harnessContract))
struct SettingsTabStopCountTests {
  init() { _ = NSApplication.shared }

  private func editableField(in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField, field.isEditable { return field }
    for child in view.subviews {
      if let field = editableField(in: child) { return field }
    }
    return nil
  }

  private func hasFieldEditor(_ view: NSView) -> Bool {
    if let editor = view as? NSTextView, editor.isFieldEditor { return true }
    return view.subviews.contains { hasFieldEditor($0) }
  }

  @Test("focusing a secure field adds AppKit's field editor, and the count stays the same")
  func focusDoesNotChangeTheCount() throws {
    struct Page: View {
      @State var text = "fixture-not-a-key"
      var body: some View { SecureField("Key", text: $text).frame(width: 200) }
    }
    let host = NSHostingView(rootView: Page())
    host.frame = CGRect(x: 0, y: 0, width: 300, height: 100)
    let window = NSWindow(
      contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    defer { window.contentView = nil }
    host.layoutSubtreeIfNeeded()
    let unfocused = SettingsMapRenderingTests.keyViewCount(host)
    #expect(unfocused == 1)
    #expect(hasFieldEditor(host) == false)

    let field = try #require(editableField(in: host))
    try #require(window.makeFirstResponder(field))
    host.layoutSubtreeIfNeeded()
    // Positive control: focus really inserted the field editor the counter must skip.
    #expect(hasFieldEditor(host))
    #expect(SettingsMapRenderingTests.keyViewCount(host) == unfocused)
  }
}
