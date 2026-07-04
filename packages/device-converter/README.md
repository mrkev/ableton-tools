# Ableton Device Converter

A native macOS (SwiftUI) tool for converting plugin **devices** inside an
Ableton Live Set (`.als`) from one plugin format to another — primarily
**VST2/VST3 → Audio Unit**, so a set that references a plugin format your Live
version can't load will open again.

Two columns:

- **Left** — every device in the file (tracks + racks, as a tree).
- **Right** — a "slot" per device. By default each slot keeps the original
  device; click it to replace that device with an installed Audio Unit.

Then **Save As…** writes a *new* `.als` (never touches the original) with only
the chosen devices replaced — every other byte round-trips untouched.

## Status: Phase 1 (structural swap)

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
| `DeviceBuilder.swift` | build the replacement `<AuPluginDevice>` element |
| `ConverterModel.swift` | app state: slots, auto-suggest, save |
| `Views.swift` | two-column SwiftUI UI |
| `App.swift` | AppKit bootstrap + menu |
