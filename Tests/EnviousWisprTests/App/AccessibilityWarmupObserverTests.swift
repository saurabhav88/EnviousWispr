import Foundation
import Testing

@testable import EnviousWisprAppKit

@Suite("AccessibilityWarmupObserver.registerPrimeIfAllowed")
struct AccessibilityWarmupObserverTests {
  @Test("Own pid is excluded")
  func excludesOwnPID() {
    var primedAtByPID: [pid_t: TimeInterval] = [:]
    #expect(
      AccessibilityWarmupObserver.registerPrimeIfAllowed(
        activatedPID: 999, ownPID: 999, isRegularActivationPolicy: true,
        primedAtByPID: &primedAtByPID, now: 0, cooldown: 10) == false)
  }

  @Test("Non-regular activation policy is excluded")
  func excludesNonRegularActivationPolicy() {
    var primedAtByPID: [pid_t: TimeInterval] = [:]
    #expect(
      AccessibilityWarmupObserver.registerPrimeIfAllowed(
        activatedPID: 100, ownPID: 999, isRegularActivationPolicy: false,
        primedAtByPID: &primedAtByPID, now: 0, cooldown: 10) == false)
  }

  @Test("First activation of a new pid is allowed")
  func allowsFirstActivation() {
    var primedAtByPID: [pid_t: TimeInterval] = [:]
    #expect(
      AccessibilityWarmupObserver.registerPrimeIfAllowed(
        activatedPID: 100, ownPID: 999, isRegularActivationPolicy: true,
        primedAtByPID: &primedAtByPID, now: 0, cooldown: 10))
    #expect(primedAtByPID[100] == 0)
  }

  @Test("Re-activation of same pid within cooldown is blocked")
  func blocksReactivationWithinCooldown() {
    var primedAtByPID: [pid_t: TimeInterval] = [100: 0]
    #expect(
      AccessibilityWarmupObserver.registerPrimeIfAllowed(
        activatedPID: 100, ownPID: 999, isRegularActivationPolicy: true,
        primedAtByPID: &primedAtByPID, now: 5, cooldown: 10) == false)
  }

  @Test("Re-activation of same pid after cooldown is allowed")
  func allowsReactivationAfterCooldown() {
    var primedAtByPID: [pid_t: TimeInterval] = [100: 0]
    #expect(
      AccessibilityWarmupObserver.registerPrimeIfAllowed(
        activatedPID: 100, ownPID: 999, isRegularActivationPolicy: true,
        primedAtByPID: &primedAtByPID, now: 10, cooldown: 10))
    #expect(primedAtByPID[100] == 10)
  }

  @Test("A to B to A does not bypass A's cooldown")
  func interleavedActivationKeepsPerPIDCooldown() {
    var primedAtByPID: [pid_t: TimeInterval] = [:]

    #expect(
      AccessibilityWarmupObserver.registerPrimeIfAllowed(
        activatedPID: 100, ownPID: 999, isRegularActivationPolicy: true,
        primedAtByPID: &primedAtByPID, now: 5, cooldown: 10))

    #expect(
      AccessibilityWarmupObserver.registerPrimeIfAllowed(
        activatedPID: 200, ownPID: 999, isRegularActivationPolicy: true,
        primedAtByPID: &primedAtByPID, now: 7, cooldown: 10))

    #expect(
      AccessibilityWarmupObserver.registerPrimeIfAllowed(
        activatedPID: 100, ownPID: 999, isRegularActivationPolicy: true,
        primedAtByPID: &primedAtByPID, now: 9, cooldown: 10) == false)
  }
}
