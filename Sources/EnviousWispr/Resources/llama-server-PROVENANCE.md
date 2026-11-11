# llama-server binary provenance (#1271)

The committed `llama-server` is the EG-1 native inference engine, built
from source (founder-approved 2026-07-02) rather than a downloaded
release binary, for full control over flags and supply chain.

| Field | Value |
|---|---|
| Source | https://github.com/ggml-org/llama.cpp (MIT) |
| Commit | `fdb1db877c526ec90f668eca1b858da5dba85560` (2026-07-02) |
| Patch | `llama-server-patches/ew-stop-on-stdin-eof.patch` (#4493), sha256 `19d020c805002cac6eea96e82d27f0db6d5efa82beb1410442476dd3ff35d456`; the only change to the pinned source |
| Binary | sha256 `005eaa0e43935e6b2da81494e7c62098a04d83e48e4cbdb0e998ac6ece7f9854`, built 2026-11-11 |
| Toolchain | Apple clang 21.0.0 (`/usr/bin/clang`, Xcode 27.1), macOS 27.0 SDK, arm64 only. The binary before #4493 was built 2026-07-02 with the macOS 26 SDK |
| Configure | `cmake -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DLLAMA_OPENSSL=OFF -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF -DCMAKE_BUILD_TYPE=Release` (deployment target 14.0 REQUIRED — Codex r1 P1: the default builds `minos 26.0`, which cannot launch on the macOS 14/15 half of our supported range; verify `otool -l` shows `minos 14.0` after any rebuild) |
| Target | `llama-server` |
| Size | ~15 MB, single static binary |
| Dynamic deps | macOS system frameworks ONLY (verified `otool -L`: no Homebrew/OpenSSL — `LLAMA_OPENSSL=OFF` exists precisely because the first build linked `/opt/homebrew` dylibs that do not exist on user Macs) |

Runtime flags are owned by `LlamaServerLaunchBuilder` (`EnviousWisprLlamaEngine` module), NOT baked in:
`-fa on --cache-type-k q8_0 --cache-type-v q8_0` + `-c` from the manifest;
EG-1 also gets `--spec-type ngram-simple` (word-copying, #3363). Exact lists:
`LlamaServerLaunchBuilder.engineArguments(for:)` and `launchArguments(for:learnedWordAdapterURL:)`.
Measured 2026-07-02 on the real EG-1 v1 GGUF (M4 Pro): 4.1 GB RSS at
16384 context (vs 7.4 GB naive 32768/fp16), ~9 s cold start, ~0.2 s warm
inference on the probe sentence, correct probe transformation.

## The carried patch (#4493)

The patch adds one behavior, off unless the environment variable
`EW_STOP_ON_STDIN_EOF` is present: the server reads its stdin until
end-of-file and then sends itself SIGTERM, and a stop signal that arrives
after a stop has begun is the same stop (upstream's "second interrupt
forces `exit(1)`" branch is skipped only in this managed mode). The app
holds the write end of a pipe on the server's stdin, so the server stops
when the app is gone for any reason. Without the variable the binary
behaves as upstream does.

Why it is a patch and not upstream's own stdin monitor
(`LLAMA_SERVER_ROUTER_PORT`): that monitor ends the process with `exit(1)`
from a side thread, which aborts inside `ggml_metal_rsets_free` and leaves
a macOS crash report on every stop (measured 2026-11-11, #4493).

A rebuilt binary is qualified against the binary it replaces before it is
committed: launch flags as `LlamaServerLaunchBuilder` renders them, each
bundled model with its checker adapter absent and present, deterministic
chat answers, checker token probabilities, chat after checker use, and the
stop orders (stdin end-of-file, SIGTERM, both in either order, during model
load, during a long answer), on this Mac and on macOS 14. Any unexplained
difference stops the change. The real-boundary test that starts the bundled
server (#4493 R2) fails if a later rebuild loses the stop behavior.

To rebuild: clone the pinned commit, apply the patch
(`git apply llama-server-patches/ew-stop-on-stdin-eof.patch`), run the
configure line above with
`-DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++`
(a stray `~/.local/bin/cc` shim breaks compiler detection otherwise),
then `cmake --build build --target llama-server`. Check `otool -l` for
`minos 14.0` and `otool -L` for system libraries only.

Upgrading the engine = rebuild from a newer pinned commit, update this
file, re-run the real-binary integration probe + the polish behavior
benchmark against the shipped config (the artifact + engine + flags
combination is the unit of QA).
