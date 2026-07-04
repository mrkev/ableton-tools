import { Input } from "@/components/ui/input";
import { ScrollArea } from "@/components/ui/scroll-area";
import type { OpenDocument } from "@/workspace/WorkspaceContext";
import { useWorkspace } from "@/workspace/WorkspaceContext";
import type { ViewMode } from "@/workspace/views";
import { serializeAlsTree } from "ableton-tools";
import { AlertTriangle, Loader2, Search } from "lucide-react";
import { useCallback, useMemo, useState } from "react";
import type { NodePath } from "@/workspace/history";
import { DevicesView } from "./DevicesView";
import { SummaryView } from "./SummaryView";
import { TracksView } from "./TracksView";
import { XmlTree } from "./inspector/XmlTree";

export function DocumentView({
  document,
  view,
}: {
  document: OpenDocument;
  view: ViewMode;
}) {
  const { editAttribute, isDirty } = useWorkspace();
  const [query, setQuery] = useState("");
  const dirty = isDirty(document.id);
  const tree = document.tree;

  // Show edits live in the source view by re-serializing the tree when dirty.
  const sourceXml = useMemo(
    () =>
      dirty && tree
        ? serializeAlsTree(tree)
        : document.doc?.xml ?? "",
    [dirty, tree, document.doc]
  );

  // Editing addresses the node by its path from the tree root (immer patches).
  const handleEdit = useCallback(
    (path: NodePath, key: string, value: string) => {
      editAttribute(document.id, path, key, value);
    },
    [editAttribute, document.id]
  );

  if (document.status === "loading") {
    return (
      <Centered>
        <Loader2 className="size-5 animate-spin" />
        <span>Parsing {document.fileName}…</span>
      </Centered>
    );
  }

  if (document.status === "error" || !document.doc || !tree) {
    return (
      <Centered>
        <AlertTriangle className="size-6 text-destructive" />
        <div className="text-center">
          <p className="font-medium">Couldn’t open {document.fileName}</p>
          <p className="max-w-md text-sm text-muted-foreground">
            {document.error ??
              "This file doesn’t look like a valid Ableton Live Set."}
          </p>
        </div>
      </Centered>
    );
  }

  const doc = document.doc;

  if (view === "summary") {
    return (
      <ScrollArea className="h-full">
        <SummaryView doc={doc} />
      </ScrollArea>
    );
  }

  if (view === "tracks") {
    return (
      <ScrollArea className="h-full">
        <TracksView tree={tree} />
      </ScrollArea>
    );
  }

  if (view === "devices") {
    // DevicesView manages its own search header + scroll region.
    return <DevicesView tree={tree} />;
  }

  if (view === "inspector") {
    return (
      <div className="flex h-full min-h-0 flex-col">
        <div className="flex items-center gap-2 border-b px-3 py-2">
          <Search className="size-4 text-muted-foreground" />
          <Input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Search tags, attributes, values…"
            className="h-7 border-0 bg-transparent px-0 shadow-none focus-visible:ring-0"
          />
          <span className="text-xs text-muted-foreground">
            click a value to edit
          </span>
        </div>
        <ScrollArea className="min-h-0 flex-1">
          <div className="p-3">
            <XmlTree nodes={tree} onEdit={handleEdit} query={query} />
          </div>
        </ScrollArea>
      </div>
    );
  }

  // Raw XML source.
  return (
    <ScrollArea className="h-full">
      <pre className="p-4 font-mono text-xs leading-relaxed whitespace-pre">
        {sourceXml}
      </pre>
    </ScrollArea>
  );
}

function Centered({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex h-full flex-col items-center justify-center gap-3 text-muted-foreground">
      {children}
    </div>
  );
}
