#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
#  iMonitor – Build, Sign & Package Script
#
#  Usage:
#    ./build.sh                  # Build Release .app
#    ./build.sh --dmg            # Build Release .app + package as DMG
#    ./build.sh --ci             # CI mode: build + dmg
#    ./build.sh --clean          # Remove all build artefacts
#    ./build.sh --help           # Show this help
#
#  Environment variables (optional):
#    SIGN_IDENTITY     Code-sign identity (default: "-" for ad-hoc)
#    MARKETING_VERSION Override version string
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Configuration ────────────────────────────────────────────────────────────
APP_NAME="iMonitor"
BUNDLE_ID="com.aresnasa.iMonitor"
MIN_MACOS="11.0"

# ── Paths ────────────────────────────────────────────────────────────────────
BUILD_DIR="./build"
DIST_DIR="./dist"
APP_BUNDLE="${BUILD_DIR}/Release/${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
ENTITLEMENTS_ADHOC="./iMonitor/iMonitor-adhoc.entitlements"

PROJECT_FILE="${SCRIPT_DIR}/iMonitor.xcodeproj"
SCHEME="iMonitor"

# ── Colours ──────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m'
    BLUE='\033[0;34m' BOLD='\033[1m' DIM='\033[2m' RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' DIM='' RESET=''
fi

step()    { echo -e "\n${BLUE}${BOLD}▸ $1${RESET}"; }
success() { echo -e "  ${GREEN}✅ $1${RESET}"; }
warn()    { echo -e "  ${YELLOW}⚠️  $1${RESET}"; }
fail()    { echo -e "  ${RED}❌ $1${RESET}"; exit 1; }
info()    { echo -e "  ${DIM}$1${RESET}"; }

# ── Defaults ─────────────────────────────────────────────────────────────────
SIGN_ID="${SIGN_IDENTITY:--}"
MAKE_DMG=false
CLEAN=false

for arg in "$@"; do
    case "$arg" in
        --dmg)  MAKE_DMG=true ;;
        --ci)   MAKE_DMG=true ;;
        --clean) CLEAN=true ;;
        --help|-h)
            echo "Usage: $0 [--dmg] [--ci] [--clean] [--help]"
            echo ""
            echo "  --dmg    Build and package as DMG"
            echo "  --ci     CI mode (build + DMG)"
            echo "  --clean  Remove build artefacts"
            exit 0
            ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

if $CLEAN; then
    step "Cleaning build artefacts"
    rm -rf "$BUILD_DIR" "$DIST_DIR"
    success "Cleaned"
    exit 0
fi

# ── Version ──────────────────────────────────────────────────────────────────
if [ -n "${MARKETING_VERSION:-}" ]; then
    VERSION="$MARKETING_VERSION"
else
    VERSION=$(grep 'MARKETING_VERSION' project.yml | awk '{print $2}' | tr -d '"')
fi

# ── Step 1: Build via xcodebuild (unsigned) ─────────────────────────────────
step "Building ${APP_NAME} v${VERSION} (Universal Binary)"

# Regenerate Xcode project
xcodegen generate 2>&1 | tail -1

# Build WITHOUT code signing (we'll sign manually)
xcodebuild -project "${PROJECT_FILE}" -scheme "${SCHEME}" \
    -configuration Release \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    ENABLE_HARDENED_RUNTIME=NO \
    SYMROOT="$BUILD_DIR" \
    | tail -5

# Verify universal binary
BINARY="${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
if [ ! -f "$BINARY" ]; then
    fail "Binary not found: $BINARY"
fi
ARCHS=$(lipo -archs "$BINARY")
info "Architecture: ${ARCHS}"
if [[ "$ARCHS" != *"arm64"* ]] || [[ "$ARCHS" != *"x86_64"* ]]; then
    fail "Binary is not universal (expected arm64 + x86_64)"
fi
success "Universal binary built"

# ── Step 2: Code sign manually ──────────────────────────────────────────────
step "Code signing"

if [ "$SIGN_ID" = "-" ]; then
    # Ad-hoc: no Hardened Runtime, no timestamp, NO entitlements.
    # macOS 26 AMFI rejects: adhoc + any entitlements + --options runtime.
    # Even network.client with ad-hoc is rejected on some machines.
    # iMonitor doesn't need entitlements: nettop is a subprocess, not in-process.
    ACTIVE_ENTITLEMENTS=""
    info "Mode: ad-hoc (no Hardened Runtime, no entitlements)"
else
    # Developer ID: full Hardened Runtime + secure timestamp for notarisation.
    ACTIVE_ENTITLEMENTS="$ENTITLEMENTS_ADHOC"
    info "Mode: Developer ID (Hardened Runtime)"
fi

# Copy ad-hoc entitlements into app bundle Resources (for Cask postflight re-signing)
if [ -f "$ENTITLEMENTS_ADHOC" ]; then
    cp "$ENTITLEMENTS_ADHOC" "${RESOURCES_DIR}/"
    info "Copied ad-hoc entitlements into app bundle"
fi

# Sign nested bundles first (frameworks, dylibs)
NESTED_COUNT=0
while IFS= read -r -d '' nested; do
    codesign --force --sign "$SIGN_ID" \
        --timestamp=none \
        "$nested" 2>/dev/null && NESTED_COUNT=$((NESTED_COUNT + 1)) || true
done < <(find "${CONTENTS_DIR}" -name '*.framework' -print0 2>/dev/null)

while IFS= read -r -d '' nested; do
    if [ -f "${nested}/Info.plist" ]; then
        codesign --force --sign "$SIGN_ID" \
            --timestamp=none \
            "$nested" 2>/dev/null && NESTED_COUNT=$((NESTED_COUNT + 1)) || true
    fi
done < <(find "${CONTENTS_DIR}" -name '*.bundle' -print0 2>/dev/null)

while IFS= read -r -d '' nested; do
    codesign --force --sign "$SIGN_ID" \
        --timestamp=none \
        "$nested" 2>/dev/null && NESTED_COUNT=$((NESTED_COUNT + 1)) || true
done < <(find "${CONTENTS_DIR}" -name '*.dylib' -print0 2>/dev/null)

info "Signed ${NESTED_COUNT} nested bundle(s)"

# Sign main app
if [ "$SIGN_ID" = "-" ]; then
    SIGN_FLAGS=(--force --sign "$SIGN_ID"
                --timestamp=none)
else
    SIGN_FLAGS=(--force --sign "$SIGN_ID"
                --entitlements "$ACTIVE_ENTITLEMENTS"
                --options runtime
                --timestamp)
fi

codesign "${SIGN_FLAGS[@]}" "$APP_BUNDLE"
success "Code signing complete ($([ "$SIGN_ID" = "-" ] && echo "ad-hoc" || echo "Developer ID"))"

# Verify
codesign -vv "$APP_BUNDLE" 2>&1 | while IFS= read -r line; do info "$line"; done

# ── Step 3: Package DMG ─────────────────────────────────────────────────────
if $MAKE_DMG; then
    step "Packaging DMG"
    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"

    DMG_NAME="${APP_NAME}-${VERSION}.dmg"
    DMG_PATH="${DIST_DIR}/${DMG_NAME}"

    hdiutil create \
        -volname "${APP_NAME}" \
        -srcfolder "$APP_BUNDLE" \
        -ov \
        -format UDZO \
        "$DMG_PATH"

    success "DMG created: $DMG_NAME ($(du -h "$DMG_PATH" | cut -f1))"

    SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
    info "SHA256: $SHA256"
fi

echo ""
echo -e "${GREEN}${BOLD}Build complete${RESET}"
