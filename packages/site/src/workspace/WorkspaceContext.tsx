import { exportAls, parseAls, type AlsDocument, type XmlNode } from "ableton-tools";
import {
  createContext,
  useCallback,
  useContext,
  useMemo,
  useState,
  type ReactNode,
} from "react";
import { downloadBytes } from "./download";
import {
  applyAttributeEdit,
  canRedo,
  canUndo,
  emptyHistory,
  isDirty,
  markSaved,
  redo as redoHistory,
  undo as undoHistory,
  type DocumentHistory,
  type NodePath,
} from "./history";
import { openFileDialog } from "./openFileDialog";

/** An open document tab, with its live (editable) tree and edit history. */
export interface OpenDocument {
  id: string;
  fileName: string;
  /** Original parse result (xml, summary, original tree). Immutable. */
  doc: AlsDocument | null;
  /** Live, edited tree — the source of truth for editing views. */
  tree: XmlNode[] | null;
  history: DocumentHistory;
  status: "loading" | "ready" | "error";
  error?: string;
}

interface WorkspaceState {
  documents: OpenDocument[];
  activeId: string | null;
  /** The currently-focused document, if any. */
  active: OpenDocument | null;
  /** Prompt the user for `.als` files and open each in a tab. */
  openFiles: () => Promise<void>;
  /** Open a specific File (e.g. from drag & drop) in a tab. */
  openFile: (file: File) => Promise<void>;
  closeDocument: (id: string) => void;
  setActiveId: (id: string) => void;
  /** Set an attribute value on the node at `path` (undoable). */
  editAttribute: (
    id: string,
    path: NodePath,
    key: string,
    value: string
  ) => void;
  undo: (id: string) => void;
  redo: (id: string) => void;
  canUndo: (id: string) => boolean;
  canRedo: (id: string) => boolean;
  /** Whether a document has unsaved edits. */
  isDirty: (id: string) => boolean;
  /** Serialize + gzip a document's tree and download it as `.als`. */
  saveDocument: (id: string) => Promise<void>;
}

const WorkspaceContext = createContext<WorkspaceState | null>(null);

let idCounter = 0;
const nextId = () => `doc-${++idCounter}`;

export function WorkspaceProvider({ children }: { children: ReactNode }) {
  const [documents, setDocuments] = useState<OpenDocument[]>([]);
  const [activeId, setActiveId] = useState<string | null>(null);

  /** Replace the document with `id` by running `fn` over it. */
  const updateDoc = useCallback(
    (id: string, fn: (doc: OpenDocument) => OpenDocument) => {
      setDocuments((docs) => docs.map((d) => (d.id === id ? fn(d) : d)));
    },
    []
  );

  const openFile = useCallback(async (file: File) => {
    const id = nextId();
    setDocuments((docs) => [
      ...docs,
      {
        id,
        fileName: file.name,
        doc: null,
        tree: null,
        history: emptyHistory(),
        status: "loading",
      },
    ]);
    setActiveId(id);

    try {
      const buffer = await file.arrayBuffer();
      const doc = await parseAls(buffer, file.name);
      setDocuments((docs) =>
        docs.map((d) =>
          d.id === id
            ? { ...d, doc, tree: doc.tree, status: "ready" }
            : d
        )
      );
    } catch (err) {
      setDocuments((docs) =>
        docs.map((d) =>
          d.id === id
            ? {
                ...d,
                status: "error",
                error: err instanceof Error ? err.message : String(err),
              }
            : d
        )
      );
    }
  }, []);

  const openFiles = useCallback(async () => {
    const files = await openFileDialog({ accept: ".als", multiple: true });
    for (const file of files) {
      await openFile(file);
    }
  }, [openFile]);

  const closeDocument = useCallback((id: string) => {
    setDocuments((docs) => {
      const idx = docs.findIndex((d) => d.id === id);
      const next = docs.filter((d) => d.id !== id);
      setActiveId((current) => {
        if (current !== id) return current;
        if (next.length === 0) return null;
        // Focus the neighbour that takes the closed tab's place.
        return next[Math.min(idx, next.length - 1)].id;
      });
      return next;
    });
  }, []);

  const editAttribute = useCallback(
    (id: string, path: NodePath, key: string, value: string) => {
      updateDoc(id, (d) => {
        if (!d.tree) return d;
        const result = applyAttributeEdit(d.tree, d.history, path, key, value);
        if (!result) return d;
        return { ...d, tree: result.tree, history: result.history };
      });
    },
    [updateDoc]
  );

  const undo = useCallback(
    (id: string) => {
      updateDoc(id, (d) => {
        if (!d.tree) return d;
        const result = undoHistory(d.tree, d.history);
        return { ...d, tree: result.tree, history: result.history };
      });
    },
    [updateDoc]
  );

  const redo = useCallback(
    (id: string) => {
      updateDoc(id, (d) => {
        if (!d.tree) return d;
        const result = redoHistory(d.tree, d.history);
        return { ...d, tree: result.tree, history: result.history };
      });
    },
    [updateDoc]
  );

  const saveDocument = useCallback(
    async (id: string) => {
      const target = documents.find((d) => d.id === id);
      if (!target?.tree) return;
      const bytes = await exportAls(target.tree);
      downloadBytes(bytes, target.fileName);
      updateDoc(id, (d) => ({ ...d, history: markSaved(d.history) }));
    },
    [documents, updateDoc]
  );

  const value = useMemo<WorkspaceState>(() => {
    const byId = (id: string) => documents.find((d) => d.id === id);
    return {
      documents,
      activeId,
      active: byId(activeId ?? "") ?? null,
      openFiles,
      openFile,
      closeDocument,
      setActiveId,
      editAttribute,
      undo,
      redo,
      canUndo: (id) => {
        const d = byId(id);
        return d ? canUndo(d.history) : false;
      },
      canRedo: (id) => {
        const d = byId(id);
        return d ? canRedo(d.history) : false;
      },
      isDirty: (id) => {
        const d = byId(id);
        return d ? isDirty(d.history) : false;
      },
      saveDocument,
    };
  }, [
    documents,
    activeId,
    openFiles,
    openFile,
    closeDocument,
    editAttribute,
    undo,
    redo,
    saveDocument,
  ]);

  return (
    <WorkspaceContext.Provider value={value}>
      {children}
    </WorkspaceContext.Provider>
  );
}

export function useWorkspace(): WorkspaceState {
  const ctx = useContext(WorkspaceContext);
  if (!ctx) {
    throw new Error("useWorkspace must be used within a WorkspaceProvider");
  }
  return ctx;
}
