#!/usr/bin/env python3
"""Generate original EnviousWispr recording start/stop earcon candidates (#1342).

Pure procedural synthesis (additive sine waves + amplitude envelopes). No
sampled/recorded/licensed audio, no network access, no external inputs.
Running this script reproduces the eight WAV files bundled at
`Sources/EnviousWisprAppKit/Resources/` byte-for-byte.
"""

from pathlib import Path
import wave

import numpy as np


SAMPLE_RATE = 44_100
# Writes directly into the bundled resources directory (not beside this
# script) so the documented regeneration command actually updates the
# shipped assets, not an ignored throwaway copy (Codex code-diff review r1).
OUTPUT_DIR = (
    Path(__file__).resolve().parent.parent / "Sources" / "EnviousWisprAppKit" / "Resources"
)


def sample_count(duration_ms: float) -> int:
    return round(SAMPLE_RATE * duration_ms / 1000.0)


def time_axis(duration_ms: float) -> np.ndarray:
    return np.arange(sample_count(duration_ms), dtype=np.float64) / SAMPLE_RATE


def smoothstep(x: np.ndarray) -> np.ndarray:
    x = np.clip(x, 0.0, 1.0)
    return x * x * (3.0 - 2.0 * x)


def fade_envelope(length: int, attack_ms: float, release_ms: float) -> np.ndarray:
    attack = max(1, sample_count(attack_ms))
    release = max(1, sample_count(release_ms))
    env = np.ones(length, dtype=np.float64)
    env[:attack] *= smoothstep(np.linspace(0.0, 1.0, attack, endpoint=True))
    env[-release:] *= smoothstep(np.linspace(1.0, 0.0, release, endpoint=True))
    return env


def oscillator_from_frequency(frequency: np.ndarray, phase_offset: float = 0.0) -> np.ndarray:
    phase = 2.0 * np.pi * np.cumsum(frequency) / SAMPLE_RATE + phase_offset
    return np.sin(phase)


def write_wav(filename: str, signal: np.ndarray, peak: float) -> None:
    signal = np.asarray(signal, dtype=np.float64)
    maximum = np.max(np.abs(signal))
    if maximum > 0.0:
        signal = signal * (peak / maximum)
    pcm = np.round(np.clip(signal, -1.0, 1.0) * 32767.0).astype("<i2")
    with wave.open(str(OUTPUT_DIR / filename), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(SAMPLE_RATE)
        wav.writeframes(pcm.tobytes())


def air_glint(start: bool) -> np.ndarray:
    """A restrained sine glint with a faint, quickly fading upper partial."""
    duration = 150.0 if start else 160.0
    t = time_axis(duration)
    progress = t / t[-1]
    if start:
        frequency = 565.0 + 105.0 * smoothstep(progress)
    else:
        frequency = 650.0 - 120.0 * smoothstep(progress)
    fundamental = oscillator_from_frequency(frequency)
    upper = oscillator_from_frequency(frequency * 2.02, 0.25) * np.exp(-t / 0.050)
    body = (fundamental + 0.13 * upper) * np.exp(-t / 0.185)
    return body * fade_envelope(len(t), 9.0, 42.0)


def velvet_tap(start: bool) -> np.ndarray:
    """A muted resonant tap made from inharmonic, rapidly decaying modes."""
    duration = 110.0 if start else 130.0
    t = time_axis(duration)
    base = 390.0 if start else 326.0
    modes = (
        np.sin(2.0 * np.pi * base * t + 0.10)
        + 0.34 * np.sin(2.0 * np.pi * base * 1.47 * t + 0.75)
        + 0.11 * np.sin(2.0 * np.pi * base * 2.31 * t + 1.60)
    )
    decay = np.exp(-t / (0.038 if start else 0.046))
    return modes * decay * fade_envelope(len(t), 3.5, 27.0)


def satin_shift(start: bool) -> np.ndarray:
    """One soft blip whose energy smoothly shifts between two nearby tones."""
    duration = 200.0 if start else 220.0
    t = time_axis(duration)
    progress = smoothstep(t / t[-1])
    low = np.sin(2.0 * np.pi * 472.0 * t)
    high = np.sin(2.0 * np.pi * 608.0 * t + 0.18)
    if start:
        blend = 0.18 + 0.67 * progress
    else:
        blend = 0.82 - 0.70 * progress
    signal = (1.0 - blend) * low + 0.82 * blend * high
    signal *= 0.96 - 0.20 * progress
    return signal * fade_envelope(len(t), 18.0, 55.0)


def lowpass_noise(length: int, seed: int, window: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    noise = rng.standard_normal(length + window - 1)
    kernel = np.hanning(window)
    kernel /= kernel.sum()
    return np.convolve(noise, kernel, mode="valid")


def cloud_pop(start: bool) -> np.ndarray:
    """A tiny filtered-air pop anchored by a low, rounded tone."""
    duration = 90.0 if start else 100.0
    t = time_axis(duration)
    base = 285.0 if start else 238.0
    tonal = np.sin(2.0 * np.pi * base * t + 0.30) * np.exp(-t / 0.032)
    window = 19 if start else 31
    air = lowpass_noise(len(t), 417 if start else 911, window)
    air /= max(np.max(np.abs(air)), 1e-12)
    air *= np.exp(-t / (0.014 if start else 0.018))
    signal = 0.82 * tonal + (0.22 if start else 0.15) * air
    return signal * fade_envelope(len(t), 2.5, 24.0)


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
