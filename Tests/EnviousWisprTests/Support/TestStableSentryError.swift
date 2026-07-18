import EnviousWisprCore

/// Shared conforming fixture for tests that need a generic, real `StableSentryErrorIdentity`
/// value without asserting per-case semantics (#1525 PR I-C). Use a bespoke per-file fixture
/// instead when a test specifically asserts override precedence, per-case identity, or
/// underlying-error preservation — this fixture is for seams that only need "a conforming
/// error", not "this specific error's identity."
struct TestStableSentryError: Error, StableSentryErrorIdentity {
  let sentryFingerprintDescriptor: String
  let sentrySemanticID: String

  init(
    descriptor: String = "TestStableSentryError#0",
    semanticID: String = "test.stable_sentry_error"
  ) {
    self.sentryFingerprintDescriptor = descriptor
    self.sentrySemanticID = semanticID
  }
}
