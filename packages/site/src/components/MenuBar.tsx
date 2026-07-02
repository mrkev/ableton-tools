import {
  Menubar,
  MenubarContent,
  MenubarItem,
  MenubarMenu,
  MenubarSeparator,
  MenubarShortcut,
  MenubarTrigger,
} from "@/components/ui/menubar";
import { useWorkspace } from "@/workspace/WorkspaceContext";
import { useTheme } from "@/workspace/useTheme";
import { Apple, Moon, Sun } from "lucide-react";
import { useEffect, useState } from "react";
import { AboutDialog, APP_NAME } from "./AboutDialog";

/**
 * A macOS-style menu bar pinned to the top of the window. Mimics the menu bar
 * of a native "ableton-tools" app: an Apple glyph, a bold application menu, and
 * the standard File / Edit / View / Help menus.
 */
export function MenuBar() {
  const {
    openFiles,
    active,
    closeDocument,
    saveDocument,
    isDirty,
    undo,
    redo,
    canUndo,
    canRedo,
  } = useWorkspace();
  const { theme, toggle: toggleTheme } = useTheme();
  const [aboutOpen, setAboutOpen] = useState(false);

  // Global keyboard shortcuts matching the menu items.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const mod = e.metaKey || e.ctrlKey;
      if (!mod) return;
      const key = e.key.toLowerCase();
      // Let the browser handle text editing inside inputs/textareas.
      const target = e.target as HTMLElement | null;
      const typing =
        target?.tagName === "INPUT" || target?.tagName === "TEXTAREA";

      if (key === "o") {
        e.preventDefault();
        void openFiles();
      } else if (key === "s" && active) {
        e.preventDefault();
        void saveDocument(active.id);
      } else if (key === "w" && active) {
        e.preventDefault();
        closeDocument(active.id);
      } else if (key === "z" && active && !typing) {
        e.preventDefault();
        if (e.shiftKey) redo(active.id);
        else undo(active.id);
      } else if (key === "y" && active && !typing) {
        e.preventDefault();
        redo(active.id);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [openFiles, active, closeDocument, saveDocument, undo, redo]);

  return (
    <>
      <div className="flex h-7 shrink-0 items-center gap-2 border-b bg-background/80 px-2 backdrop-blur select-none">
        <Apple className="size-4 fill-foreground" />

        <Menubar className="h-7 gap-0 rounded-none border-0 bg-transparent p-0">
          {/* Application menu */}
          <MenubarMenu>
            <MenubarTrigger className="px-2 font-semibold">
              {APP_NAME}
            </MenubarTrigger>
            <MenubarContent>
              <MenubarItem onClick={() => setAboutOpen(true)}>
                About {APP_NAME}
              </MenubarItem>
              <MenubarSeparator />
              <MenubarItem disabled>
                Settings…
                <MenubarShortcut>⌘,</MenubarShortcut>
              </MenubarItem>
            </MenubarContent>
          </MenubarMenu>

          {/* File menu */}
          <MenubarMenu>
            <MenubarTrigger className="px-2">File</MenubarTrigger>
            <MenubarContent>
              <MenubarItem onClick={() => void openFiles()}>
                Open…
                <MenubarShortcut>⌘O</MenubarShortcut>
              </MenubarItem>
              <MenubarSeparator />
              <MenubarItem
                disabled={!active || active.status !== "ready"}
                onClick={() => active && void saveDocument(active.id)}
              >
                {active && isDirty(active.id) ? "Save (Export)…" : "Export…"}
                <MenubarShortcut>⌘S</MenubarShortcut>
              </MenubarItem>
              <MenubarSeparator />
              <MenubarItem
                disabled={!active}
                onClick={() => active && closeDocument(active.id)}
              >
                Close Tab
                <MenubarShortcut>⌘W</MenubarShortcut>
              </MenubarItem>
            </MenubarContent>
          </MenubarMenu>

          {/* Edit menu */}
          <MenubarMenu>
            <MenubarTrigger className="px-2">Edit</MenubarTrigger>
            <MenubarContent>
              <MenubarItem
                disabled={!active || !canUndo(active.id)}
                onClick={() => active && undo(active.id)}
              >
                Undo
                <MenubarShortcut>⌘Z</MenubarShortcut>
              </MenubarItem>
              <MenubarItem
                disabled={!active || !canRedo(active.id)}
                onClick={() => active && redo(active.id)}
              >
                Redo
                <MenubarShortcut>⇧⌘Z</MenubarShortcut>
              </MenubarItem>
            </MenubarContent>
          </MenubarMenu>

          {/* View menu */}
          <MenubarMenu>
            <MenubarTrigger className="px-2">View</MenubarTrigger>
            <MenubarContent>
              <MenubarItem onClick={toggleTheme}>
                {theme === "dark" ? "Light Appearance" : "Dark Appearance"}
              </MenubarItem>
            </MenubarContent>
          </MenubarMenu>

          {/* Help menu */}
          <MenubarMenu>
            <MenubarTrigger className="px-2">Help</MenubarTrigger>
            <MenubarContent>
              <MenubarItem onClick={() => setAboutOpen(true)}>
                About {APP_NAME}
              </MenubarItem>
            </MenubarContent>
          </MenubarMenu>
        </Menubar>

        {/* Right-aligned status area, like macOS menu extras. */}
        <div className="ml-auto flex items-center gap-1 pr-1">
          <button
            type="button"
            aria-label="Toggle appearance"
            onClick={toggleTheme}
            className="flex size-6 items-center justify-center rounded hover:bg-muted"
          >
            {theme === "dark" ? (
              <Sun className="size-3.5" />
            ) : (
              <Moon className="size-3.5" />
            )}
          </button>
        </div>
      </div>

      <AboutDialog open={aboutOpen} onOpenChange={setAboutOpen} />
    </>
  );
}
