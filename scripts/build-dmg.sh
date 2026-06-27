#!/usr/bin/env bash
#
# build-dmg.sh — Build Lyripeek.app and package it as a drag-to-Applications DMG.
#
# Uses only stock macOS tools: xcodebuild, hdiutil, osascript, ditto.
# No Homebrew, npm, or Python dependencies required.
#

set -euo pipefail

# --- Resolve paths --------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# --- Config ---------------------------------------------------------------
APP_NAME="Lyripeek"
SCHEME="Lyripeek"
PROJECT="Lyripeek.xcodeproj"
CONFIGURATION="Release"
DERIVED_DATA="$PROJECT_ROOT/build/derived"
STAGING_DIR="$PROJECT_ROOT/build/dmg-staging"
RW_DMG="$PROJECT_ROOT/build/lyripeek-rw.dmg"
DIST_DIR="$PROJECT_ROOT/dist"
VOL_NAME="Lyripeek"
MOUNT_POINT="/Volumes/$VOL_NAME"

# Finder window layout
DMG_WINDOW_X=140
DMG_WINDOW_Y=140
DMG_WINDOW_WIDTH=420
DMG_WINDOW_HEIGHT=300
APP_ICON_POS_X=120
APP_ICON_POS_Y=120
APPS_ICON_POS_X=300
APPS_ICON_POS_Y=120
ICON_SIZE=64

# --- Helpers --------------------------------------------------------------
cleanup() {
  for mp in $(mount | awk -v vol="$VOL_NAME" '$3 ~ "^/Volumes/" vol {print $3}'); do
    hdiutil detach "$mp" 2>/dev/null || true
  done
  rm -rf "$STAGING_DIR" 2>/dev/null || true
  rm -f "$RW_DMG" 2>/dev/null || true
}
trap cleanup EXIT

# Pre-detach any stale Lyripeek volumes left from a previous run
cleanup

log() { printf "\033[1;34m==> %s\033[0m\n" "$*"; }
fail() { printf "\033[1;31m!! %s\033[0m\n" "$*" >&2; exit 1; }

# --- 1. Resolve MARKETING_VERSION ----------------------------------------
log "Resolving MARKETING_VERSION from $PROJECT"
VERSION=$(xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/^[[:space:]]+MARKETING_VERSION[[:space:]]*= / {print $2; exit}')

[[ -n "$VERSION" ]] || fail "Could not determine MARKETING_VERSION"
log "Version: $VERSION"

# --- 2. Build the .app (unsigned, matching the project's current state) ---
log "Building $APP_NAME ($CONFIGURATION, unsigned)"
mkdir -p "$DERIVED_DATA"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build >/dev/null

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
[[ -d "$APP_PATH" ]] || fail "Build did not produce $APP_PATH"
log "Built: $APP_PATH"

# --- 3. Stage the DMG root ------------------------------------------------
log "Staging DMG contents"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR/$VOL_NAME"
ditto "$APP_PATH" "$STAGING_DIR/$VOL_NAME/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/$VOL_NAME/Applications"

# --- 4. Create writable DMG ----------------------------------------------
log "Creating writable DMG"
mkdir -p "$PROJECT_ROOT/build"
rm -f "$RW_DMG"
hdiutil create \
  -srcfolder "$STAGING_DIR/$VOL_NAME" \
  -volname "$VOL_NAME" \
  -fs HFS+ \
  -fsargs "-c c=64,a=16,e=16" \
  -format UDRW \
  -size 50m \
  "$RW_DMG"

# --- 5. Mount and apply Finder window layout -----------------------------
log "Mounting writable DMG and applying Finder layout"
hdiutil attach "$RW_DMG" \
  -nobrowse \
  -noautoopen \
  -readwrite

# Give Finder a moment to register the mounted volume
sleep 2

osascript <<EOF
tell application "Finder"
  tell disk "$VOL_NAME"
    open
    delay 1
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {$DMG_WINDOW_X, $DMG_WINDOW_Y, $((DMG_WINDOW_X + DMG_WINDOW_WIDTH)), $((DMG_WINDOW_Y + DMG_WINDOW_HEIGHT))}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to $ICON_SIZE
    set position of item "$APP_NAME.app" of container window to {$APP_ICON_POS_X, $APP_ICON_POS_Y}
    set position of item "Applications" of container window to {$APPS_ICON_POS_X, $APPS_ICON_POS_Y}
    update without registering applications
    close
  end tell
end tell
EOF

sync

log "Detaching writable DMG"
hdiutil detach "$MOUNT_POINT" 2>/dev/null || hdiutil detach -force "$MOUNT_POINT" 2>/dev/null || true

# --- 6. Convert to compressed read-only DMG ------------------------------
log "Converting to compressed read-only DMG (UDZO)"
mkdir -p "$DIST_DIR"
OUTPUT_DMG="$DIST_DIR/${APP_NAME}-${VERSION}.dmg"
rm -f "$OUTPUT_DMG"
hdiutil convert "$RW_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$OUTPUT_DMG"

# --- 7. Verify ------------------------------------------------------------
log "Verifying DMG integrity"
hdiutil verify "$OUTPUT_DMG"

log "Done"
echo
echo "Output: $OUTPUT_DMG"
ls -lh "$OUTPUT_DMG"
