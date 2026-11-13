#!/usr/bin/env python3
"""Test signals for plugin measurements, as 48 kHz stereo float WAVs.

    signals.py <dir>

Writes:
  pink.wav     10 s of pink noise at -20 dBFS RMS
  impulse.wav  a unit impulse followed by 2 s of silence
  steps.wav    1 kHz tone in 2 s steps from -60 to 0 dBFS (6 dB apart), for a
               compressor's static curve and its attack/release at each step
  bursts.wav   1 kHz tone alternating -40 / -6 dBFS every 0.5 s, for timing
  drums.wav    8 s of synthetic kick / snare / hat hits at varying levels, with a
               bass tone under them: transients for a compressor to work on
"""
import os
import sys
import numpy as np
from wav import write

SR = 48000


def pink(seconds, level_db=-20, seed=1):
    n = int(seconds * SR)
    rng = np.random.default_rng(seed)
    X = np.fft.rfft(rng.standard_normal((n, 2)), axis=0)
    f = np.fft.rfftfreq(n, 1 / SR)
    X[1:] /= np.sqrt(f[1:])[:, None]
    X[0] = 0
    x = np.fft.irfft(X, n, axis=0)
    return x / np.sqrt(np.mean(x ** 2)) * 10 ** (level_db / 20)


def tone(levels_db, seconds_each, freq=1000):
    seg = int(seconds_each * SR)
    t = np.arange(seg * len(levels_db)) / SR
    amp = np.repeat([10 ** (l / 20) for l in levels_db], seg)
    x = amp * np.sin(2 * np.pi * freq * t)
    return np.stack([x, x], 1)


def drums(seconds=8, bpm=120, seed=2):
    rng = np.random.default_rng(seed)
    n = int(seconds * SR)
    x = np.zeros(n)
    beat = int(60 / bpm * SR)
    t = np.arange(int(0.4 * SR)) / SR
    kick = np.sin(2 * np.pi * (50 * t + 60 * (1 - np.exp(-t * 30)) / 30)) * np.exp(-t * 9)
    snare = rng.standard_normal(len(t)) * np.exp(-t * 18) * 0.6 + np.sin(2 * np.pi * 190 * t) * np.exp(-t * 25) * 0.4
    hat = rng.standard_normal(int(0.05 * SR)) * np.exp(-np.arange(int(0.05 * SR)) / SR * 90) * 0.3
    for i in range(n // beat):
        at = i * beat
        level = 10 ** (rng.uniform(-12, 0) / 20)
        hit = kick if i % 2 == 0 else snare
        x[at:at + len(hit)] += level * hit[:n - at]
        h = at + beat // 2
        if h + len(hat) < n:
            x[h:h + len(hat)] += hat * 10 ** (rng.uniform(-10, 0) / 20)
    x += 0.15 * np.sin(2 * np.pi * 55 * np.arange(n) / SR) * (0.5 + 0.5 * np.sin(2 * np.pi * 0.25 * np.arange(n) / SR))
    x *= 0.5 / np.abs(x).max()
    # A little stereo difference, so linking and mid/side matter.
    return np.stack([x, np.roll(x, 24) * 0.8], 1)


def main(out):
    os.makedirs(out, exist_ok=True)
    write(f"{out}/pink.wav", pink(10))
    imp = np.zeros((2 * SR, 2)); imp[0] = 1
    write(f"{out}/impulse.wav", imp)
    write(f"{out}/steps.wav", tone(list(range(-60, 1, 6)), 2))
    write(f"{out}/bursts.wav", tone([-40, -6] * 6, 0.5))
    write(f"{out}/drums.wav", drums())


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
