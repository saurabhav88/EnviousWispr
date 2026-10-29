@testable import EnviousWisprAppKit
@testable import EnviousWisprServices
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

  @Test("pointer movement updates click context without sending hover records")
  func pointerContextOnly() throws {
    let r = Rig()
    r.trace.pointerChanged(true)
    r.time += 1
    r.trace.pointerChanged(false)
    r.trace.pointerChanged(true)
    #expect(r.rows.isEmpty)
    r.trace.requested(alreadyPresented: false)
    r.trace.pointerChanged(false)
    r.trace.bindingFalseObserved()
    #expect(r.rows.map(\.phase) == [.requested, .bindingFalseObserved])
    try #require(r.rows.count == 2)
    #expect(r.rows[0].pointerInside)
    #expect(r.rows[1].pointerInside == false)
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


  @Test("two button traces share one process admission budget without affecting their UI callbacks")
  func sharedAcrossButtons() {
    var budget = SettingsHelpCaptureBudget()
    var rows: [SettingsHelpObservation] = []
    var available = true
    let makeTrace = {
      SettingsHelpTrace(
        now: { 10 }, captureAvailable: { available }, windowState: { (true, true) },
        emit: { if budget.admit($0, captureAvailable: available) { rows.append($0) } })
    }
    let first = makeTrace(), second = makeTrace()
    for index in 0..<6 {
      let trace = index.isMultiple(of: 2) ? first : second
      trace.requested(alreadyPresented: false)
      trace.bindingFalseObserved()
    }
    #expect(rows.count == 10)
    #expect(Set(rows.map(\.interactionID)).count == 5)
    available = false
    first.requested(alreadyPresented: false)
    first.bindingFalseObserved()
    available = true
    second.requested(alreadyPresented: false)
    second.bindingFalseObserved()
    #expect(rows.count == 10)
  }

}
