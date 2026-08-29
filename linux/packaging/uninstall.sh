#!/bin/sh
# Removes an MF4 Viewer installation made by install.sh.
#
#   ./uninstall.sh [PREFIX]      # PREFIX defaults to ~/.local
set -eu

APP_ID=com.mf4viewer.mf4_viewer
prefix=${1:-$HOME/.local}
target=$prefix/lib/mf4-viewer

echo "Removing MF4 Viewer from $prefix"

rm -f "$prefix/bin/mf4-viewer"
rm -f "$prefix/share/applications/$APP_ID.desktop"
if [ -d "$prefix/share/icons/hicolor" ]; then
    find "$prefix/share/icons/hicolor" -name "$APP_ID.png" -type f -delete
fi
rm -rf "$target"

# Best effort cache refresh, so the removed entries disappear right away. The
# shared hicolor directory itself stays: other applications may use it.
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$prefix/share/applications" || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1 &&
   [ -d "$prefix/share/icons/hicolor" ]; then
    gtk-update-icon-cache -f -t "$prefix/share/icons/hicolor" >/dev/null 2>&1 || true
fi

echo "Done."
