import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { DOCUMENT_TOOLS, type ViewMode } from "@/workspace/views";
import { useWorkspace } from "@/workspace/WorkspaceContext";
import { AudioLines, FolderOpen, SlidersHorizontal } from "lucide-react";

/** Tools that are planned but not yet wired up. */
const FUTURE_TOOLS = [
  { label: "Devices", icon: SlidersHorizontal },
  { label: "Clips", icon: AudioLines },
];

export function ToolsSidebar({
  view,
  onViewChange,
}: {
  view: ViewMode;
  onViewChange: (view: ViewMode) => void;
}) {
  const { active, openFiles } = useWorkspace();
  const hasDoc = active != null;

  return (
    <aside className="flex w-56 shrink-0 flex-col border-r bg-sidebar text-sidebar-foreground">
      <div className="flex items-center justify-between px-3 py-2">
        <span className="text-xs font-semibold tracking-wide text-muted-foreground uppercase">
          Inspect
        </span>
      </div>

      <nav className="flex flex-col gap-0.5 px-2">
        {DOCUMENT_TOOLS.map((tool) => {
          const Icon = tool.icon;
          const selected = hasDoc && view === tool.id;
          return (
            <button
              key={tool.id}
              type="button"
              disabled={!hasDoc}
              onClick={() => onViewChange(tool.id)}
              className={cn(
                "flex items-center gap-2 rounded-md px-2 py-1.5 text-sm transition-colors",
                "disabled:cursor-not-allowed disabled:opacity-40",
                selected
                  ? "bg-sidebar-accent text-sidebar-accent-foreground font-medium"
                  : "hover:bg-sidebar-accent/60"
              )}
            >
              <Icon className="size-4" />
              {tool.label}
            </button>
          );
        })}
      </nav>

      <div className="mt-4 px-3 py-2">
        <span className="text-xs font-semibold tracking-wide text-muted-foreground uppercase">
          Tools
        </span>
      </div>
      <nav className="flex flex-col gap-0.5 px-2">
        {FUTURE_TOOLS.map((tool) => {
          const Icon = tool.icon;
          return (
            <button
              key={tool.label}
              type="button"
              disabled
              title="Coming soon"
              className="flex items-center gap-2 rounded-md px-2 py-1.5 text-sm opacity-40"
            >
              <Icon className="size-4" />
              {tool.label}
              <span className="ml-auto text-[10px] text-muted-foreground">
                soon
              </span>
            </button>
          );
        })}
      </nav>

      <div className="mt-auto p-2">
        <Button
          variant="secondary"
          className="w-full justify-start gap-2"
          onClick={() => void openFiles()}
        >
          <FolderOpen className="size-4" />
          Open .als…
        </Button>
      </div>
    </aside>
  );
}
