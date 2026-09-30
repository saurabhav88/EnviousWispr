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
/// `TestDefaultsTests` fails if a test file calls the raw initializer instead.
/// The ASR test target has its own copy (`Tests/EnviousWisprASRTests/TestDefaults.swift`); keep
/// the two identical.
///
/// Known limit: ownership is proven at registration (no plist existed yet). A test that named its
/// suite after a real app's bundle id, while that app first wrote its own plist during the test
/// process, would lose that file at exit. No call site does; names are test-prefixed UUIDs.
enum TestDefaults {
  /// The process-wide registry; installing the exit hook is what first touching it does.
  fileprivate static let shared: SuiteRegistry = {
    let registry = SuiteRegistry()
    // No captures: `atexit` takes a C function pointer.
    atexit { TestDefaults.shared.removeAll() }
    return registry
  }()

  /// Same contract as `UserDefaults(suiteName:)`, but the suite's plist is removed at process exit.
  /// Returns nil for a name that is not safe to delete a file for (see `isSafeSuiteName`), so a bad
  /// name fails the test loudly instead of removing somebody's preferences at exit.
  static func suite(
    _ name: String, preferencesDirectory: URL = userPreferencesDirectory
  ) -> UserDefaults? {
    guard isSafeSuiteName(name) else { return nil }
    // Ownership: only a plist that did not exist before this suite can be ours to delete. A domain
    // that already has a file (an app's real preferences, anything a past run left) is never
    // registered, so the exit hook cannot remove what the tests did not create.
    let plist = plistURL(suite: name, in: preferencesDirectory)
    if !FileManager.default.fileExists(atPath: plist.path) {
      shared.register(name, in: preferencesDirectory)
    }
    return UserDefaults(suiteName: name)
  }

  /// A name the exit hook may delete `<name>.plist` for: plain characters only (no path separator
  /// or `..`), and never an Apple domain, the global domain or one of the app's own bundle IDs.
  static func isSafeSuiteName(_ name: String) -> Bool {
    guard !name.isEmpty, name.range(of: #"^[A-Za-z0-9_-][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil,
      !name.contains("..")
    else { return false }
    let lowered = name.lowercased()
    let reservedPrefixes = ["com.apple.", "nsglobaldomain"]
    let reservedNames: Set<String> = ["com.enviouswispr.app", "com.enviouswispr.app.dev"]
    return !reservedPrefixes.contains { lowered.hasPrefix($0) } && !reservedNames.contains(lowered)
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
    for name in names where isSafeSuiteName(name) {
      let url = plistURL(suite: name, in: preferencesDirectory)
      if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
    }
    return removed
  }

  /// The suite names registered so far in this process (what the exit hook will clean up).
  static var registeredSuiteNames: Set<String> { Set(shared.snapshot().map(\.name)) }

  static var userPreferencesDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Preferences", isDirectory: true)
  }
}

/// Suite names and the directory each one's plist lives in. The directory is stored with the name
/// so cleanup always deletes from the directory ownership was proven in, never from another one.
/// Tests make their own instance; only `TestDefaults.shared` has the exit hook.
final class SuiteRegistry: @unchecked Sendable {
  struct Entry: Hashable {
    let name: String
    let directory: URL
  }

  private let lock = NSLock()
  private var entries: Set<Entry> = []

  func register(_ name: String, in preferencesDirectory: URL) {
    lock.lock()
    entries.insert(Entry(name: name, directory: preferencesDirectory))
    lock.unlock()
  }

  func snapshot() -> Set<Entry> {
    lock.lock()
    defer { lock.unlock() }
    return entries
  }

  /// Removes every registered plist from its own directory. Returns how many files it removed.
  @discardableResult
  func removeAll() -> Int {
    var removed = 0
    for entry in snapshot() {
      removed += TestDefaults.removePlists(of: [entry.name], in: entry.directory)
    }
    return removed
  }
}
