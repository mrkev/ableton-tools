# ableton-tools — TODO / follow-ups

Running list of deferred work. Grouped by area; roughly ordered by value.

## Editing

- [ ] **Structural edits** — add / remove / rename / reorder nodes (delete a
      track, remove a device, duplicate a clip). Foundation is in place: all
      edits already flow through immer `produceWithPatches` in
      `packages/site/src/workspace/history.ts`, so structural ops get
      undo/redo for free — they just aren't wired to any UI yet.
- [ ] **Editing beyond attribute values** — today only attribute values are
      editable (that's where Live stores names, tempos, parameters). Element
      text content and tag structure are read-only.
- [ ] **Real "Save"** — `saveDocument` currently serializes + gzips and
      downloads a new `.als` (never overwrites in place). Consider the File
      System Access API (`showSaveFilePicker`) for true save / save-as where
      supported.

## Inspector / views

- [ ] **Live Overview stats** — tempo / track / scene counts in the Overview
      come from the original parse (`AlsSummary`, regex over original XML) and
      don't reflect edits. Recompute from the live tree instead.
- [ ] **Clips sidebar tool** — still stubbed in `ToolsSidebar`
      (`FUTURE_TOOLS`). A per-track / per-scene clip browser.
- [ ] **Device categorization gaps** — `NATIVE_DEVICES` in `als.ts` is a
      curated subset; unknown native tags fall back to a de-camelCased name +
      `category: "unknown"`. Plugin role is resolved (AU `ComponentType`, VST2
      `Category`, VST3 `DeviceType`); the VST3 `1 = instrument` / else = effect
      mapping is confirmed against real sets (Serum = instrument, dearVR MICRO =
      effect). Extend `NATIVE_DEVICES` as unknown native tags turn up.

## Performance / build

- [ ] **Bundle splitting** — production build emits one ~480 kB chunk (immer +
      Base UI + Geist). Add `build.rollupOptions.output.manualChunks` to split
      vendor code once it matters.
- [ ] **XML tree virtualization** — large sets render every row; the tree also
      re-renders fully on each edit (index-path props bust `React.memo`).
      Virtualize / stabilize if big files get sluggish.

## Device Converter (native macOS app — `packages/device-converter`)

- [ ] **Validate the generated AU block against Live 11.** `DeviceBuilder.swift`
      produces a best-effort `<AuPluginDevice>` (identity + envelope, default
      state). Confirm Live 11 opens a converted set and the plugin instantiates;
      tweak the block layout as needed.
- [ ] **Phase 2 — parameter bridge.** JUCE plugin-host helper to load the source
      VST3, read its state + parameters, and write them into the AU by name
      (indices/counts differ across formats). Preserves most settings.
- [ ] **Learned identity map** — bootstrap a VST3-UID → AU-component-code table
      from sets that contain both formats (helps when only the VST3 is present).
- [ ] Bundle as a distributable `.app` (currently a CLI-buildable SwiftPM exe).
- [x] **VST2 → VST3: confirm in Live 11 (native)** that a converted set opens
      and works.
- [x] **VST2 → VST3 in the GUI** — a "Convert to VST3" slot action next to the
      AU one.
- [x] **Project library** — open a folder of projects, see each set's status.
- [x] **Native status** — whether each set opens in a native Live, across VST2, VST3
      and AU.
- [x] **VST2 → VST3: batch conversion** from the library or `--batch`.
- [ ] **Check a batch's output in Live** before writing beside the originals.
- [ ] **Run single-set Save As through the batch worker** too. It still hosts plugins
      in the app, so it crawls if the window is hidden and a plugin crash takes the
      app down.
- [ ] **Try `--force` on a Live 9 set**, then open the result in Live 11. Only matters
      for sets that need converting; Live 9 sets with native plugins already open.
- [ ] **Find native builds of the top blockers** — TapeStop (21 + 4 as AU),
      DJMFilter (9), Cthulhu (4, the installed build is Intel only). The library's
      "Plugins holding sets back" has the full list. Now native: Massive 1.7,
      DimensionExpander, FabFilter Pro-Q 2. FabFilter Pro-C has a replacement.
- [x] **AMBEO Orbit → dearVR MICRO**, opt-in, with a level-matching Utility.
- [x] **FabFilter Pro-C → Pro-C 2**, opt-in, settings translated and calibrated by render.
- [ ] **Open a Pro-C → Pro-C 2 conversion in Live 11**: Pro-C 2 loads with the translated
      settings, its slots show the right values, and it sounds like the original.
- [ ] **Pro-C mid/side devices** (10, one per set in MessengerSettings, beats, encoded,
      wobble): Pro-C 2 can't compress mid and side separately. An Audio Effect Rack
      splitting mid and side into two Pro-C 2 chains could; Live has no M/S encoder,
      so check whether Utility can do the split first.
- [ ] **Open an Orbit → MICRO conversion in Live 11**: MICRO loads with its settings,
      the Utility sits after it, and the level matches Orbit by ear.
- [ ] **Check that a Massive AU set loads its patch** in native Live (1.7 is native, but
      old state loading is untested).
- [ ] **Check in Live**: Save As from inside the library, and whether a converted
      `MLoudnessAnalyzer` (the first non-Serum conversion) sounds right.
- [x] **OTT → native VST3**, from its Intel AU and its VST2 parameter dumps.
- [ ] **Open an OTT conversion in Live 11**: OTT loads as VST3 with its settings.
- [ ] **Parameter dumps for other VST3s** — only VST3s whose state is plain
      parameter floats (OTT) take one today. Others would need the controller's
      `setParamNormalized` plus a processor parameter change.

## Nice-to-haves

- [ ] Recent files, drag-to-reorder tabs, resizable panels.
- [ ] Recompute/refresh `AlsSummary` from the edited tree on save.
