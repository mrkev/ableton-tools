# Plugin Lab

Offline tools for studying audio plugins: host one, look inside it, render audio
through it, and compare renders. Used to work out how to carry a device's settings
to a replacement plugin (AMBEO Orbit → dearVR MICRO, FabFilter Pro-C → Pro-C 2) and
to check the result sounds the same.

Standalone SwiftPM package plus Python scripts (numpy only). Not part of the pnpm
workspace.

## auhost

Hosts one Audio Unit offline at 48 kHz.

```sh
swift build -c release --arch x86_64     # x86_64 so Intel-only AUs load (under Rosetta)
AUHOST=.build/x86_64-apple-macosx/release/auhost

$AUHOST params aumf:FPrC:FabF                        # parameters, ranges, current values
$AUHOST params state.plist Threshold=-24             # after loading a state, with an override
$AUHOST save   state.plist out.plist Ratio=0.7       # write the resulting state
$AUHOST render state.plist in.wav out.wav Attack=0.2 # render a file through it
```

- A plugin is named by `type:subtype:manufacturer` (four-char codes or numbers) or by
  a state plist: an AU ClassInfo dictionary, as `fullState` returns and as Live stores
  in an `AuPreset` buffer.
- `Name=value` sets a parameter by display name, in the parameter's own units, after
  the state loads.
- `render` pre-rolls 1 s of silence (override with `PREROLL=<seconds>`), since plugins
  smooth parameters from their defaults, and compensates the plugin's reported latency.
  Output is 32-bit float, the same length as the input.
- An x86_64 build hosts universal plugins too, so both sides of a comparison can run in
  the same build. For native-only plugins, build without `--arch`.

## scripts/

- `signals.py <dir>`: test signals — pink noise, an impulse, 1 kHz level steps (a
  compressor's static curve), and tone bursts (attack and release).
- `compare.py a.wav b.wav ...`: each file against the first — K-weighted loudness
  difference, and the null residual before and after best lag and gain.
- `wav.py`: read and write WAVs as numpy arrays.
