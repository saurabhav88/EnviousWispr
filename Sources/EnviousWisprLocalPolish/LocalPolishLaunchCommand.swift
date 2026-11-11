import Foundation

/// How one launch of a bundled helper is started (#4493): its arguments, what it adds to the
/// inherited environment, what the app writes to its standard input right after it starts, and
/// whether it reads the secret from the launch's key file. Rendered by the engine from the spec
/// and the launch connection's inputs; the process manager knows no engine's command line.
public struct LocalPolishLaunchCommand: Sendable, Equatable {
  public var arguments: [String]
  public var environment: [String: String]
  public var stdinPreamble: Data?
  public var writesKeyFile: Bool

  public init(
    arguments: [String], environment: [String: String] = [:], stdinPreamble: Data? = nil,
    writesKeyFile: Bool = false
  ) {
    self.arguments = arguments
    self.environment = environment
    self.stdinPreamble = stdinPreamble
    self.writesKeyFile = writesKeyFile
  }
}

/// Where the launch folders of a process manager live (#4493). The app always uses
/// `.userCache`: the user's cache folder and this app process's own identity in each folder
/// name.
///
/// Tests use the internal initializer, for a measured reason: a socket path may have at most
/// 103 bytes, and a test folder (`TestTemporaryDirectory.url`, 72 bytes on the measuring Mac)
/// plus a real 32-byte folder name and `/s.sock` is longer than that. A test therefore names a
/// short parent of its own inside that folder and a short made-up identity, and checks the
/// byte length of every socket path it gets.
public struct LocalPolishLaunchHome: Sendable {
  enum Storage: Sendable {
    case userCache
    case custom(
      parent: String, identity: LocalPolishLaunchConnection.ProcessIdentity,
      observer: LocalPolishLaunchConnection.ResourceObserver?)
  }

  let storage: Storage

  public static let userCache = LocalPolishLaunchHome(storage: .userCache)

  init(storage: Storage) { self.storage = storage }

  /// A test home. `observer` receives the launch connection's resource events (for example,
  /// that the folder watch's descriptor exists and registration is pending).
  init(
    parent: String, identity: LocalPolishLaunchConnection.ProcessIdentity,
    observer: LocalPolishLaunchConnection.ResourceObserver? = nil
  ) {
    storage = .custom(parent: parent, identity: identity, observer: observer)
  }

  func makeConnection(secret: String) throws -> LocalPolishLaunchConnection {
    switch storage {
    case .userCache:
      return try LocalPolishLaunchConnection.create(secret: secret)
    case .custom(let parent, let identity, let observer):
      return try LocalPolishLaunchConnection.create(
        secret: secret, parent: parent, identity: identity,
        suffix: LocalPolishLaunchConnection.randomSuffix(), observer: observer)
    }
  }

  func removeLeftovers() {
    switch storage {
    case .userCache:
      LocalPolishLaunchConnection.removeLeftovers()
    case .custom(let parent, let identity, _):
      // The made-up identity counts as alive: another manager of the same test may use this
      // parent, and its folders must stay.
      LocalPolishLaunchConnection.removeLeftovers(parent: parent) { pid in
        pid == identity.pid ? .running(identity) : LocalPolishLaunchConnection.lookUp(pid)
      }
    }
  }
}
