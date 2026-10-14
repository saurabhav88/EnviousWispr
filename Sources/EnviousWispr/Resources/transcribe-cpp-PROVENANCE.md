# CTranscribe.framework — provenance (#3735)

The transcribe.cpp engine framework embedded in the app (`Contents/Frameworks/CTranscribe.framework`).

| | |
|---|---|
| Source | https://github.com/saurabhav88/transcribe.cpp (fork of https://github.com/handy-computer/transcribe.cpp) |
| Branch / commit | `ew/3735-v0.4.0-langprob` at `da01aa11adb09e18df4b0c621cb6623802bc2c1d` (upstream v0.4.0 `f1dcd158` plus additive Whisper APIs `transcribe_whisper_detect_language` and `transcribe_whisper_set_progress_callback`) |
| Build | `MACOS_MIN_OS_VERSION=14.0 TRANSCRIBE_XCFRAMEWORK_SLICES=macos scripts/ci/build_xcframework.sh` (the unmodified upstream builder), `CC=/usr/bin/clang CXX=/usr/bin/clang++` |
| Binary | dynamic, arm64 + x86_64, minimum macOS 14.0, Metal library embedded; links only system frameworks and libc++ |
| Artifact | release `ew-3735-v0.4.0.5`; URL and SwiftPM checksum: the `CTranscribe` binaryTarget in `Package.swift` (SwiftPM verifies the checksum on every resolve). The archive carries `LICENSE`, `LICENSE.ggml`, `LICENSE.miniz`, `LICENSE.silero_vad` at the xcframework root |
| Licences | `transcribe-cpp-LICENSE.txt`, `transcribe-cpp-ggml-LICENSE.txt`, `transcribe-cpp-miniz-LICENSE.txt`, `transcribe-cpp-silero-vad-LICENSE.txt` beside this file; listed in `THIRD-PARTY-NOTICES.txt` by `scripts/ci/gen-third-party-notices.sh` |
| Release signing | re-signed inside-out with the Developer ID, hardened runtime and secure timestamp by `scripts/build-release-dmg.sh` step 5.7 |

To rebuild: check out the commit above, run the build line, then copy the four licence files into `bindings/swift/build-apple/TranscribeCpp.xcframework/` and zip it with `ditto -c -k --sequesterRsrc --keepParent`. A new archive needs a new release tag and a new `Package.swift` checksum.
