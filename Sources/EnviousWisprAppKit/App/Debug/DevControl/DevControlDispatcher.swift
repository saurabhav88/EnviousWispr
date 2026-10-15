#if DEBUG
  import EnviousWisprServices
  import Foundation

  /// #3765: turns one dev-control request into one call on the owner the UI uses.
  ///
  /// The door hands it an admitted command and its arguments; it returns a result payload
  /// or an error code. Only allowlisted command names exist, so the door can log the
  /// command without logging anything the client wrote. Error codes are a closed set
  /// (`ErrorCode`), so a log line never carries owner text.
  @MainActor
  final class DevControlDispatcher {
    enum Command: String, CaseIterable {
      case ping
      case settingsList = "settings.list"
      case settingsGet = "settings.get"
      case settingsSet = "settings.set"
    }

    enum ErrorCode: String, CaseIterable {
      case unknownCommand
      case unknownKey
      case badArgs
      case badValue
      case checkFailed
      case checkNotYetShared
      case catalogUnavailable
    }

    enum Result {
      /// `forced` is true only for a settings write that skipped the screens' checks; the
      /// door puts it in the request's log line.
      case ok([String: Any], forced: Bool = false)
      case error(code: String, message: String)

      static func failure(_ code: ErrorCode, _ message: String) -> Result {
        .error(code: code.rawValue, message: message)
      }
    }

    private let settings: SettingsManager
    private let writeContext: DevControlSettings.WriteContext

    init(settings: SettingsManager, writeContext: DevControlSettings.WriteContext) {
      self.settings = settings
      self.writeContext = writeContext
    }

    func handle(_ command: Command?, args: [String: Any]) async -> Result {
      guard let command else {
        return .failure(.unknownCommand, "no such command")
      }
      switch command {
      case .ping:
        return .ok(["pong": true])
      case .settingsList:
        return .ok(["settings": DevControlSettings.catalog(settings)])
      case .settingsGet:
        switch key(in: args) {
        case .failure(let result): return result
        case .success(let key): return .ok(row(key))
        }
      case .settingsSet:
        return set(args)
      }
    }

    // MARK: - Settings

    private enum KeyLookup {
      case success(SettingsManager.SettingKey)
      case failure(Result)
    }

    private func key(in args: [String: Any]) -> KeyLookup {
      guard let name = args["key"] as? String else {
        return .failure(.failure(.badArgs, "key must be a string"))
      }
      guard let key = DevControlSettings.key(named: name) else {
        return .failure(.failure(.unknownKey, "no such setting"))
      }
      return .success(key)
    }

    private func row(_ key: SettingsManager.SettingKey) -> [String: Any] {
      let entry = DevControlSettings.entry(key)
      return [
        "key": entry.name,
        "value": DevControlSettings.read(key, from: settings),
        "kind": entry.kind.rawValue,
        "deferredTo": entry.deferredTo.map { $0 as Any } ?? NSNull(),
        "legacy": entry.legacy,
      ]
    }

    /// `{key, value, force?}`. `force` must be a JSON boolean when present.
    private func set(_ args: [String: Any]) -> Result {
      let key: SettingsManager.SettingKey
      switch self.key(in: args) {
      case .failure(let result): return result
      case .success(let found): key = found
      }
      guard let value = args["value"] else {
        return .failure(.badArgs, "value is required")
      }
      var force = false
      if let raw = args["force"] {
        guard let flag = DevControlSettings.Codec.bool(raw) else {
          return .failure(.badArgs, "force must be a boolean")
        }
        force = flag
      }
      switch DevControlSettings.write(
        key, value: value, force: force, context: writeContext, to: settings)
      {
      case .written(let forced):
        var payload = row(key)
        payload["forced"] = forced
        return .ok(payload, forced: forced)
      case .refused(let code, let message):
        return .error(
          code: ErrorCode(rawValue: code)?.rawValue ?? ErrorCode.badValue.rawValue, message: message
        )
      }
    }
  }
#endif
