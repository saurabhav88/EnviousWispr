import Testing

extension Tag {
  /// #4279: this suite runs in its own test process, AT THE SAME TIME as the protected worker, in the
  /// full local `scripts/xcode-test.sh` run. Keeping the mark in the source means an edit keeps it;
  /// the person editing the suite is the one who keeps it true.
  ///
  /// A tagged suite must not touch anything another process can touch at the same moment: a shared
  /// `UserDefaults` suite (`.standard`, `com.enviouswispr.app`), the Keychain, a fixed path outside its
  /// own UUID temporary directory (`app.log`, Application Support, caches), the pasteboard, a real
  /// audio device, model or GPU, a helper process with a fixed name, port or socket, or a wall-clock
  /// deadline that CPU contention can miss. Check what the code under test touches, not only the test.
  ///
  /// If an edit adds any of these, remove the tag AND the suite's entry in
  /// `scripts/local-test-costs.json`; the suite then runs in the protected worker. To admit a suite,
  /// review it the same way, then add both. `TestInventoryFreezeTests` fails when the tagged suites
  /// and that list differ. Mechanics: `.claude/rules/code-tooling.md` RULE: xcode-test-entrypoint.
  @Tag static var localParallel: Self
}
