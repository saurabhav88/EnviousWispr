import CryptoKit
import Foundation
import Testing

@testable import EnviousWisprPostProcessing

// MARK: - International phone-number metadata adapter (#1677)
//
// Drives the real adapter over the real bundled metadata. The expected written forms are literals
// recorded once from the pinned library's international format (hyphens as spaces): they pin the
// grouping so a metadata or adapter change is visible, they do not prove it is the best German
// style. The digit checks are independent of the library: every expected form must carry exactly
// the input digits.
//
// When this fails: the bundled metadata no longer matches the pinned PhoneNumberKit release, a
// glued international number is split at the wrong place, a digit is added or dropped, or a
// missing resource stops failing safely.

@Suite("International phone-number metadata (#1677)", .tags(.productOutcome))
struct LanguagePhoneMetadataTests {

  let metadata = LanguagePhoneMetadata.shared

  private func formatted(_ digits: String) -> String? {
    if case .valid(let number) = metadata.international(digits: digits) { return number.formatted }
    return nil
  }

  // MARK: Pins

  @Test("the bundled metadata is the PhoneNumberKit 5.0.11 copy and the package pin agrees")
  func pinnedMetadataAndPackage() throws {
    let url = try #require(
      LanguagePhoneMetadata.bundledMetadataURLForDiagnostics,
      "phone-number-metadata.json did not ship in the PostProcessing resource bundle")
    let digest = SHA256.hash(data: try Data(contentsOf: url))
      .map { String(format: "%02x", $0) }.joined()
    #expect(digest == "76d69e03de3b98f8c365c80236e5786726aa48be93551f4ea9bbc8df62be1944")

    // The copy is only correct for the release it was taken from.
    let resolvedURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Package.resolved")
    let resolved = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: resolvedURL)) as? [String: Any])
    let pins = try #require(resolved["pins"] as? [[String: Any]])
    let pin = try #require(pins.first { ($0["identity"] as? String) == "phonenumberkit" })
    let state = try #require(pin["state"] as? [String: Any])
    #expect(state["version"] as? String == "5.0.11")
    #expect(state["revision"] as? String == "faf1703e6fc71c699e911ff0e306c58ad7c756c0")
  }

  // MARK: Valid numbers

  @Test(
    "a glued international number splits at its calling code and keeps every digit",
    arguments: [
      ("491769087654", "+49 176 9087654"),
      ("4317894321", "+43 1 7894321"),
      ("436649081122", "+43 664 9081122"),
      ("390687708990", "+39 06 8770 8990"),
      ("46319876543", "+46 31 987 65 43"),
      ("16047291846", "+1 604 729 1846"),
      ("79161234567", "+7 916 123 45 67"),
      ("81345678901", "+81 3 4567 8901"),
      ("3226017744", "+32 2 601 77 44"),
    ])
  func validNumbers(digits: String, expected: String) {
    #expect(formatted(digits) == expected)
    if case .valid(let number) = metadata.international(digits: digits) {
      #expect(number.countryCode + number.nationalNumber == digits)
      #expect(Array(expected.filter { $0.isNumber }.utf8) == Array(digits.utf8))
    }
  }

  // MARK: Refusals

  @Test(
    "digits that form no documented number are refused, not repaired",
    arguments: ["49176", "3908770899", "999999999999", "4930", "0049301234567"])
  func notANumber(digits: String) {
    #expect(metadata.international(digits: digits) == .invalid(.notANumber))
  }

  @Test(
    "anything but 2 to 15 ASCII digits never reaches the library",
    arguments: [
      "", "4", "+491769087654", "49 176 9087654", "4917690876541234", "٤٩١٧٦٩٠٨٧٦٥٤",
      "49176908765a",
    ])
  func notDigits(input: String) {
    #expect(metadata.international(digits: input) == .invalid(.notDigits))
  }

  @Test("a parseable international number is refused when parsing removes a digit")
  func nationalPrefixRemovalIsRefused() {
    // The library strips the British trunk 0 and parses the rest; the adapter must refuse the
    // dropped digit. Paired with the same number written without the trunk 0.
    #expect(metadata.international(digits: "4402070313000") == .invalid(.digitsChanged))
    #expect(formatted("442070313000") == "+44 20 7031 3000")
  }

  @Test("calling codes are read from the metadata, exactly, never as a prefix")
  func callingCodes() {
    for code in ["1", "7", "41", "44", "49", "420", "886"] {
      #expect(metadata.isAssignedCallingCode(code) == true, "\(code)")
    }
    for code in ["0", "2", "999", "4917", "", "4a", "٤٩"] {
      #expect(metadata.isAssignedCallingCode(code) == false, "\(code)")
    }
    let broken = LanguagePhoneMetadata(loadMetadata: { throw LanguagePhoneMetadata.LoadError.missing })
    #expect(broken.isAssignedCallingCode("49") == nil)
  }

  // MARK: Failure safety

  @Test("a missing metadata resource answers unavailable on every call and never converts")
  func missingResource() {
    let broken = LanguagePhoneMetadata(loadMetadata: {
      throw LanguagePhoneMetadata.LoadError.missing
    })
    for _ in 0..<2 {
      guard case .unavailable = broken.international(digits: "491769087654") else {
        Issue.record("expected unavailable")
        return
      }
    }
  }

  @Test("undecodable metadata is reported as unavailable, not as an empty table")
  func undecodableResource() {
    let broken = LanguagePhoneMetadata(loadMetadata: { Data("{\"nope\":1}".utf8) })
    #expect(
      broken.international(digits: "491769087654") == .unavailable("phone metadata did not decode"))
  }

  @Test("concurrent callers get the same answers")
  func concurrentCallers() async {
    let inputs = ["491769087654", "390687708990", "49176", "16047291846"]
    let expected = inputs.map { metadata.international(digits: $0) }
    await withTaskGroup(of: Bool.self) { group in
      for round in 0..<200 {
        let index = round % inputs.count
        group.addTask { [metadata] in
          metadata.international(digits: inputs[index]) == expected[index]
        }
      }
      for await same in group { #expect(same) }
    }
  }
}
