import Foundation

/// Which landing results are a MISS the app may act on (#3106): the one tuning table.
///
/// The arrival session reports what it observed; this decides which observations are trustworthy
/// misses for a destination class. It starts narrow: a readable field that stayed without the text,
/// or no focus at all in an app whose focus can be read without opting it in. Everything else,
/// including every `cannotRead` and `inconclusive`, is not a miss: the app then does what it does
/// today. Changing eligibility is an edit to `isMiss`, nowhere else.
package enum PasteLandingPolicy {

  package static func isMiss(
    _ landing: PasteArrivalLanding, appClass: TelemetryService.LearnFromEditsTelemetry.AppClass
  ) -> Bool {
    switch landing {
    case .absent:
      switch appClass {
      // A manual-accessibility host is eligible only because `.absent` itself required its field
      // to be readable BEFORE dispatch and unchanged throughout (the session's negative rules).
      case .native, .browser, .manualAccessibility: return true
      case .other: return false
      }
    case .noTarget:
      switch appClass {
      case .native, .browser: return true
      // An Electron host that was never opted in can report no focus while a field has it.
      case .manualAccessibility, .other: return false
      }
    case .found, .cannotRead, .inconclusive:
      return false
    }
  }
}
