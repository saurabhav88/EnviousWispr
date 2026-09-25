@testable import EnviousWisprAppKit

/// Stand-in for the Dock-policy owner Sparkle reports to (#2480). Records rather than
/// acting: the real owner moves the running app between accessory and regular, which a
/// unit test must never do to the developer's machine (#2455 C3).
@MainActor
final class RecordingUpdateDialogPresenter: UpdateDialogPresenting {
  enum Call: Equatable {
    case dialogWillShow
    case sessionDidEnd
  }

  private(set) var calls: [Call] = []

  func updateDialogWillShow() { calls.append(.dialogWillShow) }
  func updateSessionDidEnd() { calls.append(.sessionDidEnd) }
}
