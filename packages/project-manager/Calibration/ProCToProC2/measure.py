#!/usr/bin/env python3
"""Measure what gen_tables.py needs besides the timing fit.

    PROC_LAB=lab measure.py

Writes into $PROC_LAB:
  c1_autogain_table.json   Pro-C's Auto Gain makeup by style, knee, threshold and ratio:
                           a -60 dBFS tone sits below every threshold, so the level
                           difference with Auto Gain on and off is the makeup alone.
  c1_autogain_attack.json  the fraction of that makeup left at each attack setting
                           (the same at every threshold and ratio tried)
  link_map.json            Pro-C expert side-chain mix (left -m, right +m) → the Pro-C 2
                           stereo link that nulls best, on drums
  FC2p_release.txt         Pro-C 2's release scale, for gen_tables.py
"""
import itertools, json
import numpy as np
from lab import *

SR = 48000
sys.path.insert(0, os.path.join(LAB, 'scripts'))
from signals import drums  # noqa: E402
from wav import write  # noqa: E402

t = np.arange(SR) / SR
quiet = 0.001 * np.sin(2 * np.pi * 1000 * t)
write(f'{HERE}/sig/quiet.wav', np.stack([quiet, quiet], 1))
write(f'{HERE}/sig/drums.wav', drums())


def level(path):
    return db(rms(read(path)[SR // 2:]))


# Auto Gain makeup table.
thresholds = [float(x) for x in np.arange(-36, 0.1, 4.5)]
ratios = [round(float(x), 2) for x in np.arange(0, 1.01, 0.1)]
table = {}
for style, knee in itertools.product((0, 1, 2), (0, 1)):
    combos = list(itertools.product(thresholds, ratios))
    outs = render_all([(C1, 'quiet', {"Characteristic": style, "Knee Shape": knee, "Threshold": th, "Ratio": r,
                                      "Auto Gain": g}) for th, r in combos for g in (0, 1)])
    makeup = [level(outs[2 * i + 1]) - level(outs[2 * i]) for i in range(len(combos))]
    table[f'{style}{knee}'] = [[round(makeup[i * len(ratios) + j], 3) for j in range(len(ratios))]
                               for i in range(len(thresholds))]
json.dump({'thresholds': thresholds, 'ratios': ratios, 'makeup': table}, open(f'{HERE}/c1_autogain_table.json', 'w'))

# Its dependence on attack.
attacks = [round(float(a), 2) for a in np.arange(0, 1.001, 0.05)]
factors = []
for th, r in ((-36, 0.8), (-18, 0.5), (-27, 0.3), (-9, 1.0)):
    outs = render_all([(C1, 'quiet', {"Characteristic": 0, "Threshold": th, "Ratio": r, "Attack": a, "Auto Gain": g})
                       for a in attacks for g in (1, 0)])
    m = [level(outs[2 * i]) - level(outs[2 * i + 1]) for i in range(len(attacks))]
    factors.append([x / m[0] for x in m])
print('makeup factor spread across threshold/ratio:', float(np.ptp(factors, axis=0).max()))
json.dump({'attack': attacks, 'factor': [round(float(x), 4) for x in np.mean(factors, axis=0)]},
          open(f'{HERE}/c1_autogain_attack.json', 'w'))

# Expert side-chain mix → stereo link.
b1 = {"Characteristic": 0, "Threshold": -30, "Ratio": 0.6, "Attack": 0.3, "Release": 0.3, "Auto Gain": 0,
      "Expert Mode": 1}
b2 = {"Style": 0, "Threshold": -30, "Ratio": 0.6, "Knee": 24, "Attack": c2_attack_x(2.22),
      "Release": c2_release_x(119.4), "Auto Gain": 0, "Side Chain Mid Enabled": 0, "Side Chain Expert Mode": 1}
links = np.arange(0, 101, 5)
rows = []
for m in np.round(np.arange(0, 1.01, 0.1), 2):
    ref = render(C1, 'drums', {**b1, "Left Side Chain Mix": -float(m), "Right Side Chain Mix": float(m)})
    scores = [null(ref, o)[0] for o in render_all([(C2, 'drums', {**b2, "Stereo Link": float(l) / 200}) for l in links])]
    i = int(np.argmin(scores))
    rows.append((float(m), float(links[i]), scores[i]))
    print(f'mix ±{m}: link {links[i]}%  null {scores[i]:.1f} dB')
json.dump(rows, open(f'{HERE}/link_map.json', 'w'))
