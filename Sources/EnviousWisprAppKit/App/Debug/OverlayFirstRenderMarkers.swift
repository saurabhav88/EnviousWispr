#if DEBUG
  import Darwin
  import Foundation

  /// DEBUG-only timing markers for the #2377 Phase 6 first-render benchmark.
  ///
  /// **Measurement only. Nothing here is read at runtime and no behaviour is
  /// conditional on a marker.** The app writes; the harness judges. A production
  /// path that consulted these would make the instrument part of the thing it
  /// measures.
  ///
  /// Three properties are load-bearing and each one is a defect this avoids:
  ///
  /// **1. `AppLogger` is deliberately not used.** Its file sink is gated behind
  /// both `#if DEBUG` and the in-app Debug Mode setting, so a benchmark written
  /// through it would silently depend on a preference — a run with Debug Mode off
  /// produces no markers and looks exactly like a build with no emitter. Its
  /// actor hop and formatting would also land inside the interval being measured.
  ///
  /// **2. `capture` reads the clock and nothing else.** The environment lookup,
  /// the string building and the `write(2)` all happen in `emit`, which callers
  /// place AFTER the measured work. The cost of recording a measurement must not
  /// be inside the measurement.
  ///
  /// **3. The file is opened WITHOUT `O_CREAT`.** The harness pre-creates it, so
  /// an app launched with a stale or wrong path writes nothing rather than
  /// creating a file somewhere the harness will never read — an absence the
  /// harness reports as a block, instead of a plausible file that is missing
  /// markers for a reason nobody can recover.
  ///
  /// Absent either environment variable this is a strict no-op: no file is
  /// opened and nothing is written, on any launch, ever. It is not allocation
  /// free — resolving the sink reads `ProcessInfo.environment`, which builds a
  /// dictionary — but that happens exactly once, in `prepare()`, which the call
  /// site places before any measured interval.
  public enum OverlayFirstRenderMarkers {
    /// The exact strings the harness parses. Changing one is a schema change and
    /// belongs with a bump of `SCHEMA` in `measure_overlay_first_render.py`,
    /// whose parser refuses an unknown event rather than skipping it.
    public enum Event: String, Sendable {
      case launchEnter = "launch.enter"
      case launchExit = "launch.exit"
      case rootConstructStart = "root.construct.start"
      case rootConstructEnd = "root.construct.end"
      case hostOrderFrontComplete = "host.order_front.complete"
    }

    /// One clock reading bound to the event it belongs to.
    ///
    /// Carrying the event with the tick count is what lets a caller take both
    /// endpoints of an interval and write them afterwards, rather than writing
    /// the first one while the interval is still running.
    public struct Capture: Sendable {
      let event: Event
      let ticks: UInt64
      /// The CGWindow number the event concerns, or `0` where it concerns none.
      ///
      /// **Only `host.order_front.complete` carries one, and it is what lets the
      /// harness name its subject instead of guessing at it.** Without it the
      /// harness can only watch for "a new window owned by this process", and an
      /// unrelated window — settings, onboarding, a permission prompt — that
      /// appears before the pill reaches WindowServer is accepted as the pill.
      /// The result is a plausible latency measured against the wrong window,
      /// which is worse than no measurement because nothing about it looks
      /// wrong.
      let window: Int
    }

    /// Force the sink open BEFORE the first measured interval begins.
    ///
    /// **Without this the instrument is sensitive to the change it exists to
    /// measure.** The sink is a lazy `static let`, so whichever `emit` runs first
    /// pays for reading the environment, opening the file and building the
    /// constant prefix. Today root construction is lazy and happens on the first
    /// presentation, comfortably after launch — so the first `emit` is the launch
    /// pair's own, which runs after that interval has closed, and the cost lands
    /// nowhere. Phase 6 exists to MOVE root construction earlier. The moment it
    /// runs during `applicationDidFinishLaunching`, its `emit` becomes the first
    /// one and the setup cost lands inside the launch measurement — inflating
    /// exactly the number the move is being judged on, in the direction that
    /// makes the change look worse than it is.
    ///
    /// So the call site arms this at the top of launch, before any `capture`.
    /// A no-op when the environment is absent, like everything else here.
    public static func prepare() {
      _ = sink
    }

    /// Read the clock. This is the ONLY thing that happens at a measured boundary.
    ///
    /// `mach_absolute_time` rather than `Date`: these are sub-10 ms quantities
    /// against an 8 ms bound, and wall time can step. Raw ticks are emitted
    /// unconverted — `mach_timebase_info` is applied by the harness, so no
    /// arithmetic runs inside the interval.
    public static func capture(_ event: Event, window: Int = 0) -> Capture {
      Capture(event: event, ticks: mach_absolute_time(), window: window)
    }

    /// Write captures, in one `write(2)`, after the measured work has finished.
    public static func emit(_ captures: Capture...) {
      emit(captures)
    }

    public static func emit(_ captures: [Capture]) {
      guard let sink, !captures.isEmpty else { return }
      var payload = ""
      payload.reserveCapacity((sink.prefix.count + 64) * captures.count)
      for capture in captures {
        payload += sink.prefix
        payload += "event=\(capture.event.rawValue)\tticks=\(capture.ticks)"
        payload += "\twindow=\(capture.window)\n"
      }
      sink.write(payload)
    }

    /// Hold captures until the first order-front, instead of writing them now.
    ///
    /// **A marker's own write must not sit inside a measured interval in one
    /// bundle and outside it in the other.** Root construction is the interval
    /// Phase 6 MOVES. In the baseline bundle it runs after key-down and before
    /// the panel is ordered front, so emitting there puts this string building
    /// and `write(2)` inside the keypress interval; in the prewarmed bundle the
    /// same construction happens before key-down, so the identical cost falls
    /// outside it. The benchmark would then credit the change for removing
    /// marker I/O that is not production work — the instrument paying the
    /// variant it is supposed to be judging.
    ///
    /// Holding them means BOTH bundles write the same three lines at the same
    /// point, immediately after `orderFrontRegardless()`. The cost is identical
    /// on both sides, so it cancels in every bound this phase is judged on —
    /// all three are stated as regressions against the other bundle, and the
    /// one absolute bound (root construction p95) measures an interval this
    /// write is not inside.
    ///
    /// Consequence worth stating: a launch that never orders a panel front
    /// writes no root markers at all, and the harness blocks it as incomplete.
    /// That is the honest reading — no first render happened.
    @MainActor
    public static func hold(_ captures: Capture...) {
      pending.append(contentsOf: captures)
    }

    @MainActor private static var pending: [Capture] = []

    /// Emit at most once per process, for an event whose CALL SITE runs many
    /// times but whose measurement is about the first occurrence.
    ///
    /// `host.order_front.complete` is the case: the host orders a panel front on
    /// every presentation, and a launch that showed two pills would write the
    /// event twice. The harness treats every event as a singleton and blocks on a
    /// duplicate, correctly — two order-fronts in one file give a "first render"
    /// figure that is a mix of a first render and a later one. The latch is here
    /// rather than at the call site so the property the harness depends on lives
    /// with the contract, not with one of its callers.
    ///
    /// `@MainActor` because all three call sites already are, which is cheaper
    /// and more honest than a lock defending state nothing else touches.
    @MainActor
    public static func emitFirst(_ capture: Capture) {
      guard emittedOnce.insert(capture.event).inserted else { return }
      // Everything held so far flushes with this one, in capture order, so the
      // file order matches the causal order the harness enforces.
      let batch = pending + [capture]
      pending.removeAll()
      emit(batch)
    }

    @MainActor private static var emittedOnce: Set<Event> = []

    // MARK: - the sink

    private struct Sink {
      let descriptor: Int32
      /// Everything constant for this process, built once: schema, run id, pid
      /// and bundle id, tab-terminated so a line is a concatenation.
      let prefix: String

      func write(_ text: String) {
        var bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buffer in
          guard var pointer = buffer.baseAddress else { return }
          var remaining = buffer.count
          // A regular file's `write` normally completes in full, but a short
          // write is legal and a silently truncated marker line reads to the
          // harness as a malformed one — an instrument fault wearing an app
          // fault's clothes. Looping costs nothing here: this runs after the
          // interval it describes.
          while remaining > 0 {
            let written = Darwin.write(descriptor, pointer, remaining)
            if written <= 0 {
              if errno == EINTR { continue }
              return
            }
            pointer += Int(written)
            remaining -= Int(written)
          }
        }
      }
    }

    /// Resolved once, on the first `emit` — which every caller places after a
    /// measured interval, so the environment read and the `open` never land
    /// inside one.
    private static let sink: Sink? = {
      let environment = ProcessInfo.processInfo.environment
      guard let path = environment["EW_OVERLAY_FIRST_RENDER_MARKER_PATH"],
        let runID = environment["EW_OVERLAY_FIRST_RENDER_RUN_ID"],
        !path.isEmpty, !runID.isEmpty
      else { return nil }

      // No `O_CREAT`: see the type's documentation.
      //
      // `O_APPEND` is load-bearing rather than conventional. `emit` is
      // nonisolated and writes one whole payload per call, and O_APPEND makes
      // each of those land atomically at the end of the file - so two emits
      // racing cannot interleave into one corrupt line. Without it the harness
      // would report `BLOCKED_MALFORMED_MARKER`, which reads as a drifted app
      // format rather than as a write race.
      //
      // `O_CLOEXEC` so a child process cannot inherit the descriptor and write
      // into the same file, which would present as duplicate markers - a
      // different refusal, for a different reason, from the same cause.
      let descriptor = path.withCString { open($0, O_WRONLY | O_APPEND | O_CLOEXEC) }
      guard descriptor >= 0 else { return nil }

      let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
      let prefix =
        "EW_OVERLAY_FIRST_RENDER_V1\trun=\(runID)\tpid=\(getpid())\tbundle=\(bundleID)\t"
      return Sink(descriptor: descriptor, prefix: prefix)
    }()
  }
#endif
