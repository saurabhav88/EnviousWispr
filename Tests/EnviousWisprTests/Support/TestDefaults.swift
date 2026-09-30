import Foundation

/// The one way a test makes a named `UserDefaults` suite (#2998).
///
/// A named suite persists `~/Library/Preferences/<suite>.plist` the moment anything is written, and
/// `removePersistentDomain(forName:)` does NOT delete that file: it leaves an empty 42-byte plist
/// behind (measured 2026-09-30 on macOS 27). With a fresh UUID per test, that is one file per test
/// per run, forever: 900,602 of them on the founder's Mac. Nothing inside a test body can remove
/// the file (the suite must stay readable for the whole test), so the suites are registered here and
/// their files are unlinked once, when the test process exits. Unlinking at exit was measured to
/// stick: cfprefsd does not recreate the file afterwards.
///
/// `TestDefaultsDriftGuardTests` fails if a test file calls the raw initializer instead.
/// The ASR test target has its own copy (`Tests/EnviousWisprASRTests/TestDefaults.swift`); keep
/// the two identical.
enum TestDefaults {
  /// Same contract as `UserDefaults(suiteName:)`, but the suite's plist is removed at process exit.
  static func suite(_ name: String) -> UserDefaults? {
    Registry.shared.register(name)
    return UserDefaults(suiteName: name)
  }

  /// The plist a suite persists, inside `preferencesDirectory`.
  static func plistURL(suite name: String, in preferencesDirectory: URL) -> URL {
    preferencesDirectory.appendingPathComponent(name + ".plist")
  }

  /// Removes the plists of `names` from `preferencesDirectory`. Returns how many files it removed.
  @discardableResult
  static func removePlists(
    of names: some Sequence<String>, in preferencesDirectory: URL
  ) -> Int {
    var removed = 0
    for name in names {
      let url = plistURL(suite: name, in: preferencesDirectory)
      if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
    }
    return removed
  }

  /// The suite names registered so far in this process (what the exit hook will clean up).
  static var registeredSuiteNames: Set<String> { Registry.shared.snapshot() }

  static var userPreferencesDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Preferences", isDirectory: true)
  }

  fileprivate final class Registry: @unchecked Sendable {
    static let shared = Registry()
    private let lock = NSLock()
    private var names: Set<String> = []

    private init() {
      // No captures: `atexit` takes a C function pointer.
      atexit { Registry.shared.removeAll() }
    }

    func register(_ name: String) {
      lock.lock()
      names.insert(name)
      lock.unlock()
    }

    func snapshot() -> Set<String> {
      lock.lock()
      defer { lock.unlock() }
      return names
    }

    func removeAll() {
      lock.lock()
      let all = names
      lock.unlock()
      TestDefaults.removePlists(of: all, in: TestDefaults.userPreferencesDirectory)
    }
  }
}
