// Tests require full Xcode installation (not just Command Line Tools).
// XCTest and Swift Testing frameworks are not available with CLI tools only.
//
// To run tests: install Xcode, then `swift test`
//
// Test cases (to be enabled when Xcode is available):
// - testAppConstantsExist: AppConstants.appName == "EnviousWispr"
// - testASRBackendTypes: 2 backends (parakeet, whisperKit)
// - testPipelineStateStatusText: state machine text/isActive
// - testTranscriptDisplayText: raw vs polished text
// - testRecordingModes: pushToTalk, toggle

@testable import EnviousWispr

// Smoke test: just verify types resolve correctly
func verifyTypesCompile() {
    let _ = ASRBackendType.parakeet
    let _ = PipelineState.idle.statusText
    let _ = RecordingMode.pushToTalk
    let _ = Transcript(text: "hello")
    let _ = AppConstants.appName
}
