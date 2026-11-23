import AppKit
import SwiftUI

/// Requests keyboard focus once the actual Practice editor and its key window are both present.
struct SetupPracticeEditorFocus: NSViewRepresentable {
  let canFocus: Bool
  let mayFocusNow: @MainActor () -> Bool

  func makeNSView(context: Context) -> Probe { Probe() }

  func updateNSView(_ probe: Probe, context: Context) {
    probe.configure(canFocus: canFocus, mayFocusNow: mayFocusNow)
  }

  final class Probe: NSView {
    private var canFocus = false
    private var mayFocusNow: @MainActor () -> Bool = { false }
    private var requestQueued = false

    func configure(
      canFocus: Bool, mayFocusNow: @escaping @MainActor () -> Bool
    ) {
      let request = canFocus && !self.canFocus
      self.canFocus = canFocus
      self.mayFocusNow = mayFocusNow
      if request { requestFocus() }
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      let center = NotificationCenter.default
      center.removeObserver(self)
      guard let window else { return }
      center.addObserver(
        self, selector: #selector(requestFocus), name: NSWindow.didBecomeKeyNotification,
        object: window)
      requestFocus()
    }

    @objc private func requestFocus() {
      guard canFocus, !requestQueued, let window, window.isKeyWindow else { return }
      requestQueued = true
      // TextEditor can still be attaching during the representable update.
      DispatchQueue.main.async { [weak self, weak window] in
        guard let self else { return }
        self.requestQueued = false
        guard let window, window === self.window, window.isKeyWindow,
          self.canFocus, self.mayFocusNow(), let editor = self.nativeEditor()
        else { return }
        if window.firstResponder !== editor { window.makeFirstResponder(editor) }
      }
    }

    private func nativeEditor() -> NSTextView? {
      // The probe sits on the TextEditor. Use the nearest ancestor containing an editor,
      // and refuse to pick a target if that ancestor contains more than one.
      var parent = superview
      while let view = parent {
        let editors = Self.editors(in: view)
        if !editors.isEmpty { return editors.count == 1 ? editors.first : nil }
        parent = view.superview
      }
      return nil
    }

    private static func editors(in view: NSView) -> [NSTextView] {
      if let editor = view as? NSTextView, editor.isEditable { return [editor] }
      return view.subviews.flatMap { editors(in: $0) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    deinit { NotificationCenter.default.removeObserver(self) }
  }
}
