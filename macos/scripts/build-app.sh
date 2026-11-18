#!/bin/bash
set -euo pipefail

# Build the native Egress Atlas app. SwiftPM produces the executable; this
# script assembles the .app, copies the Metal resource bundle, renders the
# icon from the bundled SVG master, and ad-hoc signs the result.
#
#   ./scripts/build-app.sh            production
#   ./scripts/build-app.sh --debug    debug build

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="release"
if [[ "${1:-}" == "--debug" ]]; then CONFIG="debug"; fi

SWIFT_FLAGS=(--disable-sandbox --cache-path .build/spm-cache --config-path .build/spm-config)

ICON_SOURCE="$ROOT/Sources/EgressAtlas/Resources/brand-app-icon.svg"
if [[ ! -f "$ICON_SOURCE" ]]; then
  echo "error: app icon master not found at $ICON_SOURCE" >&2
  exit 1
fi

WORKBENCH_LOGO="$ROOT/../docs/assets/workbench-logo.svg"
RUNTIME_WORKBENCH="$ROOT/Sources/EgressAtlas/Resources/brand-workbench.svg"
if [[ ! -f "$WORKBENCH_LOGO" ]]; then
  echo "error: workbench lockup not found at $WORKBENCH_LOGO" >&2
  exit 1
fi
if [[ ! -f "$RUNTIME_WORKBENCH" ]]; then
  echo "error: runtime workbench lockup not found at $RUNTIME_WORKBENCH" >&2
  exit 1
fi
if ! cmp -s "$WORKBENCH_LOGO" "$RUNTIME_WORKBENCH"; then
  echo "error: the runtime workbench lockup is out of sync with docs/assets" >&2
  echo "       cp \"$WORKBENCH_LOGO\" \"$RUNTIME_WORKBENCH\"" >&2
  exit 1
fi

echo "▸ building ($CONFIG)"
swift build -c "$CONFIG" "${SWIFT_FLAGS[@]}"

BIN="$ROOT/.build/out/Products/$(echo "$CONFIG" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')/EgressAtlas"
if [[ ! -x "$BIN" ]]; then
  if [[ -x "$ROOT/.build/$CONFIG/EgressAtlas" ]]; then BIN="$ROOT/.build/$CONFIG/EgressAtlas"; else
    echo "error: built binary not found" >&2; exit 1
  fi
fi
RES_BUNDLE="$(dirname "$BIN")/EgressAtlas_EgressAtlas.bundle"

# A debug build must never overwrite the release deliverable: an -Onone
# binary is several times slower in the simulation/layout hot paths and looks
# like a performance regression once it is launched from dist/.
if [[ "$CONFIG" == "debug" ]]; then
  APP="$ROOT/dist/Egress Atlas Debug.app"
else
  APP="$ROOT/dist/Egress Atlas.app"
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/EgressAtlas"
chmod 755 "$APP/Contents/MacOS/EgressAtlas"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [[ "$CONFIG" == "debug" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Egress Atlas Debug" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName Egress Atlas Debug" "$APP/Contents/Info.plist"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [[ -d "$RES_BUNDLE" ]]; then
  cp -R "$RES_BUNDLE" "$APP/Contents/Resources/"
else
  echo "error: resource bundle not found at $RES_BUNDLE" >&2
  exit 1
fi

echo "▸ generating icon"
ICONSET="$ROOT/.build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
ATLAS_ICON_SOURCE="$ICON_SOURCE" "$APP/Contents/MacOS/EgressAtlas" --make-icon "$ICONSET" >/dev/null
if ! command -v iconutil >/dev/null 2>&1; then
  echo "error: iconutil not found; cannot build the official app icon" >&2
  exit 1
fi
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
if [[ ! -s "$APP/Contents/Resources/AppIcon.icns" ]]; then
  echo "error: AppIcon.icns was not written" >&2
  exit 1
fi

# Prefer an explicitly requested identity, then a local self-signed identity.
IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "Egress Atlas Local"; then
    IDENTITY="Egress Atlas Local"
  else
    IDENTITY="-"
  fi
fi
echo "▸ signing as: $IDENTITY"
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - "$APP"
else
  codesign --force --deep --options runtime --sign "$IDENTITY" "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"

echo ""
echo "✓ $APP"
echo "  open \"$APP\""
echo ""
if [[ "$CONFIG" == "debug" ]]; then
  echo "⚠  DEBUG build (-Onone): do not ship or benchmark this bundle."
  echo "   The release app is built without --debug."
  echo ""
fi
echo "Local build, ad-hoc signed. If macOS quarantines it after moving it"
echo "between machines: xattr -dr com.apple.quarantine \"$APP\""
