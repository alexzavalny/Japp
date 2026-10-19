#!/bin/bash
# Installs JApp Runtime and the `japp` command, and registers .japp files with macOS.
#
#   Scripts/install.sh                 install to /Applications (or ~/Applications)
#   Scripts/install.sh ~/Applications  install somewhere specific
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/build/JApp Runtime.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

[ -d "$SOURCE" ] || "$ROOT/Scripts/build.sh"

DEST_DIR="${1:-}"
if [ -z "$DEST_DIR" ]; then
    if [ -w /Applications ]; then DEST_DIR=/Applications; else DEST_DIR="$HOME/Applications"; fi
fi
mkdir -p "$DEST_DIR"
DEST="$DEST_DIR/JApp Runtime.app"

# Quit running copies so the new version is used: JApp Runtime and the apps
# running through their app bundles (~/Library/Application Support/JApp/AppBundles).
APP_BUNDLES="/JApp/AppBundles/.*\.app/Contents/MacOS/"
if pgrep -x JAppRuntime >/dev/null || pgrep -f "$APP_BUNDLES" >/dev/null; then
    echo "==> Quitting running JApp apps"
    pkill -x JAppRuntime || true
    pkill -f "$APP_BUNDLES" || true
    sleep 1
fi

echo "==> Installing $DEST"
rm -rf "$DEST"
ditto "$SOURCE" "$DEST"

echo "==> Registering .japp with Launch Services"
"$LSREGISTER" -u "$SOURCE" >/dev/null 2>&1 || true   # the build copy must not compete
"$LSREGISTER" -f -R -trusted "$DEST"
/System/Library/CoreServices/pbs -update >/dev/null 2>&1 || true   # refresh Services ("Edit JApp Source")

echo "==> Installing the japp command"
if [ -w /usr/local/bin ]; then BIN_DIR=/usr/local/bin; else BIN_DIR="$HOME/.local/bin"; mkdir -p "$BIN_DIR"; fi
ln -sf "$DEST/Contents/Helpers/japp" "$BIN_DIR/japp"
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo "    note: add $BIN_DIR to your PATH" ;;
esac

echo
echo "Installed JApp Runtime $(defaults read "$DEST/Contents/Info" CFBundleShortVersionString)."
echo "  Each app gets its own small app bundle the first time it runs (japp bundles)."
echo "  For a Mac without JApp: japp export App.japp (a standalone App.app, the runtime inside)."
echo "  Try:  open \"$ROOT/build/Calculator.japp\""
echo "        japp help"
