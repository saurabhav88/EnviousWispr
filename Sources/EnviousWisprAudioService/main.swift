import EnviousWisprObservabilityCore
import Foundation

// Crash reporting for this helper process (limb — never blocks XPC readiness):
// start Sentry BEFORE serving requests so a native crash in audio capture is
// captured, sanitized, and role-tagged. A missing DSN simply skips reporting.
HelperObservability.start(role: .audioXPC)

let delegate = AudioServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
