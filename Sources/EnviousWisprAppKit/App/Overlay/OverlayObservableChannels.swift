import AppKit
import EnviousWisprCore
import EnviousWisprPipeline
import SwiftUI

// MARK: - The two legacy observable channels

/// Observable state holder for hands-free lock mode.
///
/// **Kept, not removed, and this file is why.** With one retained window every
/// change is a morph, so a channel that exists so a lock can update "without
/// tearing down and recreating the panel" has nothing left to work around. But
/// removing it means editing the leaf views below, which C4c deliberately does
/// not do; `OverlayRootView` drives it FROM the presentation instead, so the
/// presentation is the single source and the views are untouched.
///
/// It moved here from `RecordingOverlayPanel` when that class was deleted. Its
/// removal belongs with the leaf-view cleanup this migration explicitly defers.
@MainActor
@Observable
final class OverlayLockState {
  var isLocked: Bool = false
}

/// Observable holder for the transient in-panel notice banner (#1060).
///
/// Its original doc comment stated the reason it exists: so a notice can morph
/// the live recording pill "WITHOUT tearing the panel down", because every other
/// notice path rebuilt the single panel and lost the `.recording` state. That
/// rebuild is what #2292 removed, so the workaround outlived its problem — see
/// `OverlayLockState` for why it is still here.
@MainActor
@Observable
final class OverlayNoticeState {
  var message: String? = nil
}
