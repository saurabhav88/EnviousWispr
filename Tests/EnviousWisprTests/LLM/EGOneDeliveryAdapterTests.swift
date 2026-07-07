import Foundation
import Testing

@testable import EnviousWisprLLM
@testable import EnviousWisprModelDelivery

/// The EG-1 limb adapter's pure mapping: every delivery state/failure resolves
/// to an EG-1 UI vocabulary value, and EVERY `DeliveryFailureClass` maps to a
/// retry-able RED (the limb never blocks dictation — #1363 §7).
@Suite struct EGOneDeliveryAdapterMappingTests {
  @Test func deliveryStateMapsToInstallState() {
    #expect(EGOneDeliveryAdapter.map(.notReady, version: "v1") == .notInstalled)
    #expect(
      EGOneDeliveryAdapter.map(.preparing(validatingExistingCache: true), version: "v1")
        == .verifying)
    #expect(
      EGOneDeliveryAdapter.map(
        .downloading(fractionCompleted: 0.5, bytesWritten: 5, totalBytes: 10), version: "v1")
        == .downloading(fractionCompleted: 0.5))
    #expect(EGOneDeliveryAdapter.map(.verifying, version: "v1") == .verifying)
    #expect(EGOneDeliveryAdapter.map(.admitted, version: "v1") == .installed(version: "v1"))
    #expect(
      EGOneDeliveryAdapter.map(.cancelled(resumable: true), version: "v1") == .failed(.cancelled))
  }

  @Test func everyFailureClassMapsToARetryableInstallFailure() {
    let all: [DeliveryFailureClass] = [
      .sourceUnreachable, .sourceTimeout, .source5xx, .source4xx, .integrityMismatch,
      .insufficientDisk, .permissionDenied, .cacheRepairFailed, .cancelled, .unknown,
    ]
    for reason in all {
      let mapped = EGOneDeliveryAdapter.map(
        .failed(DeliveryFailure(reason: reason)), version: "v1")
      guard case .failed = mapped else {
        Issue.record("\(reason) did not map to a .failed install state")
        continue
      }
    }
  }

  @Test func failureClassBucketsMatchExistingCopy() {
    #expect(EGOneDeliveryAdapter.mapFailure(.sourceUnreachable) == .network)
    #expect(EGOneDeliveryAdapter.mapFailure(.sourceTimeout) == .network)
    #expect(EGOneDeliveryAdapter.mapFailure(.source4xx) == .http)
    #expect(EGOneDeliveryAdapter.mapFailure(.source5xx) == .http)
    #expect(EGOneDeliveryAdapter.mapFailure(.integrityMismatch) == .checksum)
    #expect(EGOneDeliveryAdapter.mapFailure(.cacheRepairFailed) == .checksum)
    #expect(EGOneDeliveryAdapter.mapFailure(.insufficientDisk) == .disk)
    #expect(EGOneDeliveryAdapter.mapFailure(.cancelled) == .cancelled)
    #expect(EGOneDeliveryAdapter.mapFailure(.permissionDenied) == .http)
    #expect(EGOneDeliveryAdapter.mapFailure(.unknown) == .http)
  }
}
