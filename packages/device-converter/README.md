# Ableton Device Converter

A native macOS (SwiftUI) tool for converting plugin **devices** inside an
Ableton Live Set (`.als`) from one plugin format to another, so a set that
references a plugin your Live can't load will open again:

- **VST2 → VST3** (GUI and headless CLI, keeps the plugin's settings) — for VST2
  plugins that only exist as Intel builds while Live runs natively on Apple
  Silicon.
- **VST2/VST3 → Audio Unit** (GUI, per device, structural swap only: the AU loads
  at its default settings).

Open a folder of projects, a project folder or a single `.als`: File › Open works
out which from what you pick. Folders get a sidebar of projects and sets, each saying
whether it will open in a native (Apple Silicon) Live:

- **Opens natively** — every plugin, in any format, has an arm64 build.
- **Opens after converting** — needs Intel-only VST2 devices replaced by native VST3s.
- **Re-save, then convert** — the same, but saved by Live 9. (A Live 9 set that needs
  no conversion just opens; Live upgrades it.)
- **Stuck on plugins** — uses a plugin with no native build Live can use. The summary
  ranks these plugins by how many sets each holds back.
- **Converted** — a current `<name>-vst3.als` beside the set opens natively.

Statuses come from a fast byte scan of each set, cached by file date and size; File ›
Rescan picks up changes.

A set opens in two columns:

- **Left** — the VST2/VST3 devices in the file, with their tracks. Untick "Only
  convertible" to see every device (tracks + racks, as a tree).
- **Right** — a "slot" per VST2/VST3 device. By default each slot keeps the
  original; "Change" replaces it with its VST3 or an installed Audio Unit.
  "Convert VST2 to VST3" queues every VST2 device that has a usable VST3.

Then **Save As…** writes a *new* `.als` (never touches the original) with only
the chosen devices replaced — everything else keeps its values, though unchanged
XML isn't guaranteed byte-identical (empty-element spacing, for example).

## VST2 → VST3 migration

```sh
swift run DeviceConverter --vst3 "/path/to/Set.als" [--out out.als] [--dry-run] [--verbose] [--force]
```

Writes `<Set>-vst3.als` next to the original (never overwrites it) and prints
a per-device report. For every VST2 device with an installed VST3 counterpart
that loads natively:

1. **Find the VST3.** Steinberg's VST2-compatible class id — `"VST"` + the
   VST2 unique id + the first 9 chars of the lowercased name (e.g. Serum
   `XfsX` → `VSTXfsXserum`). A VST3 that only shares the name doesn't count:
   Melda's report success loading a VST2 chunk but come up with other values.
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
   after loading (0 ⇒ init patch or rejected state). A non-automated slot whose
   value differs from what Live last saved fails the device, which stays VST2.

Sets saved by Live < 10 are refused unless `--force` (Live 9 predates VST3,
and stores arrangement automation inline) — re-save them in Live 11 first.

Limits: only chunk (`FBCh`) presets — Live's `FxCk` program dumps (e.g. Xfer
OTT / DimensionExpander) aren't converted yet. Intel-only VST3s are skipped
(the CLI runs native, like Live). Verified against Serum: state loads, ids are
index-compatible.

## Batch conversion

"Convert Sets to VST3…" in a library or project summary, or from the command line:

```sh
swift run DeviceConverter --batch <folder> (--out-dir <dir> | --beside-originals) \\
  [--include-partial] [--include-native] [--dry-run]
```

By default this converts only sets that need it to open. `--include-partial` adds sets
stuck on other plugins, and `--include-native` adds sets that already open but could
move their VST2 devices to VST3. There's no default destination. `--out-dir` writes under `<dir>/<project folder>/`
and leaves project folders alone; `--beside-originals` writes into each project
folder, where the library marks the set converted. Originals are only read, existing
outputs are skipped (so an interrupted run can be run again), and each output is
re-read before it counts as done. A set with choices queued in the GUI converts the
way it was set up.

The GUI runs batches in a child process (`--batch-worker`). Hosting plugins in the
app itself crawled with its window hidden behind another app (minutes per device,
against about a second from a windowless process). The worker avoids that, Cancel can
stop it immediately, and if a plugin crashes, that set is marked failed and a new
worker continues. Save As for a single set still hosts plugins in the app.

## AU conversion status: Phase 1 (structural swap)

- ✅ Parse `.als` (gzip + `XMLDocument`), extract devices, decode plugin
  identity (VST2 `Category`, VST3 `DeviceType`, AU `ComponentType` FourCC).
- ✅ Discover installed Audio Units (`AVAudioUnitComponentManager`) — this is
  where the real component codes come from (including the manufacturer code a
  VST3-only set can't provide).
- ✅ Auto-suggest an AU by name, per device.
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
swift run DeviceConverter [path]   # launches the app, optionally opening a
                                   # library, project folder or set

# headless pipeline check (no GUI):
swift run DeviceConverter --selftest "/path/to/Set.als"

# headless library check: discovers a folder, prints status counts, and
# compares the fast scanner against the DOM extractor for every set:
swift run DeviceConverter --selftest-library "/path/to/Projects"
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
| `AppModel.swift` | what's open, scanning, statuses, summaries; shared plugin catalogs |
| `ConverterModel.swift` | one open set: its DOM, slots, auto-suggest, save |
| `Library.swift` | folder discovery and the `SetStatus` rule |
| `LiveSetScan.swift` | fast scan of a set's plugins, and its on-disk cache |
| `PluginInventory.swift` | what's installed in each format, and which builds are native |
| `Views.swift` | the two-column device view for one set |
| `LibraryViews.swift` | root view, sidebar and summary pane |
| `App.swift` | AppKit bootstrap + menu |
