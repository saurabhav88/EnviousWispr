import EnviousWisprAppKitTestSupport
import Foundation
import os

@testable import EnviousWisprLocalPolish

/// #4493: a launch home for a process-manager test that starts a real child: its own short
/// parent inside `TestTemporaryDirectory` (removed with it) and a short made-up identity, so
/// every socket path fits the 103-byte limit (`LocalPolishLaunchHome`) and no test writes to
/// the user's cache folder.
enum TestLaunchHome {
  private static let names = OSAllocatedUnfairLock(initialState: 0)

  /// The made-up identity in every test launch folder's name.
  static let identity = LocalPolishLaunchConnection.ProcessIdentity(
    pid: 7, startSeconds: 1, startMicroseconds: 1)

  /// A new short parent folder name in this test process.
  static func parent() -> String {
    let number = names.withLock { count -> Int in
      count += 1
      return count
    }
    return TestTemporaryDirectory.url.appendingPathComponent("m\(number)").path
  }

  static func make() -> (home: LocalPolishLaunchHome, parent: String) {
    let parent = parent()
    return (LocalPolishLaunchHome(parent: parent, identity: identity), parent)
  }

  /// `engine` with every launch it renders placed in `home`: the same launch, probe and slot
  /// operations, through the configurable test engine (normal bundle only; the cloud-critical
  /// bundle has no `TestTemporaryDirectory`).
  static func engine(_ engine: any LocalPolishEngine, in home: LocalPolishLaunchHome)
    -> TestLocalPolishEngine
  {
    let launch = engine.makeLaunchConfiguration
    var homed = TestLocalPolishEngine(
      makeLaunchConfiguration: { model, identity, binary, modelURL, context, adapter in
        launch(model, identity, binary, modelURL, context, adapter).inLaunchHome(home)
      },
      makeHealthProbe: engine.makeHealthProbe)
    #if DEBUG
      homed.inspectSlots = engine.inspectSlots
    #endif
    return homed
  }
}
