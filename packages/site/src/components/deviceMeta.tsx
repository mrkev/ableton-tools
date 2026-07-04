import { cn } from "@/lib/utils";
import type { AlsDevice, DeviceCategory, TrackKind } from "ableton-tools";
import {
  AudioLines,
  Box,
  CornerUpLeft,
  Folder,
  Music,
  Music2,
  Piano,
  SlidersHorizontal,
  type LucideIcon,
} from "lucide-react";

/** Per-track-kind icon + label. */
export const KIND_META: Record<
  TrackKind,
  { label: string; icon: LucideIcon; className: string }
> = {
  midi: { label: "MIDI", icon: Music2, className: "text-sky-500" },
  audio: { label: "Audio", icon: AudioLines, className: "text-emerald-500" },
  return: { label: "Return", icon: CornerUpLeft, className: "text-violet-500" },
  group: { label: "Group", icon: Folder, className: "text-amber-500" },
};

/** Per-device-category icon. */
export const CATEGORY_ICON: Record<DeviceCategory, LucideIcon> = {
  instrument: Piano,
  audioEffect: SlidersHorizontal,
  midiEffect: Music,
  unknown: Box,
};

/** Human label + display order for device categories. */
export const CATEGORY_LABEL: Record<DeviceCategory, string> = {
  instrument: "Instruments",
  audioEffect: "Audio Effects",
  midiEffect: "MIDI Effects",
  unknown: "Other",
};

export const CATEGORY_ORDER: DeviceCategory[] = [
  "instrument",
  "audioEffect",
  "midiEffect",
  "unknown",
];

const FORMAT_BADGE: Record<string, { label: string; className: string }> = {
  vst: { label: "VST2", className: "bg-orange-500/15 text-orange-600 dark:text-orange-400" },
  vst3: { label: "VST3", className: "bg-orange-500/15 text-orange-600 dark:text-orange-400" },
  au: { label: "AU", className: "bg-indigo-500/15 text-indigo-600 dark:text-indigo-400" },
  m4l: { label: "M4L", className: "bg-emerald-500/15 text-emerald-600 dark:text-emerald-400" },
};

export function FormatBadge({ format }: { format: string }) {
  const badge = FORMAT_BADGE[format];
  if (!badge) return null;
  return (
    <span
      className={cn(
        "rounded px-1 py-px text-[10px] font-medium leading-none",
        badge.className
      )}
    >
      {badge.label}
    </span>
  );
}

/** One-line detail string for a plugin (type · vendor · VST x.y · id). */
export function pluginDetail(d: AlsDevice): string {
  return [
    d.type,
    d.vendor,
    d.vstSdkVersion ? `VST ${d.vstSdkVersion}` : undefined,
    d.uniqueId ? `id ${d.uniqueId}` : undefined,
  ]
    .filter(Boolean)
    .join(" · ");
}
