# ableton-tools

## Git

Kevin and Claude are the only ones working here. Commit straight to `main` and push
to `origin main` when a task is done (built and checked), without asking. Never
create a branch, and if you find yourself on one, stop and say so.

## packages/project-manager

A native macOS (SwiftUI) app, built with Swift Package Manager. See its README.

- Build: `swift build` in `packages/project-manager`; `./make-app.sh --install`
  builds the .app.
- Check: `--selftest-library <Projects folder>` scans a library and compares the
  fast scanner with the DOM extractor; `--selftest-plan <set.als>` prints what
  fixing a set would do.
- Never write converted sets into `~/Music/Projects` (Kevin's real library). Test
  output goes to a temporary folder.
