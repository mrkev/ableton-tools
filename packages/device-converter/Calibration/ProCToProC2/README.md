# FabFilter Pro-C → Pro-C 2 calibration

How `ProCTables.swift` and the constants in `ProCToProC2.swift` were measured, and
how to measure them again. Everything renders both plugins offline with
`packages/plugin-lab`'s `auhost`, built x86_64 so Pro-C (Intel only) loads under
Rosetta; Pro-C 2 is universal, so both run in the same build.

```sh
(cd ../../../plugin-lab && swift build -c release --arch x86_64)
export PROC_LAB=lab                 # renders are cached here; delete to start over
python3 measure.py                  # auto gain table, its attack factor, stereo link
# fit_timing.py needs lab/sig/prog8.wav: 8 s of program material. We used 3 s of
# drums (plugin-lab's signals.py), 3 s of a dry vocal and 2 s of a full mix.
python3 fit_timing.py               # ~90 min
python3 gen_tables.py lab ../../Sources/DeviceConverter/ProCTables.swift
python3 e2e.py signal.wav original.als converted.als ...   # check converted sets
```

- `lab.py`: render either plugin with parameter overrides (cached, in parallel), and
  null two renders.
- `measure.py`: Pro-C's Auto Gain makeup and stereo link, see its docstring.
- `fit_timing.py`: for each style and Pro-C attack × release (and attack × auto
  release speed), the Pro-C 2 attack and release that null best on program material.
- `gen_tables.py`: writes the Swift tables.
- `e2e.py`: renders every Pro-C device in an original set and the Pro-C 2 device the
  converter wrote in its place, and checks the converted slots show Pro-C 2's values.

## Findings (Nov 2026)

Scales, from each plugin's own display text (`auhost strings`):

- Same in both: threshold (dB), ratio (identical curve), input/output/dry levels
  (36 dB per unit above -18 dB), pans, side-chain level.
- Pro-C attack 0.5 + 499.5·x⁴ ms; Pro-C 2 0.005 + 250·x³ ms. Pro-C release 50 ms–5 s,
  Pro-C 2 10 ms–2.5 s, on different curves. Pro-C's side-chain filters 5·6000^x Hz.

Behavior, from renders:

- Clean, Classic and Opto are Pro-C 2's first three styles. Pro-C's soft knee matches
  a 24 dB knee within 0.15 dB of static curve; Classic also wants ratio +0.02.
- Equal milliseconds don't match: Pro-C 2 wants roughly half the attack, and release
  maps nonlinearly. Fitted on tone bursts first; those fits didn't transfer to real
  material for Opto, hence the program-material fit.
- Pro-C 2's Auto Gain makeup differs. Pro-C's is a smooth function of threshold and
  ratio per style and knee, times a factor of attack alone (1 up to 0.2, about 0.54 at
  0.5, none from 0.9): with a slow attack Pro-C applies no makeup at all.
- Pro-C's side chain and its filters only act in expert mode; so do Pro-C 2's. The
  expert mixes (left -m, right +m) map to Pro-C 2's stereo link: 100% at 0, 20% at
  ±0.5, 10% at ±1. Pro-C 2's high-pass wants its cutoff half an octave higher at
  30 dB/oct, its low-pass half an octave lower at 36 dB/oct.
- Pro-C's mid/side mode compresses mid and side separately. Pro-C 2's stereo link modes
  only change what its detector hears, so nothing reproduces it (best -19 dB null).

Results on the library's 75 Pro-C devices in 40 sets, converted by the app and
rendered with `e2e.py` (null of Pro-C 2 against the original, on 8 s of program
material / a dry vocal; loudness is BS.1770 K-weighted):

| Devices | Null, median (worst) | Loudness, worst |
|---|---|---|
| Opto with auto release, 20 | -53 (-43) / -57 (-43) dB | 0.06 dB |
| Clean, 14 | -42 (-36) / -43 (-35) dB | 0.14 dB |
| Classic, 31 (26 with a 500 ms attack) | -27 (-21) / -30 (-23) dB | 0.57 dB |
| Mid/side, 10 | -17 (-13) / -14 (-12) dB | 2.2 dB |

Every converted parameter slot showed the value Pro-C 2 actually held, and nothing
outside the converted devices changed.
