#!/bin/zsh
# Builds "Ableton Project Manager.app" from the Swift package.
#
#     ./make-app.sh            # → build/Ableton Project Manager.app
#     ./make-app.sh --install  # also copies it to ~/Applications
#
# The package stays the source of truth; this only wraps the release binary in a
# bundle (Info.plist, icon) and signs it ad hoc for this Mac. The command-line modes
# keep working through the binary inside it:
#
#     "build/Ableton Project Manager.app/Contents/MacOS/ProjectManager" --batch …
#
# It isn't sandboxed and has no hardened runtime: it loads third-party plugins and
# reads your whole library. Sharing it with other Macs would need a Developer ID
# signature and notarization.
set -euo pipefail
cd "${0:A:h}"

name="Ableton Project Manager"
app="build/$name.app"
version="0.1"
build_number=$(git rev-list --count HEAD 2>/dev/null || echo 1)
commit=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)

swift build -c release
bin=$(swift build -c release --show-bin-path)/ProjectManager

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/ProjectManager"
cp App/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

# Folders are "Alternate": the app shows under Open With and takes drops on its
# Dock icon, but double-clicking a folder still opens Finder.
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleDisplayName</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>dev.ableton-tools.project-manager</string>
  <key>CFBundleExecutable</key><string>ProjectManager</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build_number</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHumanReadableCopyright</key><string>Built from $commit</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Folder</string>
      <key>LSItemContentTypes</key><array><string>public.folder</string></array>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
    </dict>
  </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$app"
echo "built $app ($version, build $build_number, $commit)"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/"$name.app"
  cp -R "$app" ~/Applications/
  echo "installed ~/Applications/$name.app"
fi
