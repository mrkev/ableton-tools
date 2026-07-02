import { useState } from "react";
import { DocumentView } from "./components/DocumentView";
import { EmptyState } from "./components/EmptyState";
import { MenuBar } from "./components/MenuBar";
import { TabBar } from "./components/TabBar";
import { ToolsSidebar } from "./components/ToolsSidebar";
import { useDropFiles } from "./workspace/useDropFiles";
import type { ViewMode } from "./workspace/views";
import { WorkspaceProvider, useWorkspace } from "./workspace/WorkspaceContext";

function Workspace() {
  const { active, openFile } = useWorkspace();
  const [view, setView] = useState<ViewMode>("summary");
  const { dragging, handlers } = useDropFiles((file) => void openFile(file));

  return (
    <div className="flex h-screen flex-col bg-background text-foreground" {...handlers}>
      <MenuBar />

      <div className="relative flex min-h-0 flex-1">
        <ToolsSidebar view={view} onViewChange={setView} />

        <main className="flex min-w-0 flex-1 flex-col">
          <TabBar />
          <div className="min-h-0 flex-1">
            {active ? (
              <DocumentView document={active} view={view} />
            ) : (
              <EmptyState />
            )}
          </div>
        </main>

        {dragging && (
          <div className="pointer-events-none absolute inset-0 z-50 flex items-center justify-center bg-primary/10 backdrop-blur-sm">
            <div className="rounded-xl border-2 border-dashed border-primary bg-background/80 px-8 py-6 text-lg font-medium">
              Drop .als file to open
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

export function App() {
  return (
    <WorkspaceProvider>
      <Workspace />
    </WorkspaceProvider>
  );
}
