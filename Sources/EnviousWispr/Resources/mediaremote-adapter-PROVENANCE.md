# mediaremote-adapter provenance (#1413)

`MediaRemoteAdapter.framework` and `mediaremote-adapter.pl` are the community
`mediaremote-adapter` by Jonas van den Berg (BSD 3-Clause, text in
`mediaremote-adapter-LICENSE.txt`), built from source rather than a downloaded
binary (upstream publishes none). They are the "pause whatever is playing"
route of the `Pause music` setting (`LiveMediaRemoteAdapter.swift`).

| Field | Value |
|---|---|
| Source | https://github.com/ungive/mediaremote-adapter |
| Tag / commit | `v0.7.7` = `e3ff5021eb0875858bd05f48d2e9ba2e962d1cf6` (2026-09-03) |
| Script | `bin/mediaremote-adapter.pl` at that commit, byte-identical (sha256 `d97802e46db9535e2549e178c105ebf417a0254b3929fc32f08ecfd14d49a85f`) |
| Toolchain | Apple clang 21.0.0 (clang-2100.1.1.101), macOS 26.5 SDK, CMake 4.3.4 |
| Configure | `cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_OBJC_COMPILER=/usr/bin/clang` then `cmake --build build` |
| Architectures | x86_64 + arm64 (upstream's `CMakeLists.txt` pins both; the x86_64 slice is dead weight on our Apple Silicon only range and costs ~130 KB) |
| Floor | `otool -l` `LC_BUILD_VERSION minos 14.0` (verify after any rebuild; the default builds the SDK's own floor, which cannot load on macOS 14/15) |
| Placement | `Contents/Frameworks/MediaRemoteAdapter.framework` (Tuist `copyFiles`, Apple TN2206 nested-code placement), script in `Contents/Resources` |
| Signing | `build-release-dmg.sh` signs the framework inside-out with the Developer ID before the app signature; `build-dev-app.sh` and the release script both fail closed when either file is missing |
| Never linked | the app never links this framework. `/usr/bin/perl` loads it (`DynaLoader`), because perl still carries Apple's MediaRemote entitlement that third-party apps lost on macOS 15.4 |

## FRAGILE, on purpose

This route depends on a private Apple framework reached through an entitlement
Apple could withdraw in any macOS update. When that happens the adapter reports
`unavailable`, the setting falls back to the scripted Music and Spotify route,
and the `dictation.terminal` telemetry row says so (`other_audio_media_route`,
`other_audio_adapter_failure`). Nothing else in the app depends on it. Do not
add a second consumer without re-reading this paragraph.

To rebuild: clone the pinned commit, run the configure line above, copy
`build/MediaRemoteAdapter.framework` (drop `Headers`) and `bin/mediaremote-adapter.pl`
here, update this file, run the adapter's `test` and `get` by hand through
`/usr/bin/perl` with absolute paths, then the live UAT rows in the #1413 plan.
