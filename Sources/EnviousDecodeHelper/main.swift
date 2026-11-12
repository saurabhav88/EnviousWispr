import Foundation
import MLX

// #4473 P2: the EnviousDecode helper. The app starts it with two model folders and the path of
// a Unix socket in the launch's private folder (#4493), and writes the bearer token as the
// first line of its standard input. It loads the polish model and its draft model once, then
// answers the app's chat requests on that socket until it is told to stop. With a word-check
// adapter folder (#4473 P3) it also loads that adapter and answers learned-word questions.
//
// It stops when SIGTERM arrives or when its standard input ends: the app holds the only writer
// of that pipe, so end-of-file means the app released the helper, quit or died (#4493).

/// The longest the helper keeps running after a stop request. It stops taking connections at
/// once and cancels the request in progress, which ends at its next generation round; if that
/// has not happened within this time, the process exits anyway. The exit skips MLX's own
/// teardown, which is not needed for a process that is going away and must not be able to hold
/// it open.
let shutdownBoundSeconds = 2.0

let arguments: HelperArguments
do {
  arguments = try HelperArguments.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
  helperLog("\(error)")
  helperLog(HelperArguments.usage)
  exit(64)
}
guard let token = HelperStandardInput.readSecret() else {
  helperLog("the bearer token must be the first line of standard input")
  helperLog(HelperArguments.usage)
  exit(64)
}

// From here on, the end of standard input and SIGTERM are the same request.
let stopRequest = HelperStopRequest()
let termination = stopRequest.stopOnSIGTERM()
HelperStandardInput.watchForEnd { [stopRequest] in stopRequest.request() }

// Set before any model is loaded: MLX keeps freed buffers up to this size.
MLX.Memory.cacheLimit = arguments.cacheLimitBytes

do {
  let service = try await HelperService(arguments: arguments, token: token)
  let server = try HelperHTTPServer(socketPath: arguments.socketPath) { request in
    await service.respond(to: request)
  }
  stopRequest.attach(server)

  // The socket opens only now, after both models (and the word-check adapter, when one is
  // given) are loaded: a socket that answers is a helper that can serve.
  try await server.start()
  helperLog(
    "ready socket model=\(arguments.modelName) ctx=\(arguments.contextTokens) wordcheck=\(arguments.wordCheckAdapterFolder == nil ? "off" : "on")"
  )
  while true { try await Task.sleep(for: .seconds(3600)) }
} catch {
  helperLog("failed to start: \(error)")
  exit(1)
}
