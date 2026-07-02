import { Button } from "@/components/ui/button";
import { useWorkspace } from "@/workspace/WorkspaceContext";
import { FolderOpen, MousePointerSquareDashed } from "lucide-react";

export function EmptyState() {
  const { openFiles } = useWorkspace();
  return (
    <div className="flex h-full flex-col items-center justify-center gap-4 text-center">
      <div className="flex size-16 items-center justify-center rounded-2xl border border-dashed text-muted-foreground">
        <MousePointerSquareDashed className="size-7" />
      </div>
      <div className="space-y-1">
        <h2 className="text-lg font-medium">No file open</h2>
        <p className="max-w-sm text-sm text-muted-foreground">
          Open an Ableton Live Set (<code>.als</code>) to inspect its tracks,
          devices, and raw XML. You can also drag a file anywhere onto the
          window.
        </p>
      </div>
      <Button onClick={() => void openFiles()} className="gap-2">
        <FolderOpen className="size-4" />
        Open .als…
      </Button>
    </div>
  );
}
