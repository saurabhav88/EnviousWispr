import Foundation
import Testing

/// Audit meta-rec #1 (Bible §11): confessional `public` exposure across module
/// boundaries is a known architecture smell. This test fails if a `public`
/// declaration in any non-executable module has a confessional `TODO` comment
/// within ±3 lines.
///
/// Pattern requires both `TODO` AND a structural-cross-module keyword in the
/// surrounding window. The conjunction avoids false positives like
/// `phaseString` (function name), `narrow_margin` (telemetry field), and
/// "single-phase" (literal phase counting in algorithms) that have no
/// architectural meaning.
@Suite struct CrossModulePublicGuardTests {

  @Test func noConfessionalCrossModulePublicExists() throws {
    let sourcesRoot = RepoRoot.sourceURL("Sources")
    var offenders: [String] = []

    // Exclude executable targets (app shell + XPC services). These are not
    // libraries that other modules consume, so cross-module-public is not a
    // meaningful concept for them.
    let executableTargets: Set<String> = [
      "EnviousWispr",
      "EnviousWisprAudioService",
      "EnviousWisprASRService",
    ]

    let modules = try FileManager.default.contentsOfDirectory(
      at: sourcesRoot, includingPropertiesForKeys: nil
    )
    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    .filter { !executableTargets.contains($0.lastPathComponent) }

    for module in modules {
      let files = try filesRecursively(at: module).filter { $0.pathExtension == "swift" }
      for file in files {
        let source = try String(contentsOf: file, encoding: .utf8)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
          .map(String.init)
        for (idx, line) in lines.enumerated() where line.contains("public ") {
          let lo = max(0, idx - 3)
          let hi = min(lines.count - 1, idx + 3)
          let window = lines[lo...hi].joined(separator: " ").lowercased()
          let hasTodo = window.contains("todo")
          let hasStructural =
            window.contains("narrow")
            || window.contains("temporary")
            || window.contains("cross-module") || window.contains("cross module")
            || window.range(of: #"phase\s*[a-z\d]+"#, options: .regularExpression) != nil
          if hasTodo && hasStructural {
            offenders.append(
              "\(file.path):\(idx + 1): \(line.trimmingCharacters(in: .whitespaces))")
          }
        }
      }
    }

    #expect(
      offenders.isEmpty,
      """
      Confessional cross-module `public` found (TODO + structural keyword within ±3 lines):
      \(offenders.joined(separator: "\n"))
      """)
  }
}

private func filesRecursively(at dir: URL) throws -> [URL] {
  guard
    let enumerator = FileManager.default.enumerator(
      at: dir, includingPropertiesForKeys: [.isRegularFileKey])
  else { return [] }
  return enumerator.compactMap { $0 as? URL }
    .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
}
