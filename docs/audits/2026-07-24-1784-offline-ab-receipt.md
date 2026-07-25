# #1784 §11.3 offline A/B receipt — 2026-07-24

Arm A = bare MLModelConfiguration() (current shipped). Arm B = .cpuAndNeuralEngine + allowLowPrecisionAccumulationOnGPU (this change).
6 fixtures x 2 replay modes x 3 repetitions per arm = 72 replays. Fresh VadManager + recorder + SilenceDetector per replay; model loaded per replay.
Fixtures: committed scripts/freeze-suite/clips/*.wav (16 kHz mono Int16, verified via afinfo) + quiet-onset synthesized from normal-speech.wav.

RESULT: 12/12 comparisons — stableA=true stableB=true agree=true. Identical event sequences, segment boundaries, speech-evidence outcomes, and first auto-stop chunk indexes.

normal-speech [full-feed] stableA=true stableB=true agree=true
    A: events=VadStreamEvent(kind: FluidAudio.VadStreamEvent.Kind.speechStart, sampleIndex: 0, time: nil),-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,VadStreamEvent(kind: FluidAudio.VadStreamEvent.Kind.speechEnd, sampleIndex: 94208, time: nil),-,-,-,-,-,- segments=0-94208 speech=true autoStop=30
    B: events=VadStreamEvent(kind: FluidAudio.VadStreamEvent.Kind.speechStart, sampleIndex: 0, time: nil),-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,VadStreamEvent(kind: FluidAudio.VadStreamEvent.Kind.speechEnd, sampleIndex: 94208, time: nil),-,-,-,-,-,- segments=0-94208 speech=true autoStop=30
normal-speech [auto-stop] stableA=true stableB=true agree=true
    A: events=VadStreamEvent(kind: FluidAudio.VadStreamEvent.Kind.speechStart, sampleIndex: 0, time: nil),-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,VadStreamEvent(kind: FluidAudio.VadStreamEvent.Kind.speechEnd, sampleIndex: 94208, time: nil),- segments=0-94208 speech=true autoStop=30
    B: events=VadStreamEvent(kind: FluidAudio.VadStreamEvent.Kind.speechStart, sampleIndex: 0, time: nil),-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,VadStreamEvent(kind: FluidAudio.VadStreamEvent.Kind.speechEnd, sampleIndex: 94208, time: nil),- segments=0-94208 speech=true autoStop=30
mumbled-speech [full-feed] stableA=true stableB=true agree=true
    A: events=VadStreamEvent(kind: FluidAudio.VadStreamEvent.Kind.speechStart, sampleIndex: 0, time: nil),-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,VadStreamEvent(kind: FluidAudio.VadStreamEvent.Kind.speechEnd, sampleIndex: 180224, time: nil),-,-,-,-,- segments=0-180224 speech=true autoStop=52
    B: events=VadStreamEvent(kind: FluidAudio.VadStreamEvent.Kind.speechStart, sampleIndex: 0, time: nil),-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,VadStreamEvent(kind: FluidAudio.VadStreamEvent.Kind.speechEnd, sampleIndex: 180224, time: nil),-,-,-,-,- segments=0-180224 speech=true autoStop=52
mumbled-speech [auto-stop] stableA=true stableB=true agree=true
    A: events=VadStreamEvent(kind: FluidAudio.VadStreamEvent.Kind.speechStart, sampleIndex: 0, time: nil),-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,VadStreamEvent(kind: FluidAudio.VadStreamEvent.Kind.speechEnd, sampleIndex: 180224, time: nil),-,- segments=0-180224 speech=true autoStop=52
    B: events=VadStreamEvent(kind: FluidAudio.VadStreamEvent.Kind.speechStart, sampleIndex: 0, time: nil),-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,VadStreamEvent(kind: FluidAudio.VadStreamEvent.Kind.speechEnd, sampleIndex: 180224, time: nil),-,- segments=0-180224 speech=true autoStop=52
quiet-onset [full-feed] stableA=true stableB=true agree=true
    A: events=VadStreamEvent(kind: FluidAudio.VadStreamEvent.Kind.speechStart, sampleIndex: 0, time: nil),-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,VadStreamEvent(kind: FluidAudio.VadStreamEvent.Kind.speechEnd, sampleIndex: 94208, time: nil),-,-,-,-,-,- segments=0-94208 speech=true autoStop=30
    B: events=VadStreamEvent(kind: FluidAudio.VadStreamEvent.Kind.speechStart, sampleIndex: 0, time: nil),-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,VadStreamEvent(kind: FluidAudio.VadStreamEvent.Kind.speechEnd, sampleIndex: 94208, time: nil),-,-,-,-,-,- segments=0-94208 speech=true autoStop=30
quiet-onset [auto-stop] stableA=true stableB=true agree=true
    A: events=VadStreamEvent(kind: FluidAudio.VadStreamEvent.Kind.speechStart, sampleIndex: 0, time: nil),-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,VadStreamEvent(kind: FluidAudio.VadStreamEvent.Kind.speechEnd, sampleIndex: 94208, time: nil),- segments=0-94208 speech=true autoStop=30
    B: events=VadStreamEvent(kind: FluidAudio.VadStreamEvent.Kind.speechStart, sampleIndex: 0, time: nil),-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,VadStreamEvent(kind: FluidAudio.VadStreamEvent.Kind.speechEnd, sampleIndex: 94208, time: nil),- segments=0-94208 speech=true autoStop=30
silence [full-feed] stableA=true stableB=true agree=true
    A: events=-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,- segments= speech=false autoStop=none
    B: events=-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,- segments= speech=false autoStop=none
silence [auto-stop] stableA=true stableB=true agree=true
    A: events=-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,- segments= speech=false autoStop=none
    B: events=-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,- segments= speech=false autoStop=none
background-noise [full-feed] stableA=true stableB=true agree=true
    A: events=-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,- segments= speech=false autoStop=none
    B: events=-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,- segments= speech=false autoStop=none
background-noise [auto-stop] stableA=true stableB=true agree=true
    A: events=-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,- segments= speech=false autoStop=none
    B: events=-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,- segments= speech=false autoStop=none
sudden-burst [full-feed] stableA=true stableB=true agree=true
    A: events=-,-,-,-,-,-,- segments= speech=false autoStop=none
    B: events=-,-,-,-,-,-,- segments= speech=false autoStop=none
sudden-burst [auto-stop] stableA=true stableB=true agree=true
    A: events=-,-,-,-,-,-,- segments= speech=false autoStop=none
    B: events=-,-,-,-,-,-,- segments= speech=false autoStop=none
## Honest limitation
The synthesized quiet-onset fixture produced output identical to normal-speech (segments 0-94208, autoStop=30), i.e. the 0.10/0.25/0.50 attenuation of the first six chunks did NOT move the onset decision. That fixture therefore did not discriminate, and this receipt should not be read as covering a genuinely marginal onset. The recipe was executed exactly as specified in the approved plan; it was not retuned after seeing the result.

Harness source preserved at scratchpad/ZZ1784OfflineABHarness.swift.kept; the file is NOT committed (plan Preface zero-blast condition 4).
