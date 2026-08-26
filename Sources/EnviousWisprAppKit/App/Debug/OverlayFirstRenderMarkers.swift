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
    /// The AX identifier the harness polls for (#2377, C1 repair, cloud review
    /// P1). CGWindow-list membership can precede SwiftUI content actually being
    /// composited, so the harness's stopwatch endpoint moved to "does an
    /// `AXWindow` bearing this identifier exist under the app" — set on the ONE
    /// retained panel once, in `OverlayWindowHost.ensurePanel()`, DEBUG-only.
    /// A string constant here rather than duplicated in Swift and Python is
    /// what keeps the two from drifting apart the way the schema strings do.
    public static let axPanelIdentifier = "EW_OVERLAY_FIRST_RENDER_PANEL"

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

    /// Which presentation a `host.order_front.complete` marker belongs to.
    ///
    /// **Added because the shared retained panel makes every presentation look
    /// identical to the marker.** The Host does not know why it was asked to
    /// present; the Director does (`OverlayDirector.isRecording`). Without this,
    /// an unrelated presentation — the crash-recovery card
    /// `WisprBootstrapper.applicationDidFinishLaunching` can show on ANY
    /// launch — that wins the presentation race binds the marker instead of the
    /// keypress-triggered one, and the harness reports a plausible latency for
    /// work the keypress did not cause.
    public enum Intent: String, Sendable {
      /// Launch/root markers concern no presentation.
      case none
      /// The presentation the benchmark measures.
      case recording
      /// Any other presentation sharing the retained panel.
      case other
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
      /// `.none` for launch/root events. For `host.order_front.complete`, the
      /// ambient value `withPresentationIntent` set for the call that produced
      /// this presentation.
      let intent: Intent
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
    ///
    /// It also reserves the held-capture storage, for the same reason one level
    /// down: `pending` starts empty, so the FIRST `hold` allocates its buffer.
    /// In the baseline bundle that first `hold` happens after key-down and
    /// before the panel is ordered front — inside the keypress interval — while
    /// in the prewarmed bundle it happens before key-down. A malloc is small and
    /// the asymmetry is not: it is a fixed cost charged to one side of a
    /// comparison whose whole purpose is to detect a small difference.
    ///
    /// Three captures is the whole of it — two root, one order-front — and the
    /// flush keeps the capacity rather than freeing it inside the same interval.
    @MainActor
    public static func prepare() {
      _ = sink
      pending.reserveCapacity(4)
    }

    /// Read the clock. This is the ONLY thing that happens at a measured boundary.
    ///
    /// `mach_absolute_time` rather than `Date`: these are sub-10 ms quantities
    /// against an 8 ms bound, and wall time can step. Raw ticks are emitted
    /// unconverted — `mach_timebase_info` is applied by the harness, so no
    /// arithmetic runs inside the interval.
    ///
    /// Only `hostOrderFrontComplete` ever carries a non-`.none` intent — every
    /// other event concerns no presentation, so its intent is fixed at `.none`
    /// regardless of the ambient value, which is what keeps a launch/root
    /// marker from accidentally inheriting whatever `withPresentationIntent`
    /// last set.
    @MainActor
    public static func capture(_ event: Event, window: Int = 0) -> Capture {
      let intent: Intent = event == .hostOrderFrontComplete ? currentIntent : .none
      return Capture(event: event, ticks: mach_absolute_time(), window: window, intent: intent)
    }

    /// The intent the NEXT `hostOrderFrontComplete` capture will carry.
    ///
    /// **Ambient rather than a parameter, because the Host must not learn why
    /// it was asked to present.** `OverlayWindowHosting` is deliberately
    /// minimal (`OverlayWindowHost.swift`'s own doc comment says so), and
    /// presentation intent is measurement-only — widening the production seam
    /// to carry it would put a DEBUG-only concept in a protocol production code
    /// depends on. The Director sets this immediately around its one
    /// `host.present` call, using the SAME `isRecording` classification that
    /// already decides `isFresh`.
    @MainActor
    public static func withPresentationIntent<T>(_ intent: Intent, _ body: () -> T) -> T {
      let previous = currentIntent
      currentIntent = intent
      defer { currentIntent = previous }
      return body()
    }

    @MainActor private static var currentIntent: Intent = .other

    /// Write captures, in one `write(2)`, after the measured work has finished.
    public static func emit(_ captures: Capture...) {
      emit(captures)
    }

    public static func emit(_ captures: [Capture]) {
      guard let sink, !captures.isEmpty else { return }
      var payload = ""
      payload.reserveCapacity((sink.prefix.count + 80) * captures.count)
      for capture in captures {
        payload += sink.prefix
        payload += "event=\(capture.event.rawValue)\tticks=\(capture.ticks)"
        payload += "\twindow=\(capture.window)\tintent=\(capture.intent.rawValue)\n"
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

    /// Emit at most once PER INTENT, for a call site that runs many times but
    /// whose measurement is about the first occurrence of each presentation
    /// kind.
    ///
    /// `host.order_front.complete` is the case: the host orders a panel front on
    /// every presentation. Latching per EVENT alone (the pre-intent design)
    /// meant whichever presentation reached this call first — the keypress
    /// recording, or an unrelated one racing it — silently won the marker,
    /// with nothing in the file to say which. Latching per INTENT keeps that
    /// singleton property for each kind separately: at most one `.recording`
    /// marker ever, and at most one `.other` marker ever, so the harness can
    /// tell "a recording happened" from "something else happened" instead of
    /// reading one merged, unlabelled event.
    ///
    /// **Only `.recording` flushes the held root markers.** Root construction
    /// timing is meaningful paired with the RECORDING's own first render; an
    /// unrelated `.other` presentation winning the race first must not consume
    /// that flush, or the recording's later marker would find `pending` already
    /// emptied and its root timing lost. An `.other` marker before any
    /// `.recording` is written on its own, and the harness blocks on it
    /// (`BLOCKED_WRONG_PRESENTATION`) — see the Python adjudicator.
    ///
    /// `@MainActor` because all three call sites already are, which is cheaper
    /// and more honest than a lock defending state nothing else touches.
    @MainActor
    public static func emitFirst(_ capture: Capture) {
      guard emittedIntents.insert(capture.intent).inserted else { return }
      if capture.intent == .recording {
        // Everything held so far flushes with this one, in capture order, so
        // the file order matches the causal order the harness enforces.
        let batch = pending + [capture]
        pending.removeAll(keepingCapacity: true)
        emit(batch)
      } else {
        emit(capture)
      }
    }

    @MainActor private static var emittedIntents: Set<Intent> = []

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
      // V2: adds the `intent` field (#2377, C1 repair) — a schema bump because
      // an old harness reading a V2 line would silently misparse the eighth
      // field as belonging to no key it expects.
      let prefix =
        "EW_OVERLAY_FIRST_RENDER_V2\trun=\(runID)\tpid=\(getpid())\tbundle=\(bundleID)\t"
      return Sink(descriptor: descriptor, prefix: prefix)
    }()
  }
#endif
