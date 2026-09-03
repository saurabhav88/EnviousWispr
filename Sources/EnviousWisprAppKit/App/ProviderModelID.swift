import Foundation

/// Facts about the SHAPE of a cloud provider's model id, shared by everything
/// that has to recognise the same model under two spellings.
///
/// #2602: this exists because there were briefly two implementations of the
/// same rule in this module — `SettingsChangeTelemetry.stripDateSnapshotSuffix`,
/// which collapses a dated id onto its allowlist entry, and a copy added to
/// `AIPolishModelClassifier` so a dated snapshot of a named model keeps its
/// tier. One fact, one owner: two copies of a date rule diverge the moment a
/// provider ships a shape only one of them was taught.
///
/// It is a provider-id fact rather than classifier policy, which is why it did
/// not stay on `AIPolishModelClassifier` — that type's own note asks callers not
/// to adopt it elsewhere without revisiting placement, and this is that.
enum ProviderModelID {

  /// The id with a trailing DATED SNAPSHOT removed, or `nil` when there is none.
  ///
  /// Two shapes and only two, because those are the two the providers ship:
  /// OpenAI's dashed `-YYYY-MM-DD` (`gpt-5-mini-2025-08-07`) and Anthropic's
  /// compact `-YYYYMMDD` (`claude-haiku-4-5-20251001`). Mixed separators are
  /// refused — `-2025-1001` is nobody's format.
  ///
  /// A REAL CALENDAR DATE is required, not merely eight digits, because a model
  /// id may legitimately end in a number: `claude-fable-5-1` and
  /// `gemini-2.5-flash` must survive untouched. This is stricter than the
  /// telemetry copy it replaces, which matched digit shapes alone and would
  /// therefore have collapsed `gpt-4-20259999` onto `gpt-4`; a nonsense id now
  /// reports as `custom`, which is the honest answer.
  ///
  /// OpenAI's older four-digit `MMDD` snapshots (`gpt-3.5-turbo-0125`) are
  /// deliberately NOT stripped: four digits cannot be told from a version.
  static func withoutDateSnapshot(_ id: String) -> String? {
    // Dashed first: it is the longer suffix, so trying it first cannot be
    // shadowed by the compact form.
    strippingDate(from: id, dashed: true) ?? strippingDate(from: id, dashed: false)
  }

  /// Removes a trailing `-` plus a `YYYY MM DD` date, dashed between the groups
  /// or run together, when the digits are a real date.
  private static func strippingDate(from id: String, dashed: Bool) -> String? {
    let groups = [4, 2, 2]
    let suffixLength = groups.reduce(0, +) + (dashed ? groups.count - 1 : 0) + 1  // + leading "-"
    guard id.count > suffixLength else { return nil }
    let suffix = String(id.suffix(suffixLength))
    guard suffix.hasPrefix("-") else { return nil }

    var remainder = Substring(suffix.dropFirst())
    var values: [Int] = []
    for (index, groupLength) in groups.enumerated() {
      if dashed && index > 0 {
        guard remainder.first == "-" else { return nil }
        remainder = remainder.dropFirst()
      }
      let group = remainder.prefix(groupLength)
      guard group.count == groupLength,
        group.allSatisfy({ $0.isASCII && $0.isNumber }),
        let value = Int(group)
      else { return nil }
      values.append(value)
      remainder = remainder.dropFirst(groupLength)
    }
    guard remainder.isEmpty else { return nil }

    var components = DateComponents()
    components.year = values[0]
    components.month = values[1]
    components.day = values[2]
    guard (2000...2099).contains(values[0]),
      components.isValidDate(in: Calendar(identifier: .gregorian))
    else { return nil }

    return String(id.dropLast(suffixLength))
  }
}
