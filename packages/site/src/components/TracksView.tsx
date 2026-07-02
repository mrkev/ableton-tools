import {
  extractTracks,
  type AlsTrack,
  type TrackKind,
  type XmlNode,
} from "ableton-tools";
import {
  AudioLines,
  CornerUpLeft,
  Folder,
  Music2,
  type LucideIcon,
} from "lucide-react";
import { useMemo } from "react";

const KIND_META: Record<
  TrackKind,
  { label: string; icon: LucideIcon; className: string }
> = {
  midi: { label: "MIDI", icon: Music2, className: "text-sky-500" },
  audio: { label: "Audio", icon: AudioLines, className: "text-emerald-500" },
  return: { label: "Return", icon: CornerUpLeft, className: "text-violet-500" },
  group: { label: "Group", icon: Folder, className: "text-amber-500" },
};

export function TracksView({ tree }: { tree: XmlNode[] }) {
  const tracks = useMemo<AlsTrack[]>(() => extractTracks(tree), [tree]);

  if (tracks.length === 0) {
    return (
      <div className="p-6 text-sm text-muted-foreground">
        No tracks found in this set.
      </div>
    );
  }

  return (
    <div className="mx-auto max-w-3xl space-y-1 p-4">
      <p className="px-2 pb-2 text-sm text-muted-foreground">
        {tracks.length} track{tracks.length === 1 ? "" : "s"}
      </p>
      {tracks.map((track, i) => {
        const meta = KIND_META[track.kind];
        const Icon = meta.icon;
        return (
          <div
            key={`${track.id ?? "x"}-${i}`}
            className="flex items-center gap-3 rounded-lg border bg-card px-3 py-2"
          >
            <Icon className={`size-4 shrink-0 ${meta.className}`} />
            <span className="flex-1 truncate text-sm font-medium">
              {track.name}
            </span>
            <span className="rounded bg-muted px-1.5 py-0.5 text-xs text-muted-foreground">
              {meta.label}
            </span>
            {track.id != null && (
              <span className="w-10 text-right font-mono text-xs text-muted-foreground">
                #{track.id}
              </span>
            )}
          </div>
        );
      })}
    </div>
  );
}
