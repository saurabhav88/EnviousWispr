import Foundation
import PhoneNumberKit
import os

// MARK: - International phone-number metadata (#1677)
//
// The ONE adapter between the language cleanup passes and PhoneNumberKit (pinned in Package.swift).
// A pass hands it the ASCII digits of an EXPLICITLY international number (the digits after a
// written or spoken plus sign); it answers whether those digits form a number in a documented
// numbering range, and how to write it.
//
// CONTRACT
//  - Input is digits only. No letters, signs or separators ever reach the library, so its vanity-
//    letter mapping and free-text parsing cannot run.
//  - The answer never changes a digit: the library's E.164 result must equal the input digits,
//    and so must the formatted text, or the answer is `.invalid(.digitsChanged)`.
//  - Validity means the national number matches a documented pattern for its calling code
//    (length AND number type), not that a subscriber is reachable.
//  - Formatting is the metadata's international grouping with spaces (DIN 5008 style):
//    a hyphen the metadata uses between groups becomes a space.
//
// DATA
// The metadata is `Resources/phone-number-metadata.json`, byte-identical to the
// `PhoneNumberMetadata.json` PhoneNumberKit 5.0.11 ships (Google libphonenumber v9.0.40 data;
// hash pinned by LanguagePhoneMetadataTests). It is loaded from THIS module's bundle, the same
// path the emoji dictionary and British spelling table use, and handed to the library through its
// metadata callback, so the library's own bundle lookup never runs. A missing or unreadable
// resource makes the adapter `.unavailable`; nothing crashes and no pass converts.
//
// REGION
// The library's parse requires a region argument. It is irrelevant for input that starts with
// "+" and is passed explicitly so the library never consults the device locale or Contacts.

final class LanguagePhoneMetadata: @unchecked Sendable {

  struct International: Sendable, Equatable {
    /// The calling code, as digits.
    let countryCode: String
    /// The national significant number, as digits, including an Italian leading zero.
    let nationalNumber: String
    /// The written form: "+", the calling code, then the metadata grouping joined by spaces.
    let formatted: String
  }

  enum Invalid: Sendable, Equatable {
    /// Not 2 to 15 ASCII digits (E.164 allows at most 15).
    case notDigits
    /// No assigned calling code starts the digits, or the national number fits no pattern.
    case notANumber
    /// The library's reading or formatting would add, drop or change a digit.
    case digitsChanged
  }

  enum Answer: Sendable, Equatable {
    case valid(International)
    case invalid(Invalid)
    /// The metadata could not be loaded; no number can be validated.
    case unavailable(String)
  }

  static let resourceName = "phone-number-metadata"
  static let maxDigits = 15
  /// Required by the library's API and unused for "+" input (see REGION above).
  static let parseRegion = "DE"

  /// The shared instance, loading `Resources/phone-number-metadata.json` from this module's bundle
  /// on first use.
  static let shared = LanguagePhoneMetadata(loadMetadata: {
    guard let url = Bundle.module.url(forResource: resourceName, withExtension: "json") else {
      throw LoadError.missing
    }
    return try Data(contentsOf: url)
  })

  /// The `Bundle.module` URL `shared` loads, or nil if the resource bundle did not ship. The SAME
  /// lookup as production, so a test can assert the resource resolves under the Xcode build.
  // periphery:ignore - test seam (resource-resolution diagnostic)
  static var bundledMetadataURLForDiagnostics: URL? {
    Bundle.module.url(forResource: resourceName, withExtension: "json")
  }

  enum LoadError: Error, Equatable {
    case missing
  }

  private struct Loaded {
    let utility: PhoneNumberUtility
    /// Every assigned calling code, as digits (prefix-free by E.164 design).
    let callingCodes: Set<String>
  }

  private enum State {
    case unloaded
    case loaded(Loaded)
    case failed(String)
  }

  private let loadMetadata: @Sendable () throws -> Data
  /// The library's utility is not thread-safe (its regex cache is a plain dictionary), so every
  /// call runs under this lock.
  private let state = OSAllocatedUnfairLock<State>(uncheckedState: .unloaded)

  init(loadMetadata: @escaping @Sendable () throws -> Data) {
    self.loadMetadata = loadMetadata
  }

  func international(digits: String) -> Answer {
    guard (2...Self.maxDigits).contains(digits.utf8.count),
      digits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 })
    else { return .invalid(.notDigits) }
    switch withLoaded({ Self.answer(digits: digits, utility: $0.utility) }) {
    case .success(let answer): return answer
    case .failure(let failure): return .unavailable(failure.description)
    }
  }

  /// Whether `digits` (1 to 3 ASCII digits) is exactly an assigned calling code; nil when the
  /// metadata is unavailable.
  func isAssignedCallingCode(_ digits: String) -> Bool? {
    guard (1...3).contains(digits.utf8.count),
      digits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 })
    else { return false }
    switch withLoaded({ $0.callingCodes.contains(digits) }) {
    case .success(let assigned): return assigned
    case .failure: return nil
    }
  }

  /// Runs `body` under the lock with the loaded metadata, loading it on first use.
  private func withLoaded<T>(_ body: (Loaded) -> T) -> Result<T, Failure> {
    state.withLockUnchecked { state -> Result<T, Failure> in
      switch state {
      case .loaded(let loaded):
        return .success(body(loaded))
      case .failed(let reason):
        return .failure(Failure(description: reason))
      case .unloaded:
        switch Self.load(loadMetadata) {
        case .success(let loaded):
          state = .loaded(loaded)
          return .success(body(loaded))
        case .failure(let failure):
          state = .failed(failure.description)
          return .failure(failure)
        }
      }
    }
  }

  // MARK: Internals

  private struct Failure: Error, CustomStringConvertible {
    let description: String
  }

  private static func load(
    _ load: @Sendable () throws -> Data
  ) -> Result<Loaded, Failure> {
    let data: Data
    do {
      data = try load()
    } catch {
      return .failure(Failure(description: "phone metadata not loaded: \(error)"))
    }
    let utility = PhoneNumberUtility(metadataCallback: { data })
    // The library swallows a decode failure into empty metadata; probe one known-valid number so
    // an unreadable resource is reported instead of silently refusing every number.
    guard (try? utility.parse("+4930123456", withRegion: parseRegion)) != nil else {
      return .failure(Failure(description: "phone metadata did not decode"))
    }
    let codes = Set(utility.allCountries().compactMap { utility.countryCode(for: $0) }.map(String.init))
    return .success(Loaded(utility: utility, callingCodes: codes))
  }

  private static func answer(digits: String, utility: PhoneNumberUtility) -> Answer {
    let number: PhoneNumber
    do {
      number = try utility.parse("+" + digits, withRegion: parseRegion)
    } catch {
      return .invalid(.notANumber)
    }
    guard number.numberExtension == nil else { return .invalid(.digitsChanged) }
    let e164 = utility.format(number, toType: .e164)
    guard e164 == "+" + digits else { return .invalid(.digitsChanged) }
    let international = utility.format(number, toType: .international)
    let formatted = String(
      international.unicodeScalars.map { $0 == "-" ? " " : Character($0) })
    guard formatted.hasPrefix("+"),
      formatted.unicodeScalars.allSatisfy({ ($0 >= "0" && $0 <= "9") || $0 == " " || $0 == "+" }),
      formatted.filter(\.isASCIIDigitCharacter) == digits
    else { return .invalid(.digitsChanged) }
    let code = String(number.countryCode)
    return .valid(
      International(
        countryCode: code, nationalNumber: String(digits.dropFirst(code.count)),
        formatted: formatted))
  }
}

extension Character {
  fileprivate var isASCIIDigitCharacter: Bool {
    guard let ascii = asciiValue else { return false }
    return ascii >= 0x30 && ascii <= 0x39
  }
}
