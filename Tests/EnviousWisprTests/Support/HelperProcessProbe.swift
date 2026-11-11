import Foundation
import Testing

/// #4493 real-boundary checks on one running helper process, read with the system's own tools.
/// Each read says whether it could be made: a probe that fails is an error, never an empty
/// answer.
enum HelperProcessProbe {
  struct Output {
    let status: Int32
    let text: String
  }

  static func run(_ tool: String, _ arguments: [String]) throws -> Output {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return Output(status: process.terminationStatus, text: String(decoding: data, as: UTF8.self))
  }

  struct ProbeFailed: Error, CustomStringConvertible {
    let description: String
  }

  /// The executable path of `pid`, or nil only when the system says no such process exists.
  /// Any other failure to ask is an error.
  static func executable(_ pid: Int32) throws -> String? {
    if kill(pid, 0) != 0 {
      if errno == ESRCH { return nil }
      throw ProbeFailed(description: "kill(\(pid), 0) failed with errno \(errno)")
    }
    let output = try run("/bin/ps", ["-o", "comm=", "-p", String(pid)])
    let path = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard output.status == 0, !path.isEmpty else {
      throw ProbeFailed(description: "ps could not name process \(pid) (status \(output.status))")
    }
    return path
  }

  /// The TCP sockets `pid` holds. `lsof` exits 1 both when it finds nothing and when it fails;
  /// the same tool must first list the process's Unix socket at `socketPath`, which proves it
  /// could read this process, before an empty TCP answer is believed.
  static func tcpSockets(_ pid: Int32, socketPath: String) throws -> [String] {
    let unix = try run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-U"])
    try #require(
      unix.status == 0 && unix.text.contains(socketPath),
      "lsof could not show the helper's own socket, so its TCP answer means nothing")
    let tcp = try run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-iTCP"])
    let lines = tcp.text.split(separator: "\n").map(String.init)
    try #require(tcp.status == 0 || (tcp.status == 1 && lines.isEmpty), "lsof -iTCP failed")
    return lines.dropFirst().map { $0 }  // the first line is lsof's header
  }

  /// Whether `text` appears in the command line or in the environment of `pid`. The contents
  /// are compared here and never returned.
  static func commandOrEnvironmentContains(_ pid: Int32, _ text: String) throws -> (
    command: Bool, environment: Bool
  ) {
    let command = try run("/bin/ps", ["-ww", "-o", "command=", "-p", String(pid)])
    try #require(command.status == 0 && !command.text.isEmpty, "ps could not read the command")
    let environment = try run("/bin/ps", ["-Eww", "-o", "command=", "-p", String(pid)])
    try #require(environment.status == 0, "ps could not read the environment")
    return (command.text.contains(text), environment.text.contains(text))
  }

  /// "No such file or folder", as Foundation reports it or as its underlying POSIX error.
  static func isMissingFolder(_ error: NSError) -> Bool {
    if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return true }
    guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
    return underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(ENOENT)
  }

  /// The user's crash report folder.
  static let reportFolder = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/DiagnosticReports")

  /// The names of the crash reports for `prefix` processes now in `folder`. The folder is read
  /// directly: only an established "no such folder" means none; any other failure is an error.
  static func crashReports(_ prefix: String, in folder: URL = reportFolder) throws -> Set<String> {
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    } catch let error as NSError where isMissingFolder(error) {
      return []
    }
    return Set(names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".ips") })
  }
}
