#!/bin/sh
# Installs the MF4 Viewer bundle this script sits in for desktop use:
# the app itself, a `mf4-viewer` launcher on PATH, the icon theme entries and
# a .desktop file, so it shows up in the application menu.
#
#   ./install.sh [PREFIX]        # PREFIX defaults to ~/.local
#   sudo ./install.sh /usr/local # system-wide
#
# Undo it with the uninstall.sh next to this script (same PREFIX).
set -eu

APP_ID=com.mf4viewer.mf4_viewer
bundle=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
prefix=${1:-$HOME/.local}
target=$prefix/lib/mf4-viewer

if [ ! -x "$bundle/mf4_viewer" ]; then
    echo "install.sh must be run from the extracted MF4 Viewer bundle" >&2
    exit 1
fi

echo "Installing MF4 Viewer into $prefix"

if [ "$bundle" != "$target" ]; then
    rm -rf "$target"
    mkdir -p "$target"
    cp -a "$bundle/." "$target/"
fi

mkdir -p "$prefix/bin" "$prefix/share/applications" "$prefix/share/icons/hicolor"
ln -sfn "$target/mf4_viewer" "$prefix/bin/mf4-viewer"
cp -r "$target/data/icons/hicolor/." "$prefix/share/icons/hicolor/"

# Absolute Exec path, so the launcher also works when PREFIX/bin is not on the
# session's PATH (a common surprise with ~/.local/bin).
sed "s|^Exec=.*|Exec=$target/mf4_viewer|" \
    "$target/data/$APP_ID.desktop" > "$prefix/share/applications/$APP_ID.desktop"

# Best effort cache refresh; both tools are optional.
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$prefix/share/applications" || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t "$prefix/share/icons/hicolor" >/dev/null 2>&1 || true
fi

echo "Done. Start it from the application menu or run: $prefix/bin/mf4-viewer"
case ":${PATH}:" in
    *":$prefix/bin:"*) ;;
    *) echo "Note: $prefix/bin is not on your PATH." ;;
esac
echo "Uninstall with: $target/uninstall.sh $prefix"
