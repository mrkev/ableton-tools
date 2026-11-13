#!/usr/bin/env python3
"""Compare renders: loudness and how well they null.

    compare.py a.wav b.wav [more.wav ...]   # each file against the first

Prints, for each file against the first: the loudness difference (ITU-R BS.1770
K-weighted RMS, no gating), the lag and least-squares gain that best align it,
and the residual left after that alignment (dB relative to the first file). A
residual around -40 dB or lower means they're effectively the same signal; the
16-bit noise floor sits near -50 dB for program material.
"""
import sys
import numpy as np
from wav import read

SR = 48000


def k_weight_power(n, sr=SR):
    """|H|^2 of the BS.1770 K-weighting filter on an rfft grid of n samples."""
    z = np.exp(-2j * np.pi * np.fft.rfftfreq(n, 1 / sr) / sr)
    def biquad(b, a): return (b[0] + b[1] * z + b[2] * z * z) / (a[0] + a[1] * z + a[2] * z * z)
    h = biquad([1.53512485958697, -2.69169618940638, 1.19839281085285], [1, -1.69065929318241, 0.73248077342364]) \
        * biquad([1, -2, 1], [1, -1.99004745483398, 0.99007225036621])
    return np.abs(h) ** 2


def db(x):
    return 20 * np.log10(max(float(x), 1e-12))


def rms(x):
    return np.sqrt(np.mean(np.square(x)))


def loudness(x):
    """K-weighted power summed over channels, in dB (BS.1770 without gating)."""
    X = np.abs(np.fft.rfft(x, axis=0)) ** 2
    power = (X * k_weight_power(len(x))[:, None]).sum() * 2 / len(x) ** 2
    return 10 * np.log10(max(power, 1e-24))


def align(a, b, maxlag=4800):
    """Lag (samples b is late by), LS gain (dB) and residual (dB re a) of b against a."""
    n = min(len(a), len(b))
    x, y = a[:n].sum(1), b[:n].sum(1)
    size = 1 << int(np.ceil(np.log2(2 * n)))
    c = np.fft.irfft(np.fft.rfft(y, size) * np.conj(np.fft.rfft(x, size)), size)
    lags = np.r_[0:maxlag, size - maxlag:size]
    best = lags[np.argmax(c[lags])]
    lag = int(best if best < size // 2 else best - size)
    bs = np.roll(b[:n], -lag, 0)
    lo, hi = max(0, -lag), n - max(0, lag)
    g = np.sum(a[lo:hi] * bs[lo:hi]) / max(np.sum(bs[lo:hi] ** 2), 1e-20)
    return lag, db(g), db(rms(a[lo:hi] - g * bs[lo:hi])) - db(rms(a[lo:hi]))


def main(paths):
    ref = read(paths[0])
    print(f"{paths[0]}: loudness {loudness(ref):.2f} dB")
    for p in paths[1:]:
        b = read(p)
        lag, g, res = align(ref, b)
        raw = db(rms(ref[:min(len(ref), len(b))] - b[:min(len(ref), len(b))])) - db(rms(ref))
        print(f"{p}: loudness {loudness(b) - loudness(ref):+.2f} dB · raw null {raw:.1f} dB"
              f" · aligned lag {lag} gain {g:+.2f} dB null {res:.1f} dB")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    main(sys.argv[1:])
