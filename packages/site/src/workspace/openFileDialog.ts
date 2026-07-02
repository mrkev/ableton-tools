/**
 * Open a native file picker and resolve with the chosen files. Uses a transient
 * <input type="file"> so it works across all browsers (no File System Access
 * API requirement).
 */
export function openFileDialog(options?: {
  accept?: string;
  multiple?: boolean;
}): Promise<File[]> {
  const { accept = "", multiple = true } = options ?? {};

  return new Promise((resolve) => {
    const input = document.createElement("input");
    input.type = "file";
    input.accept = accept;
    input.multiple = multiple;
    input.style.display = "none";

    // `change` fires on selection; if the user cancels nothing fires, so we
    // also clean up on window focus as a fallback.
    const cleanup = () => {
      window.removeEventListener("focus", onFocus);
      input.remove();
    };

    const onFocus = () => {
      // Defer: the `change` event (if any) lands right after focus returns.
      setTimeout(() => {
        if (input.files == null || input.files.length === 0) {
          cleanup();
          resolve([]);
        }
      }, 300);
    };

    input.addEventListener(
      "change",
      () => {
        const files = input.files ? Array.from(input.files) : [];
        cleanup();
        resolve(files);
      },
      { once: true }
    );

    window.addEventListener("focus", onFocus);
    document.body.appendChild(input);
    input.click();
  });
}
