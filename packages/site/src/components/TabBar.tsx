import { cn } from "@/lib/utils";
import { useWorkspace } from "@/workspace/WorkspaceContext";
import { Loader2, Music, X } from "lucide-react";

/** VSCode-like horizontal strip of open-document tabs. */
export function TabBar() {
  const { documents, activeId, setActiveId, closeDocument, isDirty } =
    useWorkspace();

  if (documents.length === 0) return null;

  return (
    <div className="flex h-9 shrink-0 items-stretch overflow-x-auto border-b bg-muted/30">
      {documents.map((d) => {
        const isActive = d.id === activeId;
        return (
          <div
            key={d.id}
            role="tab"
            aria-selected={isActive}
            onClick={() => setActiveId(d.id)}
            onAuxClick={(e) => {
              // Middle-click closes, like an editor.
              if (e.button === 1) closeDocument(d.id);
            }}
            className={cn(
              "group flex min-w-0 max-w-52 cursor-pointer items-center gap-2 border-r px-3 text-sm",
              isActive
                ? "bg-background text-foreground"
                : "bg-transparent text-muted-foreground hover:bg-background/50"
            )}
          >
            {d.status === "loading" ? (
              <Loader2 className="size-3.5 shrink-0 animate-spin" />
            ) : (
              <Music
                className={cn(
                  "size-3.5 shrink-0",
                  d.status === "error" && "text-destructive"
                )}
              />
            )}
            <span className="truncate">{d.fileName}</span>
            <button
              type="button"
              aria-label={`Close ${d.fileName}`}
              onClick={(e) => {
                e.stopPropagation();
                closeDocument(d.id);
              }}
              className="relative flex size-4 shrink-0 items-center justify-center rounded hover:bg-muted-foreground/20"
            >
              {/* Dirty dot, swapped for the close X on hover. */}
              {isDirty(d.id) && (
                <span className="absolute size-2 rounded-full bg-foreground/70 group-hover:opacity-0" />
              )}
              <X className="size-3 opacity-0 group-hover:opacity-100" />
            </button>
          </div>
        );
      })}
    </div>
  );
}
