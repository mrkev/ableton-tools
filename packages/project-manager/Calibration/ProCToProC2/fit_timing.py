"""Joint fit of Pro-C 2 attack/release (ms) to Pro-C timing settings, on program material.

Grid A (auto release off): style × Pro-C attack × Pro-C release.
Grid B (auto release on):  style × Pro-C attack × auto release speed.
Each cell: a coarse search in log ms, then a 3×3 refinement. Manual release starts
around a guess (0.25× to 4×); auto release, whose best ranges from 10 ms to Pro-C 2's
2.5 s maximum, searches the whole range.
Writes timing_map.json.
"""
import itertools, json, sys
import numpy as np
from lab import *

SIG = 'prog8'
BASE1 = {"Threshold": -30.0, "Ratio": 0.6, "Auto Gain": 0}
X = [0.0, 0.25, 0.5, 0.75, 1.0]
RX = [0.0, 0.5, 1.0]
SPEEDS = [0.0, 0.5, 1.0]


def base2(st):
    return {"Style": st, "Threshold": -30.0, "Ratio": 0.6 + (0.02 if st == 1 else 0), "Knee": 24.0,
            "Auto Gain": 0, "Side Chain Mid Enabled": 0, "Range": 60.0}


def fit(ref, st, extra, a0, r0=None):
    def scores(pairs):
        outs = render_all([(C2, SIG, {**base2(st), **extra,
                                      "Attack": c2_attack_x(float(np.clip(a, 0.005, 250))),
                                      "Release": c2_release_x(float(np.clip(r, 10, 2500)))}) for a, r in pairs])
        return [null(ref, o)[0] for o in outs]
    A = np.clip(a0 * np.exp(np.linspace(np.log(0.15), np.log(4), 5)), 0.005, 250)
    R = (np.clip(r0 * np.exp(np.linspace(np.log(0.25), np.log(4), 5)), 10, 2500) if r0
         else np.exp(np.linspace(np.log(10), np.log(2500), 9)))
    pairs = list(itertools.product(A, R)); sc = scores(pairs)
    a, r = pairs[int(np.argmin(sc))]
    pairs = list(itertools.product(np.clip(a * np.exp(np.linspace(-0.4, 0.4, 3)), 0.005, 250),
                                   np.clip(r * np.exp(np.linspace(-0.35, 0.35, 3)), 10, 2500)))
    sc2 = scores(pairs); i = int(np.argmin(sc2))
    return float(pairs[i][0]), float(pairs[i][1]), float(sc2[i])


out = {'x': X, 'rx': RX, 'speeds': SPEEDS, 'manual': {}, 'auto': {}}
for st in (0, 1, 2):
    grid = []
    for ax in X:
        row = []
        for rx in RX:
            ref = render(C1, SIG, {**BASE1, "Characteristic": st, "Attack": ax, "Release": rx})
            a, r, s = fit(ref, st, {"Auto Release": 0}, c1_attack_ms(ax) * 0.5, c1_release_ms(rx) * 0.8)
            row.append([a, r, s])
            print(f'manual style {st} attack {ax} release {rx}: {a:.3g} ms / {r:.4g} ms  {s:.1f} dB', flush=True)
        grid.append(row)
    out['manual'][str(st)] = grid
    grid = []
    for ax in X:
        row = []
        for sp in SPEEDS:
            ref = render(C1, SIG, {**BASE1, "Characteristic": st, "Attack": ax, "Auto Release": 1,
                                   "Auto Release Speed": sp})
            a, r, s = fit(ref, st, {"Auto Release": 1}, c1_attack_ms(ax) * 0.5)
            row.append([a, r, s])
            print(f'auto style {st} attack {ax} speed {sp}: {a:.3g} ms / {r:.4g} ms  {s:.1f} dB', flush=True)
        grid.append(row)
    out['auto'][str(st)] = grid
    json.dump(out, open(f'{HERE}/timing_map.json', 'w'))
