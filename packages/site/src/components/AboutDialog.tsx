import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { AudioWaveform } from "lucide-react";

export const APP_NAME = "ableton-tools";
export const APP_VERSION = "0.1.0";

export function AboutDialog({
  open,
  onOpenChange,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-sm">
        <DialogHeader className="items-center text-center">
          <div className="mb-2 flex size-16 items-center justify-center rounded-2xl bg-gradient-to-br from-zinc-700 to-zinc-900 text-white shadow-inner">
            <AudioWaveform className="size-8" />
          </div>
          <DialogTitle>{APP_NAME}</DialogTitle>
          <DialogDescription>
            Inspect, explore, and edit Ableton Live Set (.als) files.
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-1 text-center text-sm text-muted-foreground">
          <p>Version {APP_VERSION}</p>
          <p>
            <a
              className="underline underline-offset-2 hover:text-foreground"
              href="https://github.com/mrkev/ableton-tools"
              target="_blank"
              rel="noreferrer"
            >
              github.com/mrkev/ableton-tools
            </a>
          </p>
          <p className="pt-2 text-xs">
            Not affiliated with Ableton. “Ableton” and “Live” are trademarks of
            Ableton AG.
          </p>
        </div>

        <DialogFooter className="sm:justify-center">
          <Button variant="secondary" onClick={() => onOpenChange(false)}>
            Close
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
