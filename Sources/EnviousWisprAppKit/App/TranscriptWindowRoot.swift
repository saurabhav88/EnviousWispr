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

  var body: some View {
    HistoryTranscriptView(
      rowID: rowID, context: .window, sources: b.importedSources,
      retranscription: b.transcriptRetranscription,
      // Already in its own window: another window for the same row would only bring this one
      // forward, so the action does nothing here.
      openInNewWindow: { _ in }
    )
    .frame(minWidth: 520, minHeight: 420)
    .background(Color.stPageBg)
    .background(TranscriptWindowRegistrar(coordinator: b.appWindowCoordinator))
    .task {
      b.importedSources.invalidateAll()
      await b.importedModelCatalog.refresh()
    }
    .appHomes(b)
  }
}

/// Hands the hosting window to the coordinator once the view is in it.
private struct TranscriptWindowRegistrar: NSViewRepresentable {
  let coordinator: AppWindowCoordinator

  func makeNSView(context: Context) -> RegistrarView {
    RegistrarView(coordinator: coordinator)
  }

  func updateNSView(_ nsView: RegistrarView, context: Context) {}

  final class RegistrarView: NSView {
    private let coordinator: AppWindowCoordinator

    init(coordinator: AppWindowCoordinator) {
      self.coordinator = coordinator
      super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window else { return }
      coordinator.registerTranscriptWindow(window)
    }
  }
}
