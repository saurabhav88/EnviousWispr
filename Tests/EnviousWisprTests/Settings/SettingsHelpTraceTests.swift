@testable import EnviousWisprAppKit
import EnviousWisprServices
import Foundation
import Testing

@MainActor
@Suite("Settings help observations", .tags(.observabilityContract))
struct SettingsHelpTraceTests {
  @MainActor final class Rig {
    var time = 10.0
    var available = true
    var rows: [SettingsHelpObservation] = []
    lazy var trace = SettingsHelpTrace(
      now: { self.time }, captureAvailable: { self.available },
      windowState: { (true, false) }, emit: { self.rows.append($0) })
  }

  @Test("one request keeps its clock across repeat activation and ends once")
  func requestAndClose() throws {
    let r = Rig()
    r.trace.requested(alreadyPresented: false)
    r.time += 2
    r.trace.requested(alreadyPresented: true)
    r.trace.escapeObserved()
    r.trace.bindingFalseObserved()
    r.trace.anchorDisappeared()
    #expect(r.rows.map(\.phase) == [.requested, .bindingFalseObserved])
    #expect(r.rows.map(\.sequence) == [1, 2])
    #expect(r.rows.map(\.elapsedMilliseconds) == [0, 2_000])
    try #require(r.rows.count >= 2)
    #expect(r.rows[0].interactionID == r.rows[1].interactionID)
    #expect(r.rows[1].escapeObserved)
    r.trace.requested(alreadyPresented: false)
    try #require(r.rows.count == 3)
    #expect(r.rows[2].interactionID != r.rows[0].interactionID)
    #expect(r.rows[2].escapeObserved == false)
  }

  @Test("unmount and supersession have distinct terminals and do not duplicate")
  func terminalKinds() throws {
    let r = Rig()
    r.trace.requested(alreadyPresented: false)
    r.trace.requested(alreadyPresented: false)
    r.trace.anchorDisappeared()
    r.trace.bindingFalseObserved()
    #expect(r.rows.map(\.phase) == [
      .requested, .supersededByRequest, .requested, .anchorDisappeared,
    ])
    try #require(r.rows.count == 4)
    #expect(r.rows[0].interactionID == r.rows[1].interactionID)
    #expect(r.rows[2].interactionID == r.rows[3].interactionID)
    #expect(r.rows[0].interactionID != r.rows[2].interactionID)
  }

  @Test("hover is a dwell summary; clicking discards it and closing invents no entry")
  func hoverAndClick() throws {
    let r = Rig()
    r.trace.pointerChanged(true, popoverIsPresented: false)
    r.time += 1
    r.trace.pointerChanged(true, popoverIsPresented: false)
    r.trace.pointerChanged(false, popoverIsPresented: false)
    try #require(r.rows.count == 1)
    #expect(r.rows[0].phase == .hoverEnded)
    #expect(r.rows[0].elapsedMilliseconds == 1_000)
    #expect(r.rows[0].pointerInside == false)
    r.trace.pointerChanged(true, popoverIsPresented: false)
    r.trace.requested(alreadyPresented: false)
    r.trace.pointerChanged(false, popoverIsPresented: true)
    r.trace.pointerChanged(true, popoverIsPresented: true)
    r.trace.bindingFalseObserved()
    r.trace.pointerChanged(false, popoverIsPresented: false)
    #expect(r.rows.map(\.phase) == [.hoverEnded, .requested, .bindingFalseObserved])
  }

  @Test("capture off suppresses current observations and an off-start attempt is never replayed")
  func consent() {
    let r = Rig()
    r.available = false
    r.trace.requested(alreadyPresented: false)
    r.available = true
    r.trace.bindingFalseObserved()
    #expect(r.rows.isEmpty)
    r.trace.requested(alreadyPresented: false)
    r.available = false
    r.trace.bindingFalseObserved()
    #expect(r.rows.map(\.phase) == [.requested])
    r.available = true
    r.trace.bindingFalseObserved()
    #expect(r.rows.count == 1)
  }

}
