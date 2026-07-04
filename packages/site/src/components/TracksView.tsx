import { cn } from "@/lib/utils";
import {
  extractTracks,
  type AlsDevice,
  type AlsTrack,
  type XmlNode,
} from "ableton-tools";
import { ChevronRight, Puzzle } from "lucide-react";
import { useMemo, useState } from "react";
import { CATEGORY_ICON, FormatBadge, KIND_META, pluginDetail } from "./deviceMeta";

export function TracksView({ tree }: { tree: XmlNode[] }) {
  const tracks = useMemo<AlsTrack[]>(() => extractTracks(tree), [tree]);

  // Unique third-party / M4L plugins across the whole set (the headline info).
  const plugins = useMemo(() => collectPlugins(tracks), [tracks]);

  if (tracks.length === 0) {
    return (
      <div className="p-6 text-sm text-muted-foreground">
        No tracks found in this set.
      </div>
    );
  }

  return (
    <div className="mx-auto max-w-3xl space-y-4 p-4">
      {plugins.length > 0 && (
        <div className="rounded-lg border bg-card p-3">
          <div className="mb-2 flex items-center gap-2 text-sm font-medium">
            <Puzzle className="size-4" />
            Plugins in this set ({plugins.length})
          </div>
          <div className="flex flex-wrap gap-1.5">
            {plugins.map((p) => (
              <span
                key={`${p.format}:${p.name}`}
                title={p.vendor}
                className="flex items-center gap-1 rounded-md border px-1.5 py-0.5 text-xs"
              >
                <FormatBadge format={p.format} />
                {p.name}
                {p.vendor && (
                  <span className="text-muted-foreground/70">· {p.vendor}</span>
                )}
              </span>
            ))}
          </div>
        </div>
      )}

      <p className="px-1 text-sm text-muted-foreground">
        {tracks.length} track{tracks.length === 1 ? "" : "s"}
      </p>
      {tracks.map((track, i) => (
        <TrackCard key={`${track.id ?? "x"}-${i}`} track={track} />
      ))}
    </div>
  );
}

function TrackCard({ track }: { track: AlsTrack }) {
  const meta = KIND_META[track.kind];
  const Icon = meta.icon;
  const nested = useMemo(() => nestDevices(track.devices), [track.devices]);

  const instrument = track.devices.find(
    (d) => d.depth === 0 && d.category === "instrument"
  );
  const effectCount = track.devices.filter(
    (d) => d.depth === 0 && (d.category === "audioEffect" || d.category === "midiEffect")
  ).length;

  return (
    <div className="rounded-lg border bg-card">
      <div className="flex items-center gap-3 px-3 py-2">
        <Icon className={cn("size-4 shrink-0", meta.className)} />
        <span className="flex-1 truncate text-sm font-medium">{track.name}</span>
        <span className="rounded bg-muted px-1.5 py-0.5 text-xs text-muted-foreground">
          {meta.label}
        </span>
      </div>

      {track.devices.length === 0 ? (
        <p className="px-3 pb-2 text-xs text-muted-foreground">No devices</p>
      ) : (
        <>
          <div className="px-3 pb-1 text-xs text-muted-foreground">
            {instrument ? instrument.name : "No instrument"}
            {effectCount > 0
              ? ` · ${effectCount} effect${effectCount === 1 ? "" : "s"}`
              : ""}
          </div>
          <div className="border-t px-2 py-1.5">
            {nested.map((node, i) => (
              <DeviceRow key={i} node={node} />
            ))}
          </div>
        </>
      )}
    </div>
  );
}

interface DeviceNode {
  device: AlsDevice;
  children: DeviceNode[];
}

function DeviceRow({ node }: { node: DeviceNode }) {
  const { device, children } = node;
  const [open, setOpen] = useState(false);
  const hasChildren = children.length > 0;
  const CatIcon = CATEGORY_ICON[device.category];

  return (
    <div>
      <div
        onClick={hasChildren ? () => setOpen((o) => !o) : undefined}
        style={{ paddingLeft: device.depth * 16 }}
        title={device.format !== "native" ? pluginDetail(device) : device.type}
        className={cn(
          "flex items-center gap-1.5 rounded px-1 py-1 text-sm",
          hasChildren && "cursor-pointer hover:bg-muted/60",
          !device.enabled && "opacity-45"
        )}
      >
        <ChevronRight
          className={cn(
            "size-3 shrink-0 text-muted-foreground transition-transform",
            open && "rotate-90",
            !hasChildren && "invisible"
          )}
        />
        <CatIcon className="size-3.5 shrink-0 text-muted-foreground" />
        {device.format !== "native" && <FormatBadge format={device.format} />}
        <span className="truncate">{device.name}</span>
        {/* Show the plugin product name when the display name is a custom label. */}
        {device.pluginName && device.pluginName !== device.name && (
          <span className="truncate text-xs text-muted-foreground">
            {device.pluginName}
          </span>
        )}
        {device.vendor && (
          <span className="shrink-0 text-xs text-muted-foreground/70">
            {device.vendor}
          </span>
        )}
        {device.vstSdkVersion && (
          <span className="shrink-0 text-[10px] text-muted-foreground/70">
            {device.vstSdkVersion}
          </span>
        )}
        {device.isRack && hasChildren && (
          <span className="ml-1 text-xs text-muted-foreground">
            {children.length}
          </span>
        )}
        {!device.enabled && (
          <span className="ml-auto text-[10px] tracking-wide text-muted-foreground uppercase">
            off
          </span>
        )}
      </div>
      {hasChildren && open && (
        <div>
          {children.map((child, i) => (
            <DeviceRow key={i} node={child} />
          ))}
        </div>
      )}
    </div>
  );
}

/** Turn the flat, depth-tagged device list into a nested tree for display. */
function nestDevices(devices: AlsDevice[]): DeviceNode[] {
  const roots: DeviceNode[] = [];
  const stack: DeviceNode[] = [];
  for (const device of devices) {
    const node: DeviceNode = { device, children: [] };
    while (stack.length && stack[stack.length - 1].device.depth >= device.depth) {
      stack.pop();
    }
    if (stack.length) stack[stack.length - 1].children.push(node);
    else roots.push(node);
    stack.push(node);
  }
  return roots;
}

interface PluginSummary {
  name: string;
  format: AlsDevice["format"];
  vendor?: string;
}

/** Unique, non-native plugins used across all tracks. */
function collectPlugins(tracks: AlsTrack[]): PluginSummary[] {
  const seen = new Map<string, PluginSummary>();
  for (const track of tracks) {
    for (const d of track.devices) {
      if (d.format === "native") continue;
      const name = d.pluginName ?? d.name;
      const key = `${d.format}:${name}`;
      if (!seen.has(key)) seen.set(key, { name, format: d.format, vendor: d.vendor });
    }
  }
  return [...seen.values()].sort((a, b) => a.name.localeCompare(b.name));
}
