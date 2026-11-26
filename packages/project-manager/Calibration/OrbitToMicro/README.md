# AMBEO Orbit → dearVR MICRO calibration

How `OrbitGainTable.swift` was measured, and how to measure it again.

- `aurender.swift` hosts one AU offline at 48 kHz: it loads a state plist, applies
  `param_x=value` overrides to the JUCE state, pre-rolls 2 s (both plugins smooth
  their parameters from defaults), renders a file through it, and writes the result.
  Built for x86_64, since Orbit is Intel only; it runs under Rosetta.
- `render_grid.sh` renders an impulse through both plugins over azimuth (15° steps) ×
  elevation (30° steps) × width and Clarity (0, 25, 50, 75, 100), plus reflection
  settings. About 8,500 renders, fifteen minutes.
- `gen_table.py` compares each pair's loudness (pink noise through the ITU-R BS.1770
  K-weighting) and writes the Swift table.

Checks made with it (Nov 2026):

- Rendering the same vocal and settings as bounces from Live 10 (Orbit) and Live 11
  (MICRO) nulls to the 16-bit noise floor (−45 to −54 dB), at 0.0 dB gain.
- Both plugins are linear: impulse responses predict direct renders exactly.
- MICRO with its AMBEO Orbit HRTF never nulls against Orbit. After matching level,
  the residual is −13 to −20 dB straight ahead, behind and to the sides, but only −3
  to −7 dB on the diagonals. No Focus value matches Clarity; Focus 100 is closest.
- The makeup gain runs from 2.0 to 7.1 dB. Reflections add 0.05 to 0.9 dB depending
  on their level. Width and Clarity need the 25-point steps: with only 0/50/100,
  some converted devices were off by up to 1.6 dB.
- Converting the whole library (234 Orbit devices) and rendering each Orbit and its
  MICRO + Utility with pink noise: MICRO alone is 2.5 to 6.9 dB quieter; with the
  Utility, the median difference is +0.1 dB, 96% are within 0.5 dB, and the worst is
  +0.8 dB. Other material lands a little differently (a vocal: −0.7 dB), since the
  table is calibrated on pink noise.
