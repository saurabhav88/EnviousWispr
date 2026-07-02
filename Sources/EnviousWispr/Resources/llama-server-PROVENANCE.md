# llama-server binary provenance (#1271)

The committed `llama-server` is the EG-1 native inference engine, built
from source (founder-approved 2026-07-02) rather than a downloaded
release binary, for full control over flags and supply chain.

| Field | Value |
|---|---|
| Source | https://github.com/ggml-org/llama.cpp (MIT) |
| Commit | `fdb1db877c526ec90f668eca1b858da5dba85560` (2026-07-02) |
| Toolchain | Apple clang (`/usr/bin/clang`), macOS 26 SDK, arm64 only |
| Configure | `cmake -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DLLAMA_OPENSSL=OFF -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF -DCMAKE_BUILD_TYPE=Release` (deployment target 14.0 REQUIRED — Codex r1 P1: the default builds `minos 26.0`, which cannot launch on the macOS 14/15 half of our supported range; verify `otool -l` shows `minos 14.0` after any rebuild) |
| Target | `llama-server` |
| Size | ~15 MB, single static binary |
| Dynamic deps | macOS system frameworks ONLY (verified `otool -L`: no Homebrew/OpenSSL — `LLAMA_OPENSSL=OFF` exists precisely because the first build linked `/opt/homebrew` dylibs that do not exist on user Macs) |

Runtime flags are owned by `EGOneRuntime` (LLM module), NOT baked in:
`-fa on --cache-type-k q8_0 --cache-type-v q8_0` + `-c` from the manifest.
Measured 2026-07-02 on the real EG-1 v1 GGUF (M4 Pro): 4.1 GB RSS at
16384 context (vs 7.4 GB naive 32768/fp16), ~9 s cold start, ~0.2 s warm
inference on the probe sentence, correct probe transformation.

To rebuild: clone the pinned commit, run the configure line above with
`-DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++`
(a stray `~/.local/bin/cc` shim breaks compiler detection otherwise),
then `cmake --build build --target llama-server`.

Upgrading the engine = rebuild from a newer pinned commit, update this
file, re-run the real-binary integration probe + the polish behavior
benchmark against the shipped config (the artifact + engine + flags
combination is the unit of QA).
