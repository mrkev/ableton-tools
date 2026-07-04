import {
  FileCode2,
  Info,
  Layers,
  ListTree,
  SlidersHorizontal,
  type LucideIcon,
} from "lucide-react";

/** The available inspection views / tools for an open document. */
export type ViewMode =
  | "summary"
  | "tracks"
  | "devices"
  | "inspector"
  | "source";

export interface ToolDef {
  id: ViewMode;
  label: string;
  icon: LucideIcon;
}

/** Tools that operate on the active document, shown in the left rail. */
export const DOCUMENT_TOOLS: ToolDef[] = [
  { id: "summary", label: "Overview", icon: Info },
  { id: "tracks", label: "Tracks", icon: Layers },
  { id: "devices", label: "Devices", icon: SlidersHorizontal },
  { id: "inspector", label: "XML Tree", icon: ListTree },
  { id: "source", label: "XML Source", icon: FileCode2 },
];
