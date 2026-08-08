import ApplicationServices
import Foundation
import Testing

@testable import EnviousWisprServices

/// `PasteService.focusedElement(inAppWithPID:)` (#1980) — the app-scoped
/// focused-element query used by the delivery-time retry.
///
/// Only the deterministic, environment-independent case is asserted here.
/// CI's Debug lane has no guaranteed focused-element state, so a real-AX
/// success case is not reliable on a headless runner; the live app-scoped
/// round-trip is proven via Live UAT instead (plan §10/§11.1).
@Suite("PasteService focused element (retry query)")
struct PasteServiceFocusedElementTests {

  @Test("An invalid pid is refused before any AX query")
  func invalidPidReturnsNil() {
    #expect(PasteService.focusedElement(inAppWithPID: 0) == nil)
  }

}
