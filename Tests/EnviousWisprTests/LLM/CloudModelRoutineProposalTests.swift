import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprLLM
import EnviousWisprAppKitTestSupport

/// #4353 PR 5 (D7 detail, Receipt and proposal contract): receipts written by the real fake-run
/// harness go through the real `scripts/cloud-models/propose.py`, so the Python checker is
/// proven against Swift's own encoding rather than hand-written fixtures. Offline: fake
/// vendors, fake keys, the committed list at this checkout's HEAD as the recorded base.
@Suite("Cloud model routine proposal (#4353 PR 5)", .tags(.harnessContract))
struct CloudModelRoutineProposalTests {
  typealias H = CloudModelRoutineHarnessTests
  typealias S = CloudModelRoutineSearchTests

  static var repoRoot: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
  }

  struct Ran {
    let status: Int32
    let output: String
  }

  static func run(_ executable: String, _ arguments: [String]) throws -> Ran {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [executable] + arguments
    process.currentDirectoryURL = repoRoot
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    // Drain while the child runs so a full pipe cannot deadlock it.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return Ran(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
  }

  static func head() throws -> String {
    let ran = try run("git", ["-C", repoRoot.path, "rev-parse", "HEAD"])
    try #require(ran.status == 0)
    return ran.output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func environment(sourceSHA: String) -> [String: String] {
    [
      "GITHUB_REPOSITORY": "example/repo", "GITHUB_WORKFLOW": "cloud-models-sweep",
      "GITHUB_RUN_ID": "101", "GITHUB_RUN_ATTEMPT": "1", "GITHUB_EVENT_NAME": "schedule",
      "GITHUB_REF": "refs/heads/main", "GITHUB_SHA": sourceSHA,
    ]
  }

  /// A fresh folder with the receipt and the caller's context written in.
  struct Inputs {
    let folder: URL
    var receipt: URL { folder.appendingPathComponent("receipt.json") }
    var context: URL { folder.appendingPathComponent("context.json") }
    var result: URL { folder.appendingPathComponent("result.json") }
    var output: URL { folder.appendingPathComponent("out") }
  }

  static func inputs(_ receipt: CloudModelRoutineReceipt, sourceSHA: String) throws -> Inputs {
    let folder = TestTemporaryDirectory.url.appendingPathComponent(
      "cloud-model-proposal-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let inputs = Inputs(folder: folder)
    let bytes = try receipt.encoded(refusing: Array(H.keys.values.values))
    try bytes.write(to: inputs.receipt)
    var context = environment(sourceSHA: sourceSHA).reduce(into: [String: Any]()) {
      let names = [
        "GITHUB_REPOSITORY": "repository", "GITHUB_WORKFLOW": "workflow",
        "GITHUB_RUN_ID": "runID", "GITHUB_RUN_ATTEMPT": "runAttempt",
        "GITHUB_EVENT_NAME": "event", "GITHUB_REF": "ref", "GITHUB_SHA": "sourceSHA",
      ]
      $0[names[$1.key]!] = $1.value
    }
    context["schema"] = 1
    context["receiptSHA256"] = CloudModelRoutineReceipt.sha256(bytes)
    try JSONSerialization.data(withJSONObject: context).write(to: inputs.context)
    return inputs
  }

  static var script: String {
    repoRoot.appendingPathComponent("scripts/cloud-models/propose.py").path
  }

  static func common(_ inputs: Inputs, base: String) -> [String] {
    [
      "--repo", repoRoot.path, "--base", base, "--receipt", inputs.receipt.path,
      "--context", inputs.context.path, "--result", inputs.result.path,
    ]
  }

  static func generate(_ inputs: Inputs, base: String) throws -> Ran {
    try run(
      "python3",
      ["-B", script, "generate"] + common(inputs, base: base) + [
        "--output-root", inputs.output.path,
      ])
  }

  static func check(_ inputs: Inputs, base: String) throws -> Ran {
    try run(
      "python3",
      ["-B", script, "check"] + common(inputs, base: base) + [
        "--current-root", inputs.output.path, "--target-base", base,
      ])
  }

  static func result(_ inputs: Inputs) throws -> [String: Any] {
    try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: inputs.result)) as? [String: Any])
  }

  static func publicList(_ inputs: Inputs) throws -> Data {
    try Data(contentsOf: inputs.output.appendingPathComponent("website/public/cloud-models.json"))
  }

  // MARK: - Tests

  @Test("a real fake-run receipt: the checker appends the three fallback rows and accepts them")
  func fallbackReceiptRoundTrip() async throws {
    let base = try Self.head()
    let receipt = await CloudModelRoutine.run(
      keys: H.keys, list: H.seed, observedAt: H.observedAt,
      transports: H.vendorsWithNewModels().transports,
      provenance: .from(environment: Self.environment(sourceSHA: base)))
    let inputs = try Self.inputs(receipt, sourceSHA: base)

    let generated = try Self.generate(inputs, base: base)
    #expect(generated.status == 0, "\(generated.output)")
    let result = try Self.result(inputs)
    #expect(result["outcome"] as? String == "success")
    #expect(result["proposalStatus"] as? String == "proposed")
    let operations = try #require(result["operations"] as? [[String: Any]])
    #expect(
      operations.map { "\($0["op"]!) \($0["provider"]!)/\($0["id"]!) \($0["via"]!)" } == [
        "add openAI/gpt-9-zeta fallback", "add claude/claude-zeta-9 fallback",
        "add gemini/gemini-9-flash fallback",
      ])
    // The proposed list is valid for the app's own parser and keeps every captured row.
    let proposed = try Self.publicList(inputs)
    guard case .success(let list) = CloudModelList.validated(from: proposed) else {
      Issue.record("the app's parser refused the proposed list")
      return
    }
    #expect(Array(list.models.prefix(H.seed.models.count)) == H.seed.models)
    #expect(list.models.count == H.seed.models.count + 3)
    let zeta = try #require(list.models.first { $0.id == "gpt-9-zeta" })
    #expect(zeta.recommended == false && zeta.hidden == false)
    #expect(
      LLMProvider.openAI.modelCapabilities(model: "gpt-9-zeta", list: list)
        == LLMProvider.openAI.modelCapabilities(model: "gpt-9-zeta", list: H.seed))

    let checked = try Self.check(inputs, base: base)
    #expect(checked.status == 0, "\(checked.output)")

    // Any other byte in the proposal is refused.
    let edited = String(decoding: proposed, as: UTF8.self).replacingOccurrences(
      of: "\"recommended\": false", with: "\"recommended\": true")
    for path in [
      "website/public/cloud-models.json", "Sources/EnviousWispr/Resources/cloud-models.json",
    ] {
      try Data(edited.utf8).write(to: inputs.output.appendingPathComponent(path))
    }
    let refused = try Self.check(inputs, base: base)
    #expect(refused.status == 1)
    #expect(refused.output.contains("refused:"))
  }

  @Test("a real searched receipt: the checker proposes the chosen setting")
  func searchedReceiptRoundTrip() async throws {
    let base = try Self.head()
    let sent = S.Sent()
    let vendors = S.vendors(.openAI, sent: sent) { setting, _ in
      setting == "none/omit" ? nil : S.reject(.openAI)
    }
    let receipt = await CloudModelRoutine.run(
      keys: H.keys, list: H.seed, observedAt: H.observedAt,
      transports: vendors.transports,
      provenance: .from(environment: Self.environment(sourceSHA: base)))
    let inputs = try Self.inputs(receipt, sourceSHA: base)
    let generated = try Self.generate(inputs, base: base)
    #expect(generated.status == 0, "\(generated.output)")
    let operations = try #require(try Self.result(inputs)["operations"] as? [[String: Any]])
    let openAI = try #require(operations.first { $0["provider"] as? String == "openAI" })
    #expect(openAI["via"] as? String == "search")
    #expect(openAI["setting"] as? String == "openAI:none/omit")
    guard case .success(let list) = CloudModelList.validated(from: try Self.publicList(inputs))
    else {
      Issue.record("the app's parser refused the proposed list")
      return
    }
    #expect(
      LLMProvider.openAI.listedRow(model: "gpt-9-zeta", list: list)?.request
        == .openAI(effort: CloudModelList.OpenAIEffort.none, temperature: .omit))
    #expect(try Self.check(inputs, base: base).status == 0)
  }

  @Test("a real receipt where an earlier setting's confirmation output is unusable is accepted")
  func unusableConfirmationRoundTrip() async throws {
    let base = try Self.head()
    let sent = S.Sent()
    let second = CloudModelRoutine.inputs[1].text
    let vendors = S.vendors(.openAI, sent: sent) { setting, input in
      switch setting {
      // Returned, timed, then judged unusable on confirmation input 1.
      case "omit/omit":
        return input == second ? (200, H.Vendors.success(.openAI, text: "<thinking>x</thinking>")) : nil
      case "none/include": return nil
      default: return S.reject(.openAI)
      }
    }
    let receipt = await CloudModelRoutine.run(
      keys: H.keys, list: H.seed, observedAt: H.observedAt,
      transports: vendors.transports,
      provenance: .from(environment: Self.environment(sourceSHA: base)))
    #expect(
      sent.settings(.openAI) == [
        "omit/include", "omit/omit", "omit/omit", "omit/omit", "none/include", "none/include",
        "none/include", "none/include",
      ])
    let attempt = try #require(
      H.candidates(receipt, .openAI).first?.search?.attempts.first)
    #expect(attempt.confirmation?.errorClass == .unusableOutput)
    #expect(attempt.confirmation?.perInputMs.count == 2)
    let inputs = try Self.inputs(receipt, sourceSHA: base)
    let generated = try Self.generate(inputs, base: base)
    #expect(generated.status == 0, "\(generated.output)")
    let operations = try #require(try Self.result(inputs)["operations"] as? [[String: Any]])
    #expect(
      operations.first { $0["provider"] as? String == "openAI" }?["setting"] as? String
        == "openAI:none/include")
    #expect(try Self.check(inputs, base: base).status == 0)
  }

  @Test("a receipt without GitHub provenance is refused and writes nothing")
  func missingProvenanceRefused() async throws {
    let base = try Self.head()
    let receipt = await CloudModelRoutine.run(
      keys: H.keys, list: H.seed, observedAt: H.observedAt,
      transports: H.vendorsWithNewModels().transports, provenance: .from(environment: [:]))
    let inputs = try Self.inputs(receipt, sourceSHA: base)
    let generated = try Self.generate(inputs, base: base)
    #expect(generated.status == 1)
    #expect(generated.output.contains("provenance"))
    #expect(FileManager.default.fileExists(atPath: inputs.result.path) == false)
    #expect(FileManager.default.fileExists(atPath: inputs.output.path) == false)
  }
}
