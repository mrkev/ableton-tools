import type { AlsDocument } from "ableton-tools";
import {
  AudioLines,
  Boxes,
  CornerUpLeft,
  Gauge,
  Music2,
  Wrench,
} from "lucide-react";
import type { LucideIcon } from "lucide-react";

export function SummaryView({ doc }: { doc: AlsDocument }) {
  const s = doc.summary;
  return (
    <div className="mx-auto max-w-3xl space-y-6 p-6">
      <div>
        <h2 className="text-lg font-semibold">{doc.fileName}</h2>
        <p className="text-sm text-muted-foreground">
          {s.creator ?? "Unknown creator"}
          {s.schemaVersion ? ` · schema ${s.schemaVersion}` : ""}
        </p>
      </div>

      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
        <Stat icon={Gauge} label="Tempo" value={s.tempo ? `${s.tempo} BPM` : "—"} />
        <Stat icon={Music2} label="MIDI tracks" value={s.midiTrackCount} />
        <Stat icon={AudioLines} label="Audio tracks" value={s.audioTrackCount} />
        <Stat
          icon={CornerUpLeft}
          label="Return tracks"
          value={s.returnTrackCount}
        />
        <Stat icon={Boxes} label="Scenes" value={s.sceneCount} />
        <Stat
          icon={Wrench}
          label="XML size"
          value={formatBytes(doc.xml.length)}
        />
      </div>
    </div>
  );
}

function Stat({
  icon: Icon,
  label,
  value,
}: {
  icon: LucideIcon;
  label: string;
  value: string | number;
}) {
  return (
    <div className="rounded-lg border bg-card p-4">
      <div className="flex items-center gap-2 text-muted-foreground">
        <Icon className="size-4" />
        <span className="text-xs">{label}</span>
      </div>
      <div className="mt-1 text-2xl font-semibold tabular-nums">{value}</div>
    </div>
  );
}

function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MB`;
}
