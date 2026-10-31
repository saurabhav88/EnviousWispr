#if DEBUG
  import EnviousWisprCore

  /// #4254 runtime checkpoint (DEBUG only): holds Quit until its witness line is written.
  ///
  /// AppKit terminates as soon as `applicationShouldTerminate` answers yes, so a witness logged
  /// from a fire-and-forget task never reached `app.log`. The gate answers "later", awaits the
  /// write, then forwards to the existing quit owner: when that owner answers yes the gate
  /// replies once; when it answers no it owns the reply, exactly as without the gate. The
  /// measured Quit time therefore includes this one log write.
  @MainActor
  final class QuitWitnessGate {
    typealias Reply = @MainActor (Bool) -> Void

    private let write: @MainActor (String) async -> Void
    /// True while a witness write is in flight; cleared before forwarding, so a denied Quit
    /// never blocks the next one.
    private var writing = false

    /// `write` must return only once the line is written (the app passes `appLog`).
    init(write: @escaping @MainActor (String) async -> Void) {
      self.write = write
    }

    /// The app's writer: `AppLogger`'s actor writes the line to the file before returning.
    nonisolated static func appLog(_ line: String) async {
      await AppLogger.shared.log(line, level: .info, category: "Debug")
    }

    /// Always answers false (terminate later). A Quit while a write is in flight is not
    /// forwarded again, as the quit owner refuses a second pending reply.
    func request(
      line: String, forward: @escaping @MainActor (@escaping Reply) -> Bool, reply: @escaping Reply
    )
      -> Bool
    {
      guard !writing else { return false }
      writing = true
      Task { @MainActor [self] in
        await write(line)
        writing = false
        if forward(reply) { reply(true) }
      }
      return false
    }
  }
#endif
