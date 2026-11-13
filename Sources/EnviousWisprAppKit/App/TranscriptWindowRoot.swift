import AppKit
import SwiftUI

/// #3147 PR3: the detached transcript window's scene id and value. One window per History row:
/// SwiftUI's `WindowGroup(for: UUID.self)` brings an open row's window forward instead of
/// opening a second one.
package enum TranscriptWindowIdentity {
  package static let sceneID = "history.transcript"
  package static let title = String(
    localized: "Transcript", comment: "Window menu name for a transcript opened in its own window.")
}

/// The detached transcript window's root (#3147 PR3 §8). The same homes as the main window, so
/// the transcript, its player, Transcribe again with and the source owner are the very objects
/// History uses: a job started in one window shows in the other.
///
/// The window registers itself with `AppWindowCoordinator` once AppKit hands it a window, so
/// closing the main window keeps the Dock icon and app menu while this one is open. It is never
/// found by its title, which is the translated file name.
struct TranscriptWindowRoot: View {
  let b: WisprBootstrapper
  let rowID: UUID
  /// #4101: this window's Paste notice, held outside the replaceable transcript content.
  @State private var pasteNotice = HistoryPasteNotice()
  /// The window this root is in, so Paste brings back THIS window. Weak.
  @State private var hostWindow = WeakWindow()

  var body: some View {
    HistoryTranscriptView(
      rowID: rowID, context: .window, sources: b.importedSources,
      retranscription: b.transcriptRetranscription,
      // Already in its own window: another window for the same row would only bring this one
      // forward, so the action does nothing here.
      openInNewWindow: { _ in },
      showPasteNotice: pasteNotice.show,
      restorePasteSurface: { [hostWindow] in
        hostWindow.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
      }
    )
    .frame(minWidth: 520, minHeight: 420)
    .background(Color.stPageBg)
    .background(
      TranscriptWindowRegistrar(coordinator: b.appWindowCoordinator, hostWindow: hostWindow))
    .alert(
      pasteNotice.text ?? "",
      isPresented: Binding(
        get: { pasteNotice.text != nil }, set: { if !$0 { pasteNotice.dismiss() } })
    ) {
      Button(String(localized: "OK", comment: "History: closes the Paste message.")) {
        pasteNotice.dismiss()
      }
    }
    .task {
      b.importedSources.invalidateAll()
      await b.importedModelCatalog.refresh()
    }
    .appHomes(b)
  }
}

/// A weak reference to the transcript window, filled in by the registrar.
@MainActor
private final class WeakWindow {
  weak var window: NSWindow?
}

/// Hands the hosting window to the coordinator once the view is in it.
private struct TranscriptWindowRegistrar: NSViewRepresentable {
  let coordinator: AppWindowCoordinator
  let hostWindow: WeakWindow

  func makeNSView(context: Context) -> RegistrarView {
    RegistrarView(coordinator: coordinator, hostWindow: hostWindow)
  }

  func updateNSView(_ nsView: RegistrarView, context: Context) {}

  final class RegistrarView: NSView {
    private let coordinator: AppWindowCoordinator
    private let hostWindow: WeakWindow

    init(coordinator: AppWindowCoordinator, hostWindow: WeakWindow) {
      self.coordinator = coordinator
      self.hostWindow = hostWindow
      super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window else { return }
      hostWindow.window = window
      coordinator.registerTranscriptWindow(window)
    }
  }
}
