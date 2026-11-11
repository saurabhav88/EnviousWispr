import EnviousWisprCore
import EnviousWisprLocalPolish

/// #4473: the download controls of ONE EG-1 size, each reaching that size's own runtime.
///
/// The size cards and the DEBUG dev-control commands both press these, so a card and a
/// command for the same size cannot reach different owners. A size is always named by the
/// caller: nothing here falls back to another size. Each runtime keeps its own guards and
/// schedules its own work, so a call returning means the button was pressed, never that a
/// download finished or a cancel drained.
@MainActor
struct EGOneSizeActions {
  let runtimes: LocalPolishRuntimeSet

  private func runtime(_ size: EGOneSize) -> LocalPolishRuntime? {
    runtimes.runtime(for: .egOne(size))
  }

  /// Start the size's download, or continue an interrupted one.
  func download(_ size: EGOneSize) { runtime(size)?.startDownload() }

  func cancel(_ size: EGOneSize) { runtime(size)?.cancelDownload() }

  /// The size's install state; nil when this build has no runtime for it.
  func installState(_ size: EGOneSize) -> EGOneInstallState? { runtime(size)?.installState }
}
