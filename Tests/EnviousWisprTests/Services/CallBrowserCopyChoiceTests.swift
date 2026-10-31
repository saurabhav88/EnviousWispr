import Foundation
import Testing

@testable import EnviousWisprServices

/// #4168: with two copies of one browser running (for example Chrome started a second time with
/// its own profile folder), a microphone-holding helper belongs to the copy that started it, found
/// through its parent process. Both copies share one app bundle path, so the path alone cannot tell.
@Suite("Call detection: which browser copy holds the microphone", .tags(.productOutcome))
struct CallBrowserCopyChoiceTests {
  typealias Copy = (pid: Int32, bundlePath: String?)
  private static let chrome = "/Applications/Google Chrome.app"

  @Test("the helper's parent copy wins over another copy at the same app path")
  func parentCopyWins() {
    // The everyday copy (pid 508) is listed first; the helper belongs to the second copy (16374).
    let copies: [Copy] = [(508, Self.chrome), (16374, Self.chrome)]
    #expect(
      CallEvidenceReader.chooseBrowserCopy(
        holderPID: 17761, ancestorPIDs: [16374, 1], copies: copies, holderAppPath: Self.chrome)
        == 16374)
  }

  @Test("the holder itself is the copy when it is a running copy")
  func holderItself() {
    let copies: [Copy] = [(508, Self.chrome), (16374, Self.chrome)]
    #expect(
      CallEvidenceReader.chooseBrowserCopy(
        holderPID: 16374, ancestorPIDs: [1], copies: copies, holderAppPath: Self.chrome) == 16374)
  }

  @Test("an ancestor further up the chain still finds the copy")
  func grandparentCopy() {
    let copies: [Copy] = [(508, Self.chrome), (16374, Self.chrome)]
    #expect(
      CallEvidenceReader.chooseBrowserCopy(
        holderPID: 17761, ancestorPIDs: [17000, 16374], copies: copies, holderAppPath: Self.chrome)
        == 16374)
  }

  @Test("two copies at one path and no parent link is unknown, never the first listed")
  func ambiguousIsUnknown() {
    let copies: [Copy] = [(508, Self.chrome), (16374, Self.chrome)]
    #expect(
      CallEvidenceReader.chooseBrowserCopy(
        holderPID: 17761, ancestorPIDs: [], copies: copies, holderAppPath: Self.chrome) == nil)
  }

  @Test("one copy at the holder's app path is that copy, as before")
  func singleCopyAtPath() {
    let copies: [Copy] = [(508, Self.chrome), (700, "/Applications/Google Chrome Beta.app")]
    #expect(
      CallEvidenceReader.chooseBrowserCopy(
        holderPID: 17761, ancestorPIDs: [], copies: copies, holderAppPath: Self.chrome) == 508)
  }

  @Test("with no app path the only running copy is used, and two unrelated copies are unknown")
  func noPath() {
    #expect(
      CallEvidenceReader.chooseBrowserCopy(
        holderPID: 17761, ancestorPIDs: [], copies: [(508, Self.chrome)], holderAppPath: nil) == 508)
    #expect(
      CallEvidenceReader.chooseBrowserCopy(
        holderPID: 17761, ancestorPIDs: [],
        copies: [(508, Self.chrome), (700, "/Applications/Google Chrome Beta.app")],
        holderAppPath: nil) == nil)
  }
}
