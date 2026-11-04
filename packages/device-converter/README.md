# Ableton Device Converter

A native macOS (SwiftUI) tool for converting plugin **devices** inside an
Ableton Live Set (`.als`) from one plugin format to another, so a set that
references a plugin your Live can't load will open again:

- **VST2 → VST3** (headless CLI, state-preserving) — for VST2 plugins that only
  exist as Intel builds while Live runs natively on Apple Silicon.
- **VST2/VST3 → Audio Unit** (GUI, structural swap only).

Two columns:

- **Left** — every device in the file (tracks + racks, as a tree).
- **Right** — a "slot" per device. By default each slot keeps the original
  device; click it to replace that device with an installed Audio Unit.

Then **Save As…** writes a *new* `.als` (never touches the original) with only
the chosen devices replaced — every other byte round-trips untouched.

## VST2 → VST3 migration

```sh
swift run DeviceConverter --vst3 "/path/to/Set.als" [--out out.als] [--dry-run] [--verbose] [--force]
```

Writes `<Set>-vst3.als` next to the original (never overwrites it) and prints
a per-device report. For every VST2 device with an installed VST3 counterpart
that loads natively:

1. **Find the VST3.** Steinberg's VST2-compatible class id — `"VST"` + the
   VST2 unique id + the first 9 chars of the lowercased name (e.g. Serum
   `XfsX` → `VSTXfsXserum`) — then an exact name match.
2. **Carry the state.** The VST2 chunk (`VstPreset/Buffer`) is wrapped as
   `VstW` header + `CcnK`/`FBCh` bank, which is what VST3 builds that replace
   their VST2 accept. The converter *hosts the VST3 offline* (`CVst3Host`, a
   hand-rolled minimal VST3 host), loads that blob, and stores the state the
   plugin re-emits as `ProcessorState` / `ControllerState`.
3. **Re-point parameter slots.** Configured `PluginFloatParameter`s (what
   automation / macros target) map VST2 index → VST3 ParamID, matched by id +
   title, then title (ignoring case/spacing), then index when the plugin's VST3
   ids are its VST2 indices. Unmatched slots are unbound rather than mis-bound.
4. **Sanity checks.** Counts parameters that moved off the plugin's defaults
   after loading (0 ⇒ init patch or rejected state) and compares non-automated
   slots' values with what Live last saved.

Sets saved by Live < 10 are refused unless `--force` (Live 9 predates VST3,
and stores arrangement automation inline) — re-save them in Live 11 first.

Limits: only chunk (`FBCh`) presets — Live's `FxCk` program dumps (e.g. Xfer
OTT / DimensionExpander) aren't converted yet. Intel-only VST3s are skipped
(the CLI runs native, like Live). Verified against Serum: state loads, ids are
index-compatible.

## AU conversion status: Phase 1 (structural swap)

- ✅ Parse `.als` (gzip + `XMLDocument`), extract devices, decode plugin
  identity (VST2 `Category`, VST3 `DeviceType`, AU `ComponentType` FourCC).
- ✅ Discover installed Audio Units (`AVAudioUnitComponentManager`) — this is
  where the real component codes come from (including the manufacturer code a
  VST3-only set can't provide).
- ✅ Auto-suggest an AU by name; "Auto-convert plugins" matches all at once.
- ✅ Surgical save: replace only the chosen device subtrees.
- ⚠️ **Structural swap only** — the AU loads at **default settings**. The
  plugin's saved state can't be translated between formats from the file (see
  the repo `TODO.md` discussion). Automatable-parameter bridging is Phase 2.
- ⚠️ **AU block layout is provisional.** The exact `<AuPluginDevice>` structure
  Ableton expects is still being validated against Live 11 —
  `DeviceBuilder.swift` is the thing to tweak as real conversions are tested.

## Phase 2 (planned): parameter bridge

Load the source VST3 (via a JUCE plugin-host helper — VST3 hosting isn't native
to macOS), apply its state, read parameter values, and write them into the AU
by **name** (indices/counts differ between formats). Preserves most settings for
parameter-driven plugins; can't recover state a plugin keeps outside its
exposed parameters.

## Build & run

```sh
cd packages/device-converter
swift build
swift run DeviceConverter          # launches the app

# headless pipeline check (no GUI):
swift run DeviceConverter --selftest "/path/to/Set.als"
```

Requires the macOS toolchain (Xcode). Not part of the pnpm workspace — it's a
standalone SwiftPM package that happens to live under `packages/`.

## Layout

| File | Role |
|------|------|
| `CGzip/` | C shim over system zlib for gzip (de)compression |
| `Gzip.swift` | Swift wrapper over the shim |
| `AlsDocument.swift` | load / serialize / save; `XMLElement` helpers |
| `DeviceExtractor.swift` | walk the DOM, decode format/identity/category |
| `Device.swift` | one device, backed by its live `XMLElement` |
| `AudioUnitCatalog.swift` | installed-AU discovery + FourCC codecs |
| `DeviceBuilder.swift` | build the replacement `<AuPluginDevice>` / VST3 `<PluginDevice>` |
| `CVst3Host/` | minimal offline VST3 host in C (load, set/get state, params) |
| `Vst3Host.swift` | installed-VST3 discovery, compatible UIDs, plugin instances |
| `Vst2State.swift` | read VST2 presets; wrap them as VST3-compatible state |
| `Vst3Migration.swift` | pick target, load state, map parameter slots |
| `Vst3Cli.swift` | `--vst3` headless migration |
| `ConverterModel.swift` | app state: slots, auto-suggest, save |
| `Views.swift` | two-column SwiftUI UI |
| `App.swift` | AppKit bootstrap + menu |
