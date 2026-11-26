# Ableton Project Manager

A native macOS (SwiftUI) app for looking after a library of Ableton Live projects:
which sets open in a native (Apple Silicon) Live, what plugins and samples they
depend on, and fixing them one set at a time. Fixing converts plugin **devices**
inside a Live Set (`.als`) from one plugin format to another, so a set that
references a plugin your Live can't load will open again:

- **VST2 → VST3** (GUI and headless CLI, keeps the plugin's settings) — for VST2
  plugins that only exist as Intel builds while Live runs natively on Apple
  Silicon.
- **VST2/VST3 → Audio Unit** (GUI, per device, structural swap only: the AU loads
  at its default settings).

Open a folder of projects, a project folder or a single `.als`: File › Open works
out which from what you pick.

### The library

The sidebar lists projects and their sets, each with whether it will open in a
native (Apple Silicon) Live:

- **Opens natively**: every plugin, in any format, has an arm64 build.
- **Opens after converting**: needs Intel-only devices replaced by native VST3s,
  or by a replacement turned on in Settings.
- **Re-save, then convert**: the same, but saved by Live 9. (A Live 9 set that needs
  no conversion just opens; Live upgrades it.)
- **Stuck on plugins**: uses a plugin with no native build Live can use.
- **Converted**: a current fixed copy beside the set opens natively.

A fixed copy (`<name>-vst3.als`, or `<name>-converted.als`) shows under its set rather
than as a set of its own, marked out of date when the set was saved after it. An
orange waveform marks sets with samples that can't be found. The search field
filters by set, project or plugin name.

**All Projects** (or a project) shows status counts, what's holding sets back, and a
table of sets with their Live version, tempo, arrangement length, track count,
missing samples and save date; double-click a row to open its page. **Plugins**
lists every plugin in the library with what it needs (works natively, converts to
its VST3, can be replaced, or won't load), how many sets use it, and in its inspector
which sets those are.

Statuses come from a fast byte scan of each set, cached by file date and size;
File › Rescan picks up changes.

### A set's page

- **Verdict**: whether it opens in the newest installed Live, and why not.
- **Plugins**: one row per plugin, with the tracks using it and what fixing does to
  it. The recommendation is only what it needs to load: an Intel-only VST2 or AU
  becomes its VST3, and a plugin with a replacement turned on in Settings is
  replaced. The ⋯ menu overrides that for this set: leave it, move a native VST2 to
  its VST3, use a replacement that's off by default, or pick an Audio Unit (which
  starts from its default settings).
- **Fix and Save Copy…** saves the fixed set as a new file beside the original,
  which is never changed. Only the chosen devices are replaced; everything else
  keeps its values, though unchanged XML isn't guaranteed byte-identical.
- **Samples**: files the set refers to that aren't where it expects. They're looked
  for where Live would: the recorded path, relative to the project, and Live's Core
  Library, packs and User Library (from Live's `Library.cfg`), including library
  paths written by older Live versions. Older sets keep the absolute path in a Mac
  alias record, which is decoded. Each missing file is either lost or has a file of
  the same name somewhere in the libraries or Places, which Live's File Manager can
  likely relink. Missing freeze files are listed apart.

**Opening a set.** The app finds every installed Live (and whether each is native
or Intel-only, running under Rosetta, where Intel-only plugins still load). A set
opens by default in the oldest installed Live that can open it, so it stays in the
version that saved it rather than being upgraded; Live refuses sets from a newer
major or minor release, so older Lives aren't offered. When a later Live is
installed, the Open button's menu (and the context menus, and File › Open In)
offers it. Open and Show in Finder are in the toolbar and the File menu. Settings
holds the replacements' defaults.

To fix many sets at once, use File › Fix Sets in Bulk… (for what's selected in the
sidebar, the project shown, or the whole library), or select several sets in the
sidebar or a table.

## VST2 → VST3 migration

```sh
swift run ProjectManager --vst3 "/path/to/Set.als" [--out out.als] [--dry-run] [--verbose] [--force]
```

Writes `<Set>-vst3.als` next to the original (never overwrites it) and prints
a per-device report. For every VST2 device with an installed VST3 counterpart
that loads natively, and every Intel-only Audio Unit built around a VST2 whose
VST3 replaces it (see below):

1. **Find the VST3.** Steinberg's VST2-compatible class id — `"VST"` + the
   VST2 unique id + the first 9 chars of the lowercased name (e.g. Serum
   `XfsX` → `VSTXfsXserum`). A VST3 that only shares the name doesn't count:
   Melda's report success loading a VST2 chunk but come up with other values.
2. **Carry the state.** The converter *hosts the VST3 offline* (`CVst3Host`, a
   hand-rolled minimal VST3 host), loads the old settings into it, and stores
   the state the plugin re-emits as `ProcessorState` / `ControllerState`. The
   old settings come in two kinds:
   - **Chunks** (`FBCh`): wrapped as `VstW` header + `CcnK`/`FBCh` bank, which
     is what VST3 builds that replace their VST2 accept.
   - **Parameter dumps**: Live's `FxBk` dump of a VST2 (each program a 28-byte
     name + little-endian floats), or the `CcnK`/`FxCk` program an AU built
     around a VST2 keeps under `vstdata` in its state plist. These only work
     for a VST3 whose own state is its parameter values as little-endian
     floats in parameter order (Xfer's OTT). That's checked against a fresh
     instance first, and every value is read back after loading.
3. **Re-point parameter slots.** Configured `PluginFloatParameter`s (what
   automation / macros target) map VST2 index → VST3 ParamID, matched by id +
   title, then title (ignoring case/spacing), then index when the plugin's VST3
   ids are its VST2 indices. Unmatched slots are unbound rather than mis-bound.
4. **Sanity checks.** Counts parameters that moved off the plugin's defaults
   after loading (0 ⇒ init patch or rejected state). A non-automated slot whose
   value differs from what Live last saved fails the device, which stays VST2.

Sets saved by Live < 10 are refused unless `--force` (Live 9 predates VST3,
and stores arrangement automation inline) — re-save them in Live 11 first.

**Audio Units built around a VST2** (Xfer's) use the VST2's unique id as their
subtype, which is how their VST3 is found. Live wraps AU and VST3 devices in the
same envelope, so only the tag (`AuPluginDevice` → `PluginDevice`), `PluginDesc`
and the slots change; references to the AU's `.aupreset` files are cleared. Only
AUs that aren't native are converted.

Limits: VST3s with any other state format can't take a parameter dump yet, and
an AU keeping a chunk (`FPCh`) isn't converted. Intel-only VST3s are skipped
(the CLI runs native, like Live). Verified against Serum (chunks) and OTT
(parameter dumps, VST2 and AU).

`--probe-vst3 <bundle.vst3> [--state <file>]` is a debugging aid: it lists a
VST3's classes, parameters and own state, and with `--state` loads a file and
shows which parameters moved.

## Batch conversion

File › Fix Sets in Bulk…, "Fix several at once…" on a library or project page, or
from the command line:

```sh
swift run ProjectManager --batch <folder> (--out-dir <dir> | --beside-originals) \\
  [--include-partial] [--include-native] [--substitute-orbit] [--substitute-pro-c] [--dry-run]
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

## Replacements (opt-in)

Some Intel-only plugins have no native build, but a different plugin does the same
job. Replacing them is opt-in, because the result doesn't sound identical: a
checkbox per replacement in Settings (or a plugin's inspector on the Plugins
page), a flag on `--batch` and `--vst3`, or "Replace with …" for one set's plugin. Each lives in
`Substitution.swift` plus its own file; AU devices are rewritten in place
(`AuRetarget`). An AU → AU replacement also works in sets saved before Live 10.

### AMBEO Orbit → dearVR MICRO (`--substitute-orbit`)

AMBEO Orbit is discontinued and Intel only. dearVR MICRO is its successor: the same
controls under the same parameter ids (Clarity became Focus, and there's a new HRTF
choice), and the same JUCE state format, so every setting carries over. It doesn't
sound the same, though, even with its "AMBEO Orbit" HRTF: placement and tone differ,
most at diagonal positions, and MICRO is 2.5 to 7 dB quieter.

Each Orbit becomes MICRO (an AU stays an AU; VST2 and VST3 become VST3) with the AMBEO
Orbit HRTF and Focus 100, the closest match. MICRO re-saves the state itself, and
the result is checked against Orbit's values. A Utility named "MICRO level match"
goes right after it, with the gain that restores Orbit's loudness at that device's
settings, from a measured table (`OrbitGainTable.swift`; see
`Calibration/OrbitToMicro`). Parameter slots keep their automation; Clarity's
slot becomes Focus. If position is automated, the gain fits only the saved
position, and the conversion notes say so.

### FabFilter Pro-C → Pro-C 2 (`--substitute-pro-c`)

Pro-C is Intel only (an AU here). Pro-C 2 has the same three styles (Clean, Classic,
Opto) and most of the same controls, but can't read Pro-C's state, so each setting
is translated (`ProCToProC2.swift`) and set on Pro-C 2's AU by name, then read back.
Where the two differ, the translation was measured by rendering both offline
(`ProCTables.swift`, generated; see `Calibration/ProCToProC2`):

- Soft knee is Pro-C 2's 24 dB knee; Classic needs its ratio 0.02 higher.
- Attack and release use different curves, and equal milliseconds don't behave the
  same, so the closest-sounding times were fitted on program material per style,
  with and without auto release.
- Pro-C 2's Auto Gain makeup differs, so it's off, and Pro-C's own makeup (which
  shrinks for slow attacks) goes into the wet gain.
- Pro-C's expert side-chain mixes are Pro-C 2's stereo link; its side-chain filters
  sit half an octave off Pro-C 2's.

Pro-C 2 has no mid/side processing and its attack stops at 250 ms; devices using
either get a note. Parameter slots point at Pro-C 2's counterparts; automation on
them is dropped, since the ranges differ (none of the library's is automated).

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
cd packages/project-manager
swift build
swift run ProjectManager [path]   # launches the app, optionally opening a
                                   # library, project folder or set

# headless pipeline check (no GUI):
swift run ProjectManager --selftest "/path/to/Set.als"

# headless library check: discovers a folder, prints status counts and missing
# samples (--list-missing lists them), and compares the fast scanner against the
# DOM extractor for every set:
swift run ProjectManager --selftest-library "/path/to/Projects"

# a set page's plan, and with --out the fixed copy it saves (--replace picks
# every available replacement):
swift run ProjectManager --selftest-plan "/path/to/Set.als" [--replace] [--out copy.als]
```

`--select overview|plugins|<path>` opens the app on that page, and `DC_BACKGROUND=1`
keeps it from coming to the front (for scripted screenshots).

### As an app

```sh
./make-app.sh             # → build/Ableton Project Manager.app
./make-app.sh --install   # also copies it to ~/Applications
```

Wraps the release build in a bundle (Info.plist, icon from `App/AppIcon.icns`, drawn
by `App/make-icon.swift`) and signs it ad hoc for this Mac. Open a library, project or
set with "Open With" or by dropping it on the Dock icon; the app is only an alternate
handler for `.als`, so double-clicking a set still opens Live. The command-line modes
work through `Ableton Project Manager.app/Contents/MacOS/ProjectManager`. Inside the bundle,
settings (like the opted-in replacements) are kept under its bundle id,
`dev.ableton-tools.project-manager`, separately from `swift run`'s. (The app was
called Device Converter; on first launch it copies the old settings and scan cache
across.)

Requires the macOS toolchain (Xcode). Not part of the pnpm workspace — it's a
standalone SwiftPM package that happens to live under `packages/`. It stays a package
rather than an Xcode project: open `Package.swift` in Xcode for the debugger and
previews.

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
| `Vst2State.swift` | read VST2 presets and AU-wrapped VST2 programs; wrap them for VST3 |
| `Vst3Migration.swift` | pick target, load state, map parameter slots |
| `Vst3Cli.swift` | `--vst3` headless migration |
| `ProbeCli.swift` | `--probe-vst3`: how a VST3 stores its state |
| `OrbitToMicro.swift` | AMBEO Orbit → dearVR MICRO: identity, settings, AU hosting, device rewrite |
| `OrbitGainTable.swift` | measured makeup gain for MICRO, by Orbit's settings |
| `Substitution.swift` | opt-in replacements by a different plugin; shared AU rewrite and slot re-pointing |
| `ProCToProC2.swift` | FabFilter Pro-C → Pro-C 2: settings translation, AU hosting, slots |
| `ProCTables.swift` | measured Pro-C → Pro-C 2 timing, makeup and link tables (generated) |
| `UtilityDevice.swift` | build a Live Utility; allocate ids from `NextPointeeId` |
| `AppModel.swift` | what's open, scanning, statuses, summaries; shared plugin catalogs |
| `SetModel.swift` | one open set: its DOM, slots, auto-suggest, save |
| `Library.swift` | folder discovery and the `SetStatus` rule |
| `LiveSetScan.swift` | fast scan of a set's plugins, and its on-disk cache |
| `PluginInventory.swift` | what's installed in each format, and which builds are native |
| `PluginIndex.swift` | every plugin across the library, and what each needs |
| `LiveApps.swift` | installed Lives, which can open a set, the Open button and menus |
| `Samples.swift` | sample references, Live's library locations, missing samples |
| `SetPage.swift` | a set's page: verdict, fixed copy, plugins, samples |
| `LibraryPages.swift` | All Projects / project pages, sets table, Plugins page |
| `LibraryViews.swift` | root view, sidebar, batch sheet |
| `Settings.swift` | Settings window (replacement defaults) |
| `Views.swift` | format badge, Audio Unit picker |
| `App.swift` | AppKit bootstrap + menu |
