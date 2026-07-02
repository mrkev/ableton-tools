import { cn } from "@/lib/utils";
import type { NodePath } from "@/workspace/history";
import {
  isTextNode,
  nodeAttributes,
  nodeChildren,
  nodeTag,
  nodeText,
  type XmlNode,
} from "ableton-tools";
import { ChevronRight } from "lucide-react";
import { memo, useMemo, useState } from "react";

/** Commit an attribute edit on the node located at `path`. */
export type EditAttr = (path: NodePath, key: string, value: string) => void;

/** Recursive, collapsible, optionally-editable tree view of Live Set XML. */
export function XmlTree({
  nodes,
  onEdit,
  query = "",
}: {
  nodes: XmlNode[];
  onEdit?: EditAttr;
  query?: string;
}) {
  const q = query.trim().toLowerCase();
  // When searching, compute which nodes match and which are on a match's path.
  const search = useMemo(
    () => (q ? computeMatches(nodes, q) : null),
    [nodes, q]
  );

  if (search && search.visible.size === 0) {
    return (
      <div className="p-4 text-sm text-muted-foreground">
        No matches for “{query}”.
      </div>
    );
  }

  return (
    <div className="font-mono text-xs leading-relaxed">
      {nodes.map((node, i) => (
        <TreeNode
          key={i}
          node={node}
          path={[i]}
          depth={0}
          defaultOpen={i === 0}
          onEdit={onEdit}
          query={q}
          search={search}
        />
      ))}
    </div>
  );
}

interface SearchInfo {
  matched: Set<XmlNode>;
  visible: Set<XmlNode>;
}

/** Build the set of matching nodes and their ancestors for a query. */
function computeMatches(nodes: XmlNode[], q: string): SearchInfo {
  const matched = new Set<XmlNode>();
  const visible = new Set<XmlNode>();

  const visit = (node: XmlNode): boolean => {
    if (isTextNode(node)) {
      return nodeText(node).toLowerCase().includes(q);
    }
    const tag = nodeTag(node);
    const attrs = nodeAttributes(node);
    const selfMatch =
      tag.toLowerCase().includes(q) ||
      Object.entries(attrs).some(
        ([k, v]) =>
          k.toLowerCase().includes(q) || String(v).toLowerCase().includes(q)
      );
    if (selfMatch) matched.add(node);

    let childMatch = false;
    for (const child of nodeChildren(node)) {
      if (visit(child)) childMatch = true;
    }

    const isVisible = selfMatch || childMatch;
    if (isVisible) visible.add(node);
    return isVisible;
  };

  for (const node of nodes) visit(node);
  return { matched, visible };
}

const INDENT = 12;

const TreeNode = memo(function TreeNode({
  node,
  path,
  depth,
  defaultOpen = false,
  onEdit,
  query,
  search,
}: {
  node: XmlNode;
  path: NodePath;
  depth: number;
  defaultOpen?: boolean;
  onEdit?: EditAttr;
  query: string;
  search: SearchInfo | null;
}) {
  const [manualOpen, setManualOpen] = useState(defaultOpen);

  if (isTextNode(node)) {
    const text = nodeText(node);
    if (text.trim() === "") return null;
    return (
      <Row depth={depth}>
        <span className="text-emerald-600 dark:text-emerald-400">
          <Highlight text={text} query={query} />
        </span>
      </Row>
    );
  }

  // Hide nodes filtered out by search.
  if (search && !search.visible.has(node)) return null;

  const tag = nodeTag(node);
  const attrs = nodeAttributes(node);
  const attrEntries = Object.entries(attrs);
  // Iterate the real child array so paths keep their true indices; render only
  // non-empty (and, while searching, visible) children.
  const allChildren = nodeChildren(node);
  const renderable = allChildren
    .map((child, realIndex) => ({ child, realIndex }))
    .filter(
      ({ child }) =>
        !(isTextNode(child) && nodeText(child).trim() === "") &&
        (!search || search.visible.has(child))
    );
  const hasChildren = renderable.length > 0;
  // Force-open while searching so matches deep in the tree are revealed.
  const open = search ? true : manualOpen;

  return (
    <div>
      <Row
        depth={depth}
        onClick={hasChildren && !search ? () => setManualOpen((o) => !o) : undefined}
        clickable={hasChildren && !search}
      >
        <ChevronRight
          className={cn(
            "size-3 shrink-0 text-muted-foreground transition-transform",
            open && "rotate-90",
            !hasChildren && "invisible"
          )}
        />
        <span className="text-sky-700 dark:text-sky-300">
          <Highlight text={tag} query={query} />
        </span>
        {attrEntries.map(([k, v]) => (
          <Attr
            key={k}
            path={path}
            name={k}
            value={String(v)}
            query={query}
            onEdit={onEdit}
          />
        ))}
        {!hasChildren && attrEntries.length === 0 && (
          <span className="text-muted-foreground">{"(empty)"}</span>
        )}
      </Row>

      {hasChildren && open && (
        <div>
          {renderable.map(({ child, realIndex }) => (
            <TreeNode
              key={realIndex}
              node={child}
              path={[...path, tag, realIndex]}
              depth={depth + 1}
              onEdit={onEdit}
              query={query}
              search={search}
            />
          ))}
        </div>
      )}
    </div>
  );
});

/** A single `name="value"` attribute, with an editable value when enabled. */
function Attr({
  path,
  name,
  value,
  query,
  onEdit,
}: {
  path: NodePath;
  name: string;
  value: string;
  query: string;
  onEdit?: EditAttr;
}) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(value);

  const commit = () => {
    setEditing(false);
    if (draft !== value) onEdit?.(path, name, draft);
  };

  return (
    <span className="whitespace-nowrap">
      <span className="text-muted-foreground"> {name}</span>
      <span className="text-muted-foreground">=</span>
      {editing ? (
        <input
          autoFocus
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          onBlur={commit}
          onClick={(e) => e.stopPropagation()}
          onKeyDown={(e) => {
            if (e.key === "Enter") commit();
            if (e.key === "Escape") {
              setDraft(value);
              setEditing(false);
            }
          }}
          size={Math.max(draft.length, 1)}
          className="rounded bg-amber-500/10 px-0.5 text-amber-700 outline outline-amber-500/50 dark:text-amber-300"
        />
      ) : (
        <span
          onClick={
            onEdit
              ? (e) => {
                  e.stopPropagation();
                  setDraft(value);
                  setEditing(true);
                }
              : undefined
          }
          className={cn(
            "text-amber-700 dark:text-amber-400",
            onEdit && "cursor-text rounded hover:bg-amber-500/15"
          )}
        >
          "<Highlight text={value} query={query} />"
        </span>
      )}
    </span>
  );
}

/** Render `text`, highlighting case-insensitive occurrences of `query`. */
function Highlight({ text, query }: { text: string; query: string }) {
  if (!query) return <>{text}</>;
  const lower = text.toLowerCase();
  const idx = lower.indexOf(query);
  if (idx === -1) return <>{text}</>;
  return (
    <>
      {text.slice(0, idx)}
      <mark className="rounded bg-yellow-300/70 text-inherit dark:bg-yellow-500/40">
        {text.slice(idx, idx + query.length)}
      </mark>
      {text.slice(idx + query.length)}
    </>
  );
}

function Row({
  depth,
  children,
  onClick,
  clickable,
}: {
  depth: number;
  children: React.ReactNode;
  onClick?: () => void;
  clickable?: boolean;
}) {
  return (
    <div
      onClick={onClick}
      style={{ paddingLeft: depth * INDENT + 4 }}
      className={cn(
        "flex items-center gap-1 rounded px-1 py-px hover:bg-muted/60",
        clickable && "cursor-pointer"
      )}
    >
      {children}
    </div>
  );
}
