import { XMLBuilder, XMLParser } from "fast-xml-parser";

/**
 * Ableton Live Set (`.als`) files are gzip-compressed XML documents. This
 * module handles decompressing and parsing them into structures that are
 * convenient to inspect and traverse.
 */

/** gzip magic bytes: every gzip stream starts with 0x1f 0x8b. */
const GZIP_MAGIC = [0x1f, 0x8b];

function isGzip(bytes: Uint8Array): boolean {
  return bytes[0] === GZIP_MAGIC[0] && bytes[1] === GZIP_MAGIC[1];
}

/**
 * Gunzip a byte buffer using the platform `DecompressionStream` (available in
 * modern browsers and Node 18+). Falls back to returning the input untouched if
 * it isn't actually gzip-compressed (some `.als` exports are plain XML).
 */
export async function gunzip(
  data: ArrayBuffer | Uint8Array
): Promise<Uint8Array> {
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
  if (!isGzip(bytes)) {
    return bytes;
  }

  if (typeof DecompressionStream === "undefined") {
    throw new Error(
      "DecompressionStream is not available in this environment; cannot gunzip .als file."
    );
  }

  const stream = new Blob([bytes as BlobPart]).stream().pipeThrough(
    new DecompressionStream("gzip")
  );
  const buffer = await new Response(stream).arrayBuffer();
  return new Uint8Array(buffer);
}

/** Decompress a `.als` file's bytes into its raw XML string. */
export async function decompressAls(
  data: ArrayBuffer | Uint8Array
): Promise<string> {
  const bytes = await gunzip(data);
  return new TextDecoder("utf-8").decode(bytes);
}

/** High-level summary extracted from a Live Set, handy for the inspector. */
export interface AlsSummary {
  /** Raw `Creator` attribute, e.g. "Ableton Live 11.3.21". */
  creator?: string;
  /** Live Set schema major/minor version, from the root `<Ableton>` element. */
  schemaVersion?: string;
  /** Project tempo in BPM, if present. */
  tempo?: number;
  /** Number of MIDI tracks. */
  midiTrackCount: number;
  /** Number of audio tracks. */
  audioTrackCount: number;
  /** Number of return tracks. */
  returnTrackCount: number;
  /** Number of scenes. */
  sceneCount: number;
}

/** A fully parsed Live Set. */
export interface AlsDocument {
  /** Original file name, e.g. "my song.als". */
  fileName: string;
  /** Raw decompressed XML source. */
  xml: string;
  /**
   * Parsed XML tree (fast-xml-parser, `preserveOrder` form). This is an ordered
   * array of nodes that faithfully mirrors the document and is ideal for
   * rendering a tree view.
   */
  tree: XmlNode[];
  /** Quick stats about the set. */
  summary: AlsSummary;
}

/**
 * A node in the `preserveOrder` parse tree. Each object has exactly one tag key
 * whose value is the array of child nodes, plus an optional `:@` attributes bag.
 * Text nodes use the special `#text` key.
 */
export type XmlAttributes = Record<string, string | number>;

export type XmlNode = {
  [tag: string]: XmlNode[] | string | number | XmlAttributes | undefined;
};

const parser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: "",
  preserveOrder: true,
  parseAttributeValue: true,
  parseTagValue: true,
  trimValues: true,
  ignoreDeclaration: true,
});

/** Parse already-decompressed Live Set XML into a tree + summary. */
export function parseAlsXml(xml: string): {
  tree: XmlNode[];
  summary: AlsSummary;
} {
  const tree = parser.parse(xml) as XmlNode[];
  return { tree, summary: summarize(xml) };
}

/**
 * Parse a `.als` file (raw bytes) into a full {@link AlsDocument}.
 *
 * @param data     The file's bytes (gzip-compressed or plain XML).
 * @param fileName Display name to attach to the document.
 */
export async function parseAls(
  data: ArrayBuffer | Uint8Array,
  fileName: string
): Promise<AlsDocument> {
  const xml = await decompressAls(data);
  const { tree, summary } = parseAlsXml(xml);
  return { fileName, xml, tree, summary };
}

const builder = new XMLBuilder({
  ignoreAttributes: false,
  attributeNamePrefix: "",
  preserveOrder: true,
  format: true,
  indentBy: "\t",
  suppressEmptyNode: true,
});

const XML_DECLARATION = '<?xml version="1.0" encoding="UTF-8"?>';

/**
 * Serialize a parse tree back into Live Set XML. The XML declaration is
 * re-added (it's stripped during parsing) so the result is a complete document.
 */
export function serializeAlsTree(tree: XmlNode[]): string {
  const body = builder.build(tree).trimEnd();
  return `${XML_DECLARATION}\n${body}\n`;
}

/** gzip-compress a string using the platform `CompressionStream`. */
export async function gzip(text: string): Promise<Uint8Array> {
  if (typeof CompressionStream === "undefined") {
    throw new Error(
      "CompressionStream is not available in this environment; cannot write .als file."
    );
  }
  const bytes = new TextEncoder().encode(text);
  const stream = new Blob([bytes as BlobPart])
    .stream()
    .pipeThrough(new CompressionStream("gzip"));
  const buffer = await new Response(stream).arrayBuffer();
  return new Uint8Array(buffer);
}

/**
 * Serialize a parse tree and gzip-compress it into `.als` file bytes, ready to
 * download or write to disk.
 */
export async function exportAls(tree: XmlNode[]): Promise<Uint8Array> {
  return gzip(serializeAlsTree(tree));
}

/**
 * Extract a lightweight summary directly from the XML text. We scan the source
 * rather than walking the tree because the relevant facts live in a handful of
 * well-known attributes/elements and string scanning keeps this cheap.
 */
function summarize(xml: string): AlsSummary {
  const creator = matchAttr(xml, "Creator");
  const major = matchAttr(xml, "MajorVersion");
  const minor = matchAttr(xml, "MinorVersion");
  const schemaVersion =
    major || minor ? [major, minor].filter(Boolean).join(" / ") : undefined;

  // Master/global tempo is stored as <Tempo><Manual Value="120" /></Tempo>.
  const tempo = matchTempo(xml);

  return {
    creator,
    schemaVersion,
    tempo,
    midiTrackCount: countTags(xml, "MidiTrack"),
    audioTrackCount: countTags(xml, "AudioTrack"),
    returnTrackCount: countTags(xml, "ReturnTrack"),
    sceneCount: countTags(xml, "Scene"),
  };
}

function matchAttr(xml: string, attr: string): string | undefined {
  const m = xml.match(new RegExp(`${attr}="([^"]*)"`));
  return m?.[1];
}

function matchTempo(xml: string): number | undefined {
  // Find the first <Tempo> ... <Manual Value="..."/> ... </Tempo> block.
  const block = xml.match(/<Tempo\b[\s\S]*?<\/Tempo>/);
  const m = block?.[0].match(/<Manual\s+Value="([\d.]+)"/);
  return m ? Number(m[1]) : undefined;
}

/** Count occurrences of an opening tag `<Tag ` or `<Tag>` in the source. */
function countTags(xml: string, tag: string): number {
  const matches = xml.match(new RegExp(`<${tag}(\\s|>|/)`, "g"));
  return matches ? matches.length : 0;
}

/** Depth-first walk over every element node in the tree. */
export function walk(nodes: XmlNode[], visit: (node: XmlNode) => void): void {
  for (const node of nodes) {
    if (isTextNode(node)) continue;
    visit(node);
    walk(nodeChildren(node), visit);
  }
}

/** Find the first direct child element with the given tag. */
export function findChild(node: XmlNode, tag: string): XmlNode | undefined {
  return nodeChildren(node).find((c) => nodeTag(c) === tag);
}

/** Follow a path of child tags, returning the node at the end (or undefined). */
export function findPath(node: XmlNode, ...tags: string[]): XmlNode | undefined {
  let current: XmlNode | undefined = node;
  for (const tag of tags) {
    if (!current) return undefined;
    current = findChild(current, tag);
  }
  return current;
}

/** Read the `Value` attribute of a child element (the common Live idiom). */
function childValue(node: XmlNode, tag: string): string | undefined {
  const child = findChild(node, tag);
  if (!child) return undefined;
  const v = nodeAttributes(child)["Value"];
  return v == null ? undefined : String(v);
}

export type TrackKind = "midi" | "audio" | "return" | "group";

export interface AlsTrack {
  kind: TrackKind;
  /** The track's Live `Id`, if present. */
  id?: string;
  /** Effective (display) name. */
  name: string;
  /** Color index into Live's palette, if present. */
  color?: number;
  /** Devices (instruments & effects) on the track, in chain order. */
  devices: AlsDevice[];
}

const TRACK_TAGS: Record<string, TrackKind> = {
  MidiTrack: "midi",
  AudioTrack: "audio",
  ReturnTrack: "return",
  GroupTrack: "group",
};

/** Extract the list of tracks (with names, colors, and devices) from a set. */
export function extractTracks(tree: XmlNode[]): AlsTrack[] {
  const tracks: AlsTrack[] = [];
  walk(tree, (node) => {
    const kind = TRACK_TAGS[nodeTag(node)];
    if (!kind) return;

    const id = nodeAttributes(node)["Id"];
    // Name lives at Name > EffectiveName Value (falling back to UserName).
    const nameNode = findChild(node, "Name");
    const name =
      (nameNode && childValue(nameNode, "EffectiveName")) ||
      (nameNode && childValue(nameNode, "UserName")) ||
      "(unnamed)";
    const colorRaw = childValue(node, "Color") ?? childValue(node, "ColorIndex");

    tracks.push({
      kind,
      id: id == null ? undefined : String(id),
      name,
      color: colorRaw != null ? Number(colorRaw) : undefined,
      devices: extractTrackDevices(node),
    });
  });
  return tracks;
}

// ---------------------------------------------------------------------------
// Devices: software instruments, audio/MIDI effects, and plugins.
// ---------------------------------------------------------------------------

export type DeviceCategory =
  | "instrument"
  | "audioEffect"
  | "midiEffect"
  | "unknown";

export type DeviceFormat = "native" | "vst" | "vst3" | "au" | "m4l";

export interface AlsDevice {
  /** Raw XML tag / internal class name, e.g. "Operator", "Vst3PluginDevice". */
  type: string;
  /** Display name: custom name → plugin product name → friendly device name. */
  name: string;
  /**
   * Device/product identity ignoring any user rename — the thing you'd group by
   * (e.g. "Operator", "EQ Eight", "Serum"). Equals {@link name} when the device
   * hasn't been renamed.
   */
  product: string;
  /** Instrument vs effect, where determinable. */
  category: DeviceCategory;
  /** How the device is hosted. */
  format: DeviceFormat;
  /** True for the four Rack (group) device types. */
  isRack: boolean;
  /** Plugin product name (e.g. "Serum", "Pro-Q 3"), for plugin formats. */
  pluginName?: string;
  /** Plugin vendor / manufacturer, when the format records it. */
  vendor?: string;
  /**
   * VST SDK version the plugin reports, for VST2 plugins (e.g. "2.4"). VST2 is
   * always this wrapper; the number just refines the sub-version.
   */
  vstSdkVersion?: string;
  /**
   * Stable plugin identifier: the VST2 `UniqueId` or AU `ComponentSubType`,
   * shown as its four-character code when printable (e.g. "XfsX").
   */
  uniqueId?: string;
  /** Whether the device is enabled (its On switch). */
  enabled: boolean;
  /** Nesting depth: 0 = top-level in the track chain, >0 = inside a Rack. */
  depth: number;
}

const RACK_TAGS = new Set([
  "DrumGroupDevice",
  "InstrumentGroupDevice",
  "AudioEffectGroupDevice",
  "MidiEffectGroupDevice",
]);

// Non-generic plugin wrappers map straight to a format. `PluginDevice` is
// generic — it hosts BOTH VST2 and VST3, told apart by its PluginDesc contents
// (see detectFormat) — so it is deliberately absent here.
const PLUGIN_FORMAT: Record<string, DeviceFormat> = {
  Vst3PluginDevice: "vst3",
  AuPluginDevice: "au",
  MxDeviceInstrument: "m4l",
  MxDeviceAudioEffect: "m4l",
  MxDeviceMidiEffect: "m4l",
};

/**
 * Determine a device's plugin format. A `<PluginDevice>` wraps either VST2 or
 * VST3 (Live doesn't use a distinct VST3 wrapper element in 10.x), so we look
 * inside `PluginDesc` for a `Vst3PluginInfo` to tell them apart.
 */
function detectFormat(dev: XmlNode, type: string): DeviceFormat {
  if (type === "PluginDevice") {
    const desc = findChild(dev, "PluginDesc");
    if (desc && findChild(desc, "Vst3PluginInfo")) return "vst3";
    return "vst";
  }
  return PLUGIN_FORMAT[type] ?? "native";
}

/** Curated internal-name → {display name, category} for common Live devices. */
const NATIVE_DEVICES: Record<string, { name: string; category: DeviceCategory }> =
  {
    // Instruments
    Operator: { name: "Operator", category: "instrument" },
    InstrumentVector: { name: "Wavetable", category: "instrument" },
    MultiSampler: { name: "Sampler", category: "instrument" },
    OriginalSimpler: { name: "Simpler", category: "instrument" },
    Impulse: { name: "Impulse", category: "instrument" },
    UltraAnalog: { name: "Analog", category: "instrument" },
    Collision: { name: "Collision", category: "instrument" },
    StringStudio: { name: "Tension", category: "instrument" },
    LoungeLizard: { name: "Electric", category: "instrument" },
    Drift: { name: "Drift", category: "instrument" },
    Meld: { name: "Meld", category: "instrument" },
    ExternalInstrument: { name: "External Instrument", category: "instrument" },
    DrumGroupDevice: { name: "Drum Rack", category: "instrument" },
    InstrumentGroupDevice: { name: "Instrument Rack", category: "instrument" },
    // Audio effects
    Eq8: { name: "EQ Eight", category: "audioEffect" },
    FilterEQ3: { name: "EQ Three", category: "audioEffect" },
    Compressor2: { name: "Compressor", category: "audioEffect" },
    Glue: { name: "Glue Compressor", category: "audioEffect" },
    Limiter: { name: "Limiter", category: "audioEffect" },
    MultibandDynamics: { name: "Multiband Dynamics", category: "audioEffect" },
    Gate: { name: "Gate", category: "audioEffect" },
    Saturator: { name: "Saturator", category: "audioEffect" },
    Overdrive: { name: "Overdrive", category: "audioEffect" },
    Tube: { name: "Dynamic Tube", category: "audioEffect" },
    Amp: { name: "Amp", category: "audioEffect" },
    Cabinet: { name: "Cabinet", category: "audioEffect" },
    Erosion: { name: "Erosion", category: "audioEffect" },
    Redux2: { name: "Redux", category: "audioEffect" },
    Reverb: { name: "Reverb", category: "audioEffect" },
    HybridReverb: { name: "Hybrid Reverb", category: "audioEffect" },
    Echo: { name: "Echo", category: "audioEffect" },
    Delay: { name: "Delay", category: "audioEffect" },
    PingPongDelay: { name: "Ping Pong Delay", category: "audioEffect" },
    FilterDelay: { name: "Filter Delay", category: "audioEffect" },
    GrainDelay: { name: "Grain Delay", category: "audioEffect" },
    Phaser: { name: "Phaser", category: "audioEffect" },
    Flanger: { name: "Flanger", category: "audioEffect" },
    Chorus: { name: "Chorus", category: "audioEffect" },
    AutoPan: { name: "Auto Pan", category: "audioEffect" },
    AutoFilter: { name: "Auto Filter", category: "audioEffect" },
    StereoGain: { name: "Utility", category: "audioEffect" },
    Tuner: { name: "Tuner", category: "audioEffect" },
    Spectrum: { name: "Spectrum", category: "audioEffect" },
    Resonator: { name: "Resonators", category: "audioEffect" },
    Vocoder: { name: "Vocoder", category: "audioEffect" },
    FrequencyShifter: { name: "Frequency Shifter", category: "audioEffect" },
    BeatRepeat: { name: "Beat Repeat", category: "audioEffect" },
    Corpus: { name: "Corpus", category: "audioEffect" },
    DrumBuss: { name: "Drum Buss", category: "audioEffect" },
    Pedal: { name: "Pedal", category: "audioEffect" },
    Roar: { name: "Roar", category: "audioEffect" },
    Shifter: { name: "Shifter", category: "audioEffect" },
    AudioEffectGroupDevice: {
      name: "Audio Effect Rack",
      category: "audioEffect",
    },
    // MIDI effects
    MidiArpeggiator: { name: "Arpeggiator", category: "midiEffect" },
    MidiChord: { name: "Chord", category: "midiEffect" },
    MidiPitcher: { name: "Pitch", category: "midiEffect" },
    MidiScale: { name: "Scale", category: "midiEffect" },
    MidiVelocity: { name: "Velocity", category: "midiEffect" },
    NoteLength: { name: "Note Length", category: "midiEffect" },
    MidiRandom: { name: "Random", category: "midiEffect" },
    MidiEffectGroupDevice: {
      name: "MIDI Effect Rack",
      category: "midiEffect",
    },
  };

/**
 * Extract every device on a track, in chain order, descending into Racks.
 * Devices are exactly the element children of a `<Devices>` node; Racks nest
 * further `<Devices>` inside their branches (reported at a greater `depth`).
 */
export function extractTrackDevices(track: XmlNode): AlsDevice[] {
  const out: AlsDevice[] = [];

  const recurse = (node: XmlNode, depth: number) => {
    for (const child of nodeChildren(node)) {
      if (isTextNode(child)) continue;
      if (nodeTag(child) === "Devices") {
        for (const dev of nodeChildren(child)) {
          if (isTextNode(dev)) continue;
          out.push(describeDevice(dev, depth));
          if (RACK_TAGS.has(nodeTag(dev))) recurse(dev, depth + 1);
        }
      } else {
        recurse(child, depth);
      }
    }
  };

  recurse(track, 0);
  return out;
}

function describeDevice(dev: XmlNode, depth: number): AlsDevice {
  const type = nodeTag(dev);
  const isRack = RACK_TAGS.has(type);
  const format = detectFormat(dev, type);
  const enabled = deviceEnabled(dev);
  const userName = childValue(dev, "UserName")?.trim() || undefined;

  let category: DeviceCategory = "unknown";
  let friendly: string;
  let pluginName: string | undefined;
  let vendor: string | undefined;
  let vstSdkVersion: string | undefined;
  let uniqueId: string | undefined;

  if (format === "native") {
    const meta = NATIVE_DEVICES[type];
    friendly = meta?.name ?? deCamelCase(type);
    category = meta?.category ?? "unknown";
  } else if (format === "m4l") {
    category =
      type === "MxDeviceInstrument"
        ? "instrument"
        : type === "MxDeviceMidiEffect"
          ? "midiEffect"
          : "audioEffect";
    friendly = "Max for Live";
  } else {
    // VST / VST3 / AU. Role is derivable for AU (ComponentType) and VST2
    // (Category); VST3 doesn't expose it in a form we've confirmed.
    const info = pluginInfo(dev, format);
    pluginName = info.name;
    vendor = info.vendor;
    category = info.category;
    vstSdkVersion = info.vstSdkVersion;
    uniqueId = info.uniqueId;
    friendly =
      info.name ??
      (format === "vst3"
        ? "VST3 Plugin"
        : format === "au"
          ? "AU Plugin"
          : "VST Plugin");
  }

  return {
    type,
    name: userName ?? pluginName ?? friendly,
    product: pluginName ?? friendly,
    category,
    format,
    isRack,
    pluginName,
    vendor,
    vstSdkVersion,
    uniqueId,
    enabled,
    depth,
  };
}

function deviceEnabled(dev: XmlNode): boolean {
  const on = findChild(dev, "On");
  if (!on) return true;
  const manual = childValue(on, "Manual");
  return manual == null ? true : manual === "true";
}

interface PluginMeta {
  name?: string;
  vendor?: string;
  category: DeviceCategory;
  vstSdkVersion?: string;
  uniqueId?: string;
}

function pluginInfo(dev: XmlNode, format: DeviceFormat): PluginMeta {
  const desc = findChild(dev, "PluginDesc") ?? dev;

  if (format === "au") {
    // AU records its type as a FourCC (ComponentType) and its stable id as
    // ComponentSubType; Manufacturer is a human-readable vendor string.
    const info = findChild(desc, "AuPluginInfo") ?? desc;
    const compType = numChild(info, "ComponentType");
    const subType = numChild(info, "ComponentSubType");
    return {
      name: childValue(info, "Name"),
      vendor: childValue(info, "Manufacturer"),
      category: compType != null ? auRole(decodeFourCC(compType)) : "unknown",
      uniqueId: subType != null ? decodeFourCC(subType) : undefined,
    };
  }

  if (format === "vst3") {
    // VST3 stores its role in DeviceType: 1 = instrument (confirmed on real
    // sets); any other present value is treated as an audio effect.
    const info = findChild(desc, "Vst3PluginInfo") ?? desc;
    const dt = numChild(info, "DeviceType");
    return {
      name: childValue(info, "Name"),
      category: dt === 1 ? "instrument" : dt != null ? "audioEffect" : "unknown",
    };
  }

  // VST2: PlugName is the product name; Category encodes the role; VstVersion
  // is the SDK sub-version; UniqueId is the plugin's FourCC id.
  const info = findChild(desc, "VstPluginInfo") ?? desc;
  const cat = numChild(info, "Category");
  const ver = numChild(info, "VstVersion");
  const uid = numChild(info, "UniqueId");
  return {
    name: childValue(info, "PlugName") ?? childValue(info, "Name"),
    category: cat != null ? vst2Role(cat) : "unknown",
    vstSdkVersion: ver != null ? formatVstVersion(ver) : undefined,
    uniqueId: uid != null ? decodeFourCC(uid) ?? String(uid) : undefined,
  };
}

/** Read a direct child's `Value` attribute as a finite number, if possible. */
function numChild(node: XmlNode, tag: string): number | undefined {
  const v = childValue(node, tag);
  if (v == null) return undefined;
  const n = Number(v);
  return Number.isFinite(n) ? n : undefined;
}

/** Decode a 32-bit int as a four-character code, if all bytes are printable. */
function decodeFourCC(n: number): string | undefined {
  const bytes = [
    (n >>> 24) & 0xff,
    (n >>> 16) & 0xff,
    (n >>> 8) & 0xff,
    n & 0xff,
  ];
  if (bytes.every((b) => b >= 32 && b < 127)) {
    return String.fromCharCode(...bytes);
  }
  return undefined;
}

/** Map an AudioUnit ComponentType FourCC to an instrument/effect role. */
function auRole(fourcc: string | undefined): DeviceCategory {
  switch (fourcc) {
    case "aumu": // MusicDevice (instrument)
    case "augn": // Generator
      return "instrument";
    case "aufx": // Effect
    case "aumf": // MusicEffect (MIDI-controlled audio effect)
      return "audioEffect";
    case "aumi": // MIDIProcessor
      return "midiEffect";
    default:
      return "unknown";
  }
}

/** Map a VST2 plug category code (aeffect.h) to an instrument/effect role. */
function vst2Role(category: number): DeviceCategory {
  switch (category) {
    case 2: // kPlugCategSynth
    case 11: // kPlugCategGenerator
      return "instrument";
    case 1: // kPlugCategEffect
    case 3: // Analysis
    case 4: // Mastering
    case 5: // Spacializer
    case 6: // RoomFx
    case 7: // SurroundFx
    case 8: // Restoration
    case 9: // OfflineProcess
      return "audioEffect";
    default: // 0 Unknown, 10 Shell
      return "unknown";
  }
}

/** Format a VST SDK version integer (e.g. 2400) as "2.4". */
function formatVstVersion(v: number): string {
  const major = Math.floor(v / 1000);
  const minor = Math.floor((v % 1000) / 100);
  return `${major}.${minor}`;
}

/** Insert spaces at camelCase boundaries: "AutoFilter" → "Auto Filter". */
function deCamelCase(s: string): string {
  return s
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
    .replace(/([A-Z]+)([A-Z][a-z])/g, "$1 $2");
}

/** Find the first descendant element with `tag` (depth-first, pre-order). */
export function findDescendant(
  node: XmlNode,
  tag: string
): XmlNode | undefined {
  for (const child of nodeChildren(node)) {
    if (isTextNode(child)) continue;
    if (nodeTag(child) === tag) return child;
    const found = findDescendant(child, tag);
    if (found) return found;
  }
  return undefined;
}

/** Get the tag name of a `preserveOrder` node (the non-`:@` key). */
export function nodeTag(node: XmlNode): string {
  for (const key of Object.keys(node)) {
    if (key !== ":@") return key;
  }
  return "#unknown";
}

/** Get the child nodes of a `preserveOrder` node. */
export function nodeChildren(node: XmlNode): XmlNode[] {
  const value = node[nodeTag(node)];
  return Array.isArray(value) ? value : [];
}

/** Get the attribute bag of a `preserveOrder` node. */
export function nodeAttributes(node: XmlNode): XmlAttributes {
  return (node[":@"] as XmlAttributes | undefined) ?? {};
}

/** Whether this node is a text node. */
export function isTextNode(node: XmlNode): boolean {
  return nodeTag(node) === "#text";
}

/** The text value of a text node (or empty string). */
export function nodeText(node: XmlNode): string {
  const v = node["#text"];
  return v == null ? "" : String(v);
}
