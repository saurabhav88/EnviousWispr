import AppKit
import EnviousWisprPipeline
import Testing

@testable import EnviousWisprAppKit

/// #1480 — the Bluetooth card is a normal single-slot overlay intent: recording
/// must supersede it synchronously through the existing dedup, and it must never
/// linger in the intent state. `currentIntent` is mutated synchronously in
/// `show(intent:)`; panel creation is deferred, so these assertions hold headless.
@Suite @MainActor struct BluetoothAwarenessOverlayTests {
  /// `show(intent:)` posts an accessibility announcement against `NSApp.mainWindow`;
  /// `NSApp` is an implicitly-unwrapped `NSApplication!` that stays nil until
  /// `NSApplication.shared` is first accessed (AppearanceController.swift note), so
  /// touching it here keeps the AX post from crashing the headless test host.
  init() { _ = NSApplication.shared }

  @Test func recordingSupersedesBluetoothCardSynchronously() {
    let overlay = RecordingOverlayPanel()
    overlay.show(intent: .bluetoothAwareness)
    #expect(overlay.currentIntent == .bluetoothAwareness)

    overlay.show(intent: .recording(audioLevel: 0))
    #expect(overlay.currentIntent == .recording(audioLevel: 0))

    // Cancel the deferred panel-creation work so no NSPanel is built headless.
    overlay.hide()
    #expect(overlay.currentIntent == .hidden)
  }

  @Test func hideClearsBluetoothCardIntent() {
    let overlay = RecordingOverlayPanel()
    overlay.show(intent: .bluetoothAwareness)
    overlay.hide()
    #expect(overlay.currentIntent == .hidden)
  }
}
