# Recording sound provenance

All eight WAV files (`airGlint_*`, `velvetTap_*`, `satinShift_*`, `cloudPop_*`) were generated procedurally for EnviousWispr using additive sine synthesis and amplitude envelopes. They contain no sampled, recorded, licensed, Apple, Slack, Discord, or WisprFlow audio.

Generated 2026-07-17 by `scripts/generate-recording-sounds.py`; running that script in a clean directory with only a stock Python 3 install (standard library only, no numpy/scipy/pip install step) reproduces these files byte-for-byte (pure procedural synthesis, no external inputs).

Ref: issue #1342.
