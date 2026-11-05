# CWebRTCAEC.framework — provenance (#4355)

The meeting echo cleaner framework embedded in the app (`Contents/Frameworks/CWebRTCAEC.framework`): WebRTC AEC3 behind a narrow C boundary.

| | |
|---|---|
| Upstream | https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing, tag `v2.1` at `846fe90a289f58b7c9303a635142aa2c7caa93e5`, unmodified |
| Abseil | `20240722.0` from upstream's pinned wrap `subprojects/abseil-cpp.wrap` (source and patch SHA-256 pinned there), statically linked |
| Boundary | `Vendor/webrtc-aec/` in this repository: `CWebRTCAEC.h` (the C API and its contract), `CWebRTCAEC.cc`, `exports.txt`, `module.modulemap`, `Info.plist.in` |
| Configuration | fixed in `CWebRTCAEC.cc`: 16 kHz mono, 160-sample (10 ms) float frames; AEC3 full output; noise suppression, both gain controllers and the high-pass filter off; stream delay seed 0 with AEC3's own estimator |
| Build | `Vendor/webrtc-aec/build-xcframework.sh <empty-dir> ew-4355.3` (Xcode 27.1 command line tools, `/usr/bin/clang`, meson 1.12.1, ninja); build id `ew-4355.3`; `BUILD-INFO.txt` at the xcframework root records the upstream revision and a hash of the boundary files |
| Binary | dynamic, arm64 only, minimum macOS 14.0; exports only the eight `ew_aec_*` functions; links only CoreFoundation, Foundation, libc++ and libSystem |
| Artifact | `https://models.enviouswispr.com/frameworks/cwebrtcaec/ew-4355.3/CWebRTCAEC.xcframework.zip` in our R2 bucket `enviouslabs-models`; the SwiftPM checksum is the `CWebRTCAEC` binaryTarget in `Package.swift` (SwiftPM verifies it on every resolve). The archive carries `LICENSE`, `PATENTS` and `LICENSE.*` at the xcframework root |
| Licences | `webrtc-aec-*.txt` beside this file; listed in `THIRD-PARTY-NOTICES.txt` by `scripts/ci/gen-third-party-notices.sh` |
| Release signing | re-signed inside-out with the Developer ID, hardened runtime and secure timestamp by `scripts/build-release-dmg.sh` step 5.8 |

To rebuild: run the build line into an empty folder, upload the zip under a NEW build-id path (never overwrite an object a released build pins), and put the new URL and `shasum -a 256` of the uploaded bytes into `Package.swift`.
