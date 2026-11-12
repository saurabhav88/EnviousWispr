import EnviousWisprCore
import Foundation

/// #4473: the measured numbers a size card may show, read from the bundled
/// `eg1-size-facts.json`. One owner for every number on the cards.
///
/// Each value carries the receipt it came from and states any difference from the shipped
/// setup. The numbers are guidance for choosing a size, rounded from our own measurements
/// (founder 2026-11-11), never a design mock's. An absent value is not shown.
struct EGOneSizeFacts: Decodable, Equatable, Sendable {
  struct Measured: Decodable, Equatable, Sendable {
    let value: Int64
    /// Where the value was measured, relative to the run folder named in the resource.
    let receipt: String
    let measures: String
  }

  struct Size: Decodable, Equatable, Sendable {
    let englishPercent: Measured?
    let internationalPercent: Measured?
    let polishMilliseconds: Measured?
    let memoryBytes: Measured?

    static let unmeasured = Size(
      englishPercent: nil, internationalPercent: nil, polishMilliseconds: nil, memoryBytes: nil)
  }

  let schemaVersion: Int
  /// The Mac the speed and memory values were measured on, for the footnote.
  let measuredOn: String
  private let sizes: [String: Size]

  init(schemaVersion: Int = 1, measuredOn: String, sizes: [EGOneSize: Size]) {
    self.schemaVersion = schemaVersion
    self.measuredOn = measuredOn
    self.sizes = Dictionary(uniqueKeysWithValues: sizes.map { ($0.key.rawValue, $0.value) })
  }

  /// A size the resource does not name has no measurements.
  func facts(for size: EGOneSize) -> Size { sizes[size.rawValue] ?? .unmeasured }

  /// No measurement at all: what a build with a missing or unreadable resource shows.
  static let none = EGOneSizeFacts(measuredOn: "", sizes: [:])

  static let resourceName = "eg1-size-facts"

  static func loadBundled(bundle: Bundle = .main) -> EGOneSizeFacts {
    guard let url = bundle.url(forResource: resourceName, withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let facts = try? JSONDecoder().decode(EGOneSizeFacts.self, from: data)
    else { return .none }
    return facts
  }
}
