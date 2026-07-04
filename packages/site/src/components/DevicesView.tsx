import { Input } from "@/components/ui/input";
import { cn } from "@/lib/utils";
import {
  extractTracks,
  type AlsTrack,
  type DeviceCategory,
  type DeviceFormat,
  type TrackKind,
  type XmlNode,
} from "ableton-tools";
import { ChevronRight, Search } from "lucide-react";
import { useMemo, useState } from "react";
import {
  CATEGORY_ICON,
  CATEGORY_LABEL,
  CATEGORY_ORDER,
  FormatBadge,
  KIND_META,
} from "./deviceMeta";

interface TrackUse {
  name: string;
  kind: TrackKind;
  count: number;
}

/** One unique device/plugin and everywhere it's used across the set. */
interface DeviceUsage {
  product: string;
  type: string;
  format: DeviceFormat;
  category: DeviceCategory;
  vendor?: string;
  vstSdkVersion?: string;
  /** Total instances across the whole set. */
  count: number;
  tracks: TrackUse[];
}

/** A device-centric catalog: every unique device and which tracks use it. */
export function DevicesView({ tree }: { tree: XmlNode[] }) {
  const tracks = useMemo(() => extractTracks(tree), [tree]);
  const usages = useMemo(() => aggregate(tracks), [tracks]);

  const [query, setQuery] = useState("");
  const [pluginsOnly, setPluginsOnly] = useState(false);

  const q = query.trim().toLowerCase();
  const filtered = usages.filter((u) => {
    if (pluginsOnly && u.format === "native") return false;
    if (!q) return true;
    return (
      u.product.toLowerCase().includes(q) ||
      u.type.toLowerCase().includes(q) ||
      (u.vendor?.toLowerCase().includes(q) ?? false) ||
      u.format.includes(q)
    );
  });

  const totalInstances = usages.reduce((n, u) => n + u.count, 0);
  const pluginCount = usages.filter((u) => u.format !== "native").length;

  if (usages.length === 0) {
    return (
      <div className="p-6 text-sm text-muted-foreground">
        No devices found in this set.
      </div>
    );
  }

  return (
    <div className="flex h-full min-h-0 flex-col">
      <div className="flex items-center gap-2 border-b px-3 py-2">
        <Search className="size-4 text-muted-foreground" />
        <Input
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Search devices, plugins, vendors…"
          className="h-7 border-0 bg-transparent px-0 shadow-none focus-visible:ring-0"
        />
        <button
          type="button"
          onClick={() => setPluginsOnly((v) => !v)}
          className={cn(
            "shrink-0 rounded-md border px-2 py-0.5 text-xs",
            pluginsOnly
              ? "border-primary bg-primary/10 text-foreground"
              : "text-muted-foreground hover:bg-muted"
          )}
        >
          Plugins only
        </button>
      </div>

      <div className="min-h-0 flex-1 overflow-y-auto">
        <div className="mx-auto max-w-3xl space-y-4 p-4">
          <p className="px-1 text-sm text-muted-foreground">
            {usages.length} unique {usages.length === 1 ? "device" : "devices"} ·{" "}
            {totalInstances} total · {pluginCount} plugin
            {pluginCount === 1 ? "" : "s"}
          </p>

          {CATEGORY_ORDER.map((category) => {
            const items = filtered
              .filter((u) => u.category === category)
              .sort(sortUsages);
            if (items.length === 0) return null;
            const Icon = CATEGORY_ICON[category];
            return (
              <section key={category} className="space-y-1">
                <h3 className="flex items-center gap-1.5 px-1 text-xs font-semibold tracking-wide text-muted-foreground uppercase">
                  <Icon className="size-3.5" />
                  {CATEGORY_LABEL[category]} ({items.length})
                </h3>
                <div className="overflow-hidden rounded-lg border bg-card">
                  {items.map((u, i) => (
                    <UsageRow key={`${u.format}:${u.product}`} usage={u} first={i === 0} />
                  ))}
                </div>
              </section>
            );
          })}

          {filtered.length === 0 && (
            <p className="px-1 text-sm text-muted-foreground">
              No devices match your filter.
            </p>
          )}
        </div>
      </div>
    </div>
  );
}

function UsageRow({ usage, first }: { usage: DeviceUsage; first: boolean }) {
  const [open, setOpen] = useState(false);
  const Icon = CATEGORY_ICON[usage.category];

  return (
    <div className={cn(!first && "border-t")}>
      <div
        onClick={() => setOpen((o) => !o)}
        className="flex cursor-pointer items-center gap-2 px-3 py-2 text-sm hover:bg-muted/50"
      >
        <ChevronRight
          className={cn(
            "size-3 shrink-0 text-muted-foreground transition-transform",
            open && "rotate-90"
          )}
        />
        <Icon className="size-4 shrink-0 text-muted-foreground" />
        {usage.format !== "native" && <FormatBadge format={usage.format} />}
        <span className="truncate font-medium">{usage.product}</span>
        {usage.vendor && (
          <span className="truncate text-xs text-muted-foreground/70">
            {usage.vendor}
          </span>
        )}
        {usage.vstSdkVersion && (
          <span className="shrink-0 text-[10px] text-muted-foreground/70">
            VST {usage.vstSdkVersion}
          </span>
        )}
        <span className="ml-auto shrink-0 rounded bg-muted px-1.5 py-0.5 text-xs tabular-nums text-muted-foreground">
          ×{usage.count}
        </span>
      </div>

      {open && (
        <div className="space-y-0.5 bg-muted/20 px-3 pb-2 pl-9">
          <p className="pt-1 text-xs text-muted-foreground">
            Used on {usage.tracks.length} track
            {usage.tracks.length === 1 ? "" : "s"}:
          </p>
          {usage.tracks.map((t, i) => {
            const km = KIND_META[t.kind];
            const KIcon = km.icon;
            return (
              <div key={i} className="flex items-center gap-2 text-sm">
                <KIcon className={cn("size-3.5 shrink-0", km.className)} />
                <span className="truncate">{t.name}</span>
                {t.count > 1 && (
                  <span className="text-xs text-muted-foreground">
                    ×{t.count}
                  </span>
                )}
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}

function sortUsages(a: DeviceUsage, b: DeviceUsage): number {
  // Plugins first, then by instance count desc, then name.
  const aPlugin = a.format !== "native" ? 0 : 1;
  const bPlugin = b.format !== "native" ? 0 : 1;
  if (aPlugin !== bPlugin) return aPlugin - bPlugin;
  if (a.count !== b.count) return b.count - a.count;
  return a.product.localeCompare(b.product);
}

/** Aggregate every device across all tracks into a unique-device catalog. */
function aggregate(tracks: AlsTrack[]): DeviceUsage[] {
  const map = new Map<string, DeviceUsage & { trackMap: Map<string, TrackUse> }>();

  for (const track of tracks) {
    for (const d of track.devices) {
      const key = `${d.format}::${d.product}`;
      let u = map.get(key);
      if (!u) {
        u = {
          product: d.product,
          type: d.type,
          format: d.format,
          category: d.category,
          vendor: d.vendor,
          vstSdkVersion: d.vstSdkVersion,
          count: 0,
          tracks: [],
          trackMap: new Map(),
        };
        map.set(key, u);
      }
      u.count += 1;
      const existing = u.trackMap.get(track.name);
      if (existing) existing.count += 1;
      else u.trackMap.set(track.name, { name: track.name, kind: track.kind, count: 1 });
    }
  }

  const result: DeviceUsage[] = [];
  for (const u of map.values()) {
    u.tracks = [...u.trackMap.values()];
    const { trackMap, ...usage } = u;
    void trackMap;
    result.push(usage);
  }
  return result;
}
