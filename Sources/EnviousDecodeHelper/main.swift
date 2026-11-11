import Foundation
import MLX

// #4473 P2: the EnviousDecode helper. The app starts it with two model folders, a loopback
// port and a bearer token. It loads the polish model and its draft model once, then answers
// the app's chat requests on 127.0.0.1 until it is told to stop. With a word-check adapter
// folder (#4473 P3) it also loads that adapter and answers learned-word questions. No code in
// the app starts it yet.

/// The longest the helper keeps running after SIGTERM. It stops taking connections at once and
/// cancels the request in progress, which ends at its next generation round; if that has not
/// happened within this time, the process exits anyway. The exit skips MLX's own teardown,
/// which is not needed for a process that is going away and must not be able to hold it open.
let shutdownBoundSeconds = 2.0

let arguments: HelperArguments
do {
  arguments = try HelperArguments.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
  helperLog("\(error)")
  helperLog(HelperArguments.usage)
  exit(64)
}

// Set before any model is loaded: MLX keeps freed buffers up to this size.
MLX.Memory.cacheLimit = arguments.cacheLimitBytes

do {
  let service = try await HelperService(arguments: arguments)
  let server = try HelperHTTPServer(port: arguments.port) { request in
    await service.respond(to: request)
  }

  signal(SIGTERM, SIG_IGN)
  let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
  termination.setEventHandler {
    helperLog("stopping")
    DispatchQueue.global().asyncAfter(deadline: .now() + shutdownBoundSeconds) { _exit(0) }
    server.stop { _exit(0) }
  }
  termination.resume()

  // The port opens only now, after both models (and the word-check adapter, when one is
  // given) are loaded: a port that answers is a helper that can serve.
  try await server.start()
  helperLog(
    "ready port=\(arguments.port) model=\(arguments.modelName) ctx=\(arguments.contextTokens) wordcheck=\(arguments.wordCheckAdapterFolder == nil ? "off" : "on")"
  )
  while true { try await Task.sleep(for: .seconds(3600)) }
} catch {
  helperLog("failed to start: \(error)")
  exit(1)
}
