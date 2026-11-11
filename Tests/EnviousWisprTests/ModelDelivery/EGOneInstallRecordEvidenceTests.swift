import EnviousWisprAppKitTestSupport
import EnviousWisprCore
import Foundation
import Testing

@testable import EnviousWisprModelDelivery

/// #4473 (plan §3.1.1 S4): "this user had EG-1" is read from EG-1's install records.
///
/// When this fails, a user who had EG-1 installed before sizes existed is treated as new and
/// started on a smaller model, or a user who never had EG-1 (but has another model, or a
/// damaged leftover file) is treated as an EG-1 user and started on the largest one.
/// Encounter: the first launch of a build with sizes. Owner: plan #4473 P5.
@Suite("An EG-1 install record, of any revision, is the evidence that the user had EG-1 (#4473)", .tags(.productOutcome))
struct EGOneInstallRecordEvidenceTests {
  typealias Seed = EGOneMLXDeliveryTests

  struct Rig {
    let root = TestTemporaryDirectory.url
      .appendingPathComponent("eg1-evidence-\(UUID().uuidString)", isDirectory: true)
    var metadata: URL { root.appendingPathComponent("ModelDelivery", isDirectory: true) }
    func install(_ name: String) -> URL { root.appendingPathComponent("Models/\(name)") }
    var hasEGOne: Bool {
      PriorRevisionAdmission.hasReadableMarker(
        family: .egOne, name: "eg-1", metadataDirectory: metadata)
    }
    func seed(_ identity: ModelIdentity, folder: String) throws {
      try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
      try Seed.seedAdmitted(
        identity, files: [("w.bin", Data("w".utf8), "w.bin")], install: install(folder),
        metadata: metadata)
    }
    /// Every file under the root with its bytes.
    func snapshot() throws -> [String: Data] {
      var out: [String: Data] = [:]
      let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
      while let url = walker?.nextObject() as? URL {
        if let data = try? Data(contentsOf: url) { out[url.path] = data }
      }
      return out
    }
  }

  @Test(
    "the shipped llama revision, an older revision and the new MLX revision are each evidence",
    arguments: [
      ("eg1-1.2-c003", "q5km"), ("eg1-1.1-c001", "q5km"), ("eg1-1.3-intl-1c-20261109", "mlx-q6"),
    ])
  func anyRevisionIsEvidence(_ revision: String, _ variant: String) throws {
    let rig = Rig()
    #expect(!rig.hasEGOne, "nothing on disk, not even the folder")
    try rig.seed(Seed.identity(.egOne, "eg-1", revision, variant), folder: "eg-1")
    let before = try rig.snapshot()
    #expect(rig.hasEGOne)
    #expect(try rig.snapshot() == before, "asking changed a file")
  }

  @Test("another size, EG-1's checker and S-1 are not evidence of EG-1")
  func otherModelsAreNotEvidence() throws {
    let rig = Rig()
    try rig.seed(Seed.identity(.egOneMini, "eg-1-mini", "mini-a", "mlx-q6"), folder: "eg-1-mini")
    try rig.seed(Seed.identity(.egOneMicro, "eg-1-micro", "micro-a", "mlx-q6"), folder: "eg-1-micro")
    try rig.seed(Seed.identity(.s1Mini, "s1-mini", "s1-a", "q4km"), folder: "s1-mini")
    #expect(!rig.hasEGOne)
  }

  @Test("model files with no record, a record that cannot be read, and a name with no revision are not evidence")
  func leftoversAreNotEvidence() throws {
    let rig = Rig()
    try FileManager.default.createDirectory(at: rig.metadata, withIntermediateDirectories: true)
    // Weight files in EG-1's folder, no record.
    try FileManager.default.createDirectory(
      at: rig.install("eg-1"), withIntermediateDirectories: true)
    try Data("gguf".utf8).write(to: rig.install("eg-1").appendingPathComponent("eg1.gguf"))
    #expect(!rig.hasEGOne)
    // A file with a record's name that is not a record.
    try Data("not json".utf8).write(
      to: rig.metadata.appendingPathComponent("eg_one-eg-1-eg1-1.2-c003-q5km.admission.json"))
    try Data("{}".utf8).write(
      to: rig.metadata.appendingPathComponent("eg_one-eg-1-eg1-1.1-q5km.admission.json"))
    // The name with nothing where the revision goes.
    try Data(#"{"manifestDigest":"d","admittedAt":0,"files":[]}"#.utf8).write(
      to: rig.metadata.appendingPathComponent("eg_one-eg-1-.admission.json"))
    #expect(!rig.hasEGOne)
    // The control: the same well-formed record under a real name IS evidence.
    try Data(#"{"manifestDigest":"d","admittedAt":0,"files":[]}"#.utf8).write(
      to: rig.metadata.appendingPathComponent("eg_one-eg-1-r1-q5km.admission.json"))
    #expect(rig.hasEGOne)
  }
}
