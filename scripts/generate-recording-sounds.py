#!/usr/bin/env python3
"""Generate original EnviousWispr recording start/stop earcon candidates (#1342).

Pure procedural synthesis (additive sine waves + amplitude envelopes) using
ONLY the Python standard library — no numpy/scipy, matching every other
committed script under scripts/. No sampled/recorded/licensed audio, no
network access, no external inputs. Running this script reproduces the eight
WAV files bundled at `Sources/EnviousWisprAppKit/Resources/` byte-for-byte.
"""

import math
import random
import wave
from pathlib import Path

SAMPLE_RATE = 44_100
# Writes directly into the bundled resources directory (not beside this
# script) so the documented regeneration command actually updates the
# shipped assets, not an ignored throwaway copy (Codex code-diff review r1).
OUTPUT_DIR = (
    Path(__file__).resolve().parent.parent / "Sources" / "EnviousWisprAppKit" / "Resources"
)


def sample_count(duration_ms: float) -> int:
    return round(SAMPLE_RATE * duration_ms / 1000.0)


def time_axis(duration_ms: float) -> list[float]:
    n = sample_count(duration_ms)
    return [i / SAMPLE_RATE for i in range(n)]


def smoothstep_scalar(x: float) -> float:
    x = min(1.0, max(0.0, x))
    return x * x * (3.0 - 2.0 * x)


def smoothstep(xs: list[float]) -> list[float]:
    return [smoothstep_scalar(x) for x in xs]


def linspace(start: float, stop: float, num: int) -> list[float]:
    if num <= 1:
        return [start]
    step = (stop - start) / (num - 1)
    return [start + step * i for i in range(num)]


def fade_envelope(length: int, attack_ms: float, release_ms: float) -> list[float]:
    attack = max(1, sample_count(attack_ms))
    release = max(1, sample_count(release_ms))
    env = [1.0] * length
    attack_curve = smoothstep(linspace(0.0, 1.0, attack))
    for i in range(min(attack, length)):
        env[i] *= attack_curve[i]
    release_curve = smoothstep(linspace(1.0, 0.0, release))
    start_idx = length - release
    for i in range(release):
        idx = start_idx + i
        if 0 <= idx < length:
            env[idx] *= release_curve[i]
    return env


def oscillator_from_frequency(
    frequency: list[float], phase_offset: float = 0.0
) -> list[float]:
    out = []
    acc = 0.0
    for f in frequency:
        acc += f
        out.append(math.sin(2.0 * math.pi * acc / SAMPLE_RATE + phase_offset))
    return out


def write_wav(filename: str, signal: list[float], peak: float) -> None:
    maximum = max((abs(s) for s in signal), default=0.0)
    if maximum > 0.0:
        scale = peak / maximum
        signal = [s * scale for s in signal]
    pcm = bytearray()
    for s in signal:
        clipped = max(-1.0, min(1.0, s))
        pcm += int(round(clipped * 32767.0)).to_bytes(2, byteorder="little", signed=True)
    with wave.open(str(OUTPUT_DIR / filename), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(SAMPLE_RATE)
        wav.writeframes(bytes(pcm))


def air_glint(start: bool) -> list[float]:
    """A restrained sine glint with a faint, quickly fading upper partial."""
    duration = 150.0 if start else 160.0
    t = time_axis(duration)
    t_last = t[-1]
    progress = [ti / t_last for ti in t]
    if start:
        frequency = [565.0 + 105.0 * smoothstep_scalar(p) for p in progress]
    else:
        frequency = [650.0 - 120.0 * smoothstep_scalar(p) for p in progress]
    fundamental = oscillator_from_frequency(frequency)
    upper_osc = oscillator_from_frequency([f * 2.02 for f in frequency], 0.25)
    upper = [u * math.exp(-ti / 0.050) for u, ti in zip(upper_osc, t)]
    body = [
        (f + 0.13 * u) * math.exp(-ti / 0.185) for f, u, ti in zip(fundamental, upper, t)
    ]
    env = fade_envelope(len(t), 9.0, 42.0)
    return [b * e for b, e in zip(body, env)]


def velvet_tap(start: bool) -> list[float]:
    """A muted resonant tap made from inharmonic, rapidly decaying modes."""
    duration = 110.0 if start else 130.0
    t = time_axis(duration)
    base = 390.0 if start else 326.0
    modes = [
        math.sin(2.0 * math.pi * base * ti + 0.10)
        + 0.34 * math.sin(2.0 * math.pi * base * 1.47 * ti + 0.75)
        + 0.11 * math.sin(2.0 * math.pi * base * 2.31 * ti + 1.60)
        for ti in t
    ]
    decay_const = 0.038 if start else 0.046
    decay = [math.exp(-ti / decay_const) for ti in t]
    env = fade_envelope(len(t), 3.5, 27.0)
    return [m * d * e for m, d, e in zip(modes, decay, env)]


def satin_shift(start: bool) -> list[float]:
    """One soft blip whose energy smoothly shifts between two nearby tones."""
    duration = 200.0 if start else 220.0
    t = time_axis(duration)
    t_last = t[-1]
    progress = smoothstep([ti / t_last for ti in t])
    low = [math.sin(2.0 * math.pi * 472.0 * ti) for ti in t]
    high = [math.sin(2.0 * math.pi * 608.0 * ti + 0.18) for ti in t]
    if start:
        blend = [0.18 + 0.67 * p for p in progress]
    else:
        blend = [0.82 - 0.70 * p for p in progress]
    signal = [(1.0 - b) * lo + 0.82 * b * hi for b, lo, hi in zip(blend, low, high)]
    signal = [s * (0.96 - 0.20 * p) for s, p in zip(signal, progress)]
    env = fade_envelope(len(t), 18.0, 55.0)
    return [s * e for s, e in zip(signal, env)]


def hann_window(window: int) -> list[float]:
    if window == 1:
        return [1.0]
    return [
        0.5 - 0.5 * math.cos(2.0 * math.pi * i / (window - 1)) for i in range(window)
    ]


def lowpass_noise(length: int, seed: int, window: int) -> list[float]:
    """Gaussian noise low-pass filtered by a normalized Hann-windowed moving
    average ('valid' convolution, matching numpy's mode="valid" semantics)."""
    rng = random.Random(seed)
    noise = [rng.gauss(0.0, 1.0) for _ in range(length + window - 1)]
    kernel = hann_window(window)
    kernel_sum = sum(kernel) or 1.0
    kernel = [k / kernel_sum for k in kernel]
    out = []
    for i in range(length):
        acc = 0.0
        for k in range(window):
            acc += noise[i + k] * kernel[window - 1 - k]
        out.append(acc)
    return out


def cloud_pop(start: bool) -> list[float]:
    """A tiny filtered-air pop anchored by a low, rounded tone."""
    duration = 90.0 if start else 100.0
    t = time_axis(duration)
    base = 285.0 if start else 238.0
    tonal = [
        math.sin(2.0 * math.pi * base * ti + 0.30) * math.exp(-ti / 0.032) for ti in t
    ]
    window = 19 if start else 31
    air = lowpass_noise(len(t), 417 if start else 911, window)
    denom = max((abs(a) for a in air), default=0.0) or 1e-12
    decay_const = 0.014 if start else 0.018
    air = [(a / denom) * math.exp(-ti / decay_const) for a, ti in zip(air, t)]
    weight = 0.22 if start else 0.15
    signal = [0.82 * tn + weight * a for tn, a in zip(tonal, air)]
    env = fade_envelope(len(t), 2.5, 24.0)
    return [s * e for s, e in zip(signal, env)]


def main() -> None:
    pairings = [
        ("airGlint", air_glint, 0.16),
        ("velvetTap", velvet_tap, 0.14),
        ("satinShift", satin_shift, 0.15),
        ("cloudPop", cloud_pop, 0.13),
    ]
    for name, generator, peak in pairings:
        for state in ("start", "stop"):
            signal = generator(state == "start")
            write_wav(f"{name}_{state}.wav", signal, peak)
    print(f"Wrote 8 WAV files to {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
