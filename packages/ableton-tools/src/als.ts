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
}

const TRACK_TAGS: Record<string, TrackKind> = {
  MidiTrack: "midi",
  AudioTrack: "audio",
  ReturnTrack: "return",
  GroupTrack: "group",
};

/** Extract the list of tracks (with names/colors) from a parsed Live Set. */
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
    });
  });
  return tracks;
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
