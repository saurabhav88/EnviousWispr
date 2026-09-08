// #2705 test fixture, NOT part of any compiled target (lives outside every
// Tuist `sources` glob — see Project.swift). Invoked at test runtime with
// `swift Tests/Fixtures/frozen-app/FrozenAppHelper.swift`, never compiled in.
//
// A minimal, real AppKit app: nothing more than what an ordinary macOS app
// needs to register with the Accessibility subsystem and become a genuine
// target for `AXUIElementCreateApplication(pid)`. It does NOT freeze itself —
// the test freezes it from outside with SIGSTOP once it has confirmed the
// process is a real, responsive AX target, which is the actual shape of a
// third-party app that stops answering: the process is alive, just not
// servicing its run loop, whatever the reason.
import Cocoa

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
