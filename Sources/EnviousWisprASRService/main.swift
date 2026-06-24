import EnviousWisprObservabilityCore
import Foundation

// Crash reporting for this helper process (limb — never blocks XPC readiness):
// start Sentry BEFORE serving requests so a native crash in model load /
// inference is captured, sanitized, and role-tagged. Missing DSN skips reporting.
HelperObservability.start(role: .asrXPC)

let delegate = ASRServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
