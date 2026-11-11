import EnviousWisprCore

/// Test shorthand only (#4473). In a test, `.egOne` where a model identity is expected means
/// EG-1 at its FULL size, and `.s1Mini` means S1-mini's one model: the two models the app
/// served before sizes existed, which most suites are about. A test about another size writes
/// `.egOne(.mini)` or `.egOne(.micro)`. Production code has no such shorthand: there every
/// EG-1 identity names its size.
extension LocalPolishModelID {
  static var egOne: LocalPolishModelID { .egOne(.full) }
  static var s1Mini: LocalPolishModelID { .singleModel(for: .s1Mini) }
}
