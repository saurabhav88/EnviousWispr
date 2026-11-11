import EnviousWisprCore
import EnviousWisprLocalPolish
import EnviousWisprServices

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

  /// The sizes installed and current now.
  var installedSizes: Set<EGOneSize> {
    Set(
      EGOneSize.allCases.filter {
        if case .installed = installState($0) { true } else { false }
      })
  }

  /// Remove the pressed size (plan §3.1.1 S9). The selection moves in THIS turn, before the
  /// runtime's own asynchronous checks read it, so a removal of the size in use is never
  /// refused as "still selected" and no surface is left on a size that is going away. A
  /// recording, import or summary that froze the size keeps it: the runtime defers the
  /// deletion until that work ends.
  func remove(_ size: EGOneSize, settings: SettingsManager, recommendation: EGOneSize) {
    let outcome = EGOneSizeRemoval.outcome(
      removing: size, preference: settings.egOneSize, installed: installedSizes,
      recommendation: recommendation)
    runtime(size)?.removeModel()
    Self.apply(outcome, to: settings)
  }

  static func apply(_ outcome: EGOneSizeRemoval.Outcome, to settings: SettingsManager) {
    switch outcome {
    case .preferenceUnchanged: break
    case .moveTo(let size): settings.selectEGOneSize(size)
    case .leaveEGOne(let reset):
      settings.selectEGOneSize(reset)
      BundledEngineRemoval.moveSurfaces(off: .egOne, in: settings)
    }
  }
}
