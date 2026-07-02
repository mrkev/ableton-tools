import type { XmlNode } from "ableton-tools";
import {
  applyPatches,
  enablePatches,
  produceWithPatches,
  setAutoFreeze,
  type Patch,
} from "immer";

// immer's patch support is an opt-in plugin.
enablePatches();
// Don't deep-freeze the (potentially huge) parse tree on every produce; we only
// ever mutate it through immer here, so freezing buys correctness we don't need.
setAutoFreeze(false);

/** A path of object keys / array indices locating a node from the tree root. */
export type NodePath = (string | number)[];

interface HistoryEntry {
  patches: Patch[];
  inverse: Patch[];
  /** Identifies the edit target, used to coalesce rapid edits to one field. */
  coalesceKey: string;
  time: number;
}

export interface DocumentHistory {
  entries: HistoryEntry[];
  /** Number of entries currently applied (0 = original document). */
  index: number;
  /** `index` value corresponding to the last saved/original state. */
  savedIndex: number;
}

export function emptyHistory(): DocumentHistory {
  return { entries: [], index: 0, savedIndex: 0 };
}

export function canUndo(h: DocumentHistory): boolean {
  return h.index > 0;
}

export function canRedo(h: DocumentHistory): boolean {
  return h.index < h.entries.length;
}

export function isDirty(h: DocumentHistory): boolean {
  return h.index !== h.savedIndex;
}

export function markSaved(h: DocumentHistory): DocumentHistory {
  return { ...h, savedIndex: h.index };
}

/** Coalesce same-field edits committed within this window into one history step. */
const COALESCE_MS = 700;

/**
 * Set an attribute value on the node at `path`, recording the change as an
 * undoable history entry. Returns `null` when the value is unchanged.
 */
export function applyAttributeEdit(
  tree: XmlNode[],
  history: DocumentHistory,
  path: NodePath,
  key: string,
  value: string
): { tree: XmlNode[]; history: DocumentHistory } | null {
  const [next, patches, inverse] = produceWithPatches(tree, (draft) => {
    // Walk to the target node, then write into its attribute bag (`:@`).
    let cur: unknown = draft;
    for (const step of path) {
      cur = (cur as Record<string | number, unknown>)[step];
    }
    const node = cur as Record<string, unknown>;
    if (node[":@"] == null) node[":@"] = {};
    (node[":@"] as Record<string, string>)[key] = value;
  });

  if (patches.length === 0) return null;

  const coalesceKey = `${path.join("/")}::${key}`;
  const now = Date.now();
  const atTip = history.index === history.entries.length;
  const prev = history.entries[history.index - 1];
  const canCoalesce =
    atTip &&
    prev != null &&
    prev.coalesceKey === coalesceKey &&
    now - prev.time < COALESCE_MS &&
    // Never merge across a save boundary, or the dirty flag desyncs.
    history.savedIndex !== history.index;

  if (canCoalesce) {
    // Keep the original inverse (back to the pre-edit value); update forward.
    const merged: HistoryEntry = {
      patches,
      inverse: prev.inverse,
      coalesceKey,
      time: now,
    };
    const entries = history.entries.slice(0, history.index - 1).concat(merged);
    return {
      tree: next,
      history: { ...history, entries, index: entries.length },
    };
  }

  // New edit: drop any redo branch and append.
  const entries = history.entries
    .slice(0, history.index)
    .concat({ patches, inverse, coalesceKey, time: now });
  return {
    tree: next,
    history: { ...history, entries, index: entries.length },
  };
}

export function undo(
  tree: XmlNode[],
  history: DocumentHistory
): { tree: XmlNode[]; history: DocumentHistory } {
  if (!canUndo(history)) return { tree, history };
  const entry = history.entries[history.index - 1];
  return {
    tree: applyPatches(tree, entry.inverse),
    history: { ...history, index: history.index - 1 },
  };
}

export function redo(
  tree: XmlNode[],
  history: DocumentHistory
): { tree: XmlNode[]; history: DocumentHistory } {
  if (!canRedo(history)) return { tree, history };
  const entry = history.entries[history.index];
  return {
    tree: applyPatches(tree, entry.patches),
    history: { ...history, index: history.index + 1 },
  };
}
