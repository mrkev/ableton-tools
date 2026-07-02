import { useCallback, useRef, useState, type DragEvent } from "react";

/**
 * Window-level drag & drop for `.als` files. Returns a `dragging` flag for the
 * drop overlay and handlers to spread onto a container element.
 */
export function useDropFiles(onFile: (file: File) => void) {
  const [dragging, setDragging] = useState(false);
  // Track nested dragenter/leave so the overlay doesn't flicker over children.
  const depth = useRef(0);

  const onDragEnter = useCallback((e: DragEvent) => {
    if (!e.dataTransfer?.types.includes("Files")) return;
    e.preventDefault();
    depth.current += 1;
    setDragging(true);
  }, []);

  const onDragOver = useCallback((e: DragEvent) => {
    if (e.dataTransfer?.types.includes("Files")) e.preventDefault();
  }, []);

  const onDragLeave = useCallback((e: DragEvent) => {
    e.preventDefault();
    depth.current -= 1;
    if (depth.current <= 0) {
      depth.current = 0;
      setDragging(false);
    }
  }, []);

  const onDrop = useCallback(
    (e: DragEvent) => {
      e.preventDefault();
      depth.current = 0;
      setDragging(false);
      const files = e.dataTransfer ? Array.from(e.dataTransfer.files) : [];
      for (const file of files) {
        if (file.name.toLowerCase().endsWith(".als")) onFile(file);
      }
    },
    [onFile]
  );

  return {
    dragging,
    handlers: { onDragEnter, onDragOver, onDragLeave, onDrop },
  };
}
