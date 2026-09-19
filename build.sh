#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
#  iMonitor – Build, Sign, Package & Release Script
#
#  Usage:
#    ./build.sh                       # Build Release .app
#    ./build.sh --dmg                 # Build Release .app + package as DMG
#    ./build.sh --ci                  # CI mode: build + DMG
#    ./build.sh --clean               # Remove all build artefacts
#    ./build.sh --release [VERSION]   # Full release: build + tag + GitHub + Homebrew
#    ./build.sh --release 1.2.3 --dry-run
#    ./build.sh --release 1.2.3 --skip-brew
#    ./build.sh --release 1.2.3 --fix-sha
#    ./build.sh --help                # Show this help
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

# Release / Homebrew
GITHUB_OWNER="aresnasa"
GITHUB_REPO="iMonitor"
HOMEBREW_TAP_REPO="homebrew-tap"
LOCAL_TAP_CASK="/opt/homebrew/Library/Taps/${GITHUB_OWNER}/homebrew-tap/Casks/imonitor.rb"

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
    BLUE='\033[0;34m' CYAN='\033[0;36m' BOLD='\033[1m' DIM='\033[2m' RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' RESET=''
fi

step()    { echo -e "\n${BLUE}${BOLD}▸ $1${RESET}"; }
success() { echo -e "  ${GREEN}✅ $1${RESET}"; }
warn()    { echo -e "  ${YELLOW}⚠️  $1${RESET}"; }
fail()    { echo -e "  ${RED}❌ $1${RESET}"; exit 1; }
info()    { echo -e "  ${DIM}$1${RESET}"; }

# ══════════════════════════════════════════════════════════════════════════════
#  Release helpers
# ══════════════════════════════════════════════════════════════════════════════

# Download DMG from a GitHub release and compute its SHA256.
# Sets SHA256_DMG. Fails if the asset is missing.
# Bounded: GitHub's CDN occasionally stalls a transfer mid-flight, and a bare
# `curl` waits forever — abort slow/stalled transfers and retry instead.
verify_dmg_from_github() {
    local tag="$1" tmpdir="$2"
    SHA256_DMG=""
    local url="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/download/${tag}/${DMG_NAME}"
    info "Downloading DMG from GitHub Release…"
    if curl -fsSL --progress-bar \
        --connect-timeout 15 \
        --max-time 300 \
        --speed-limit 1024 --speed-time 20 \
        --retry 4 --retry-delay 2 --retry-all-errors \
        -o "${tmpdir}/dmg.dmg" "$url" 2>&1; then
        SHA256_DMG="$(shasum -a 256 "${tmpdir}/dmg.dmg" | awk '{print $1}')"
        success "SHA256: $SHA256_DMG"
    else
        fail "DMG not found in release ${tag}. Is the release published?"
    fi
}

# Emit the Homebrew cask Ruby source for the current version/sha/url.
# Single source of truth: homebrew/imonitor.rb (with @VERSION@/@SHA256@ placeholders).
build_cask_content() {
    local template="${SCRIPT_DIR}/homebrew/imonitor.rb"
    [ -f "$template" ] || fail "Cask template not found: $template"
    sed -e "s/@VERSION@/${VERSION}/g" \
        -e "s/@SHA256@/${SHA256_DMG}/g" \
        "$template"
}

# Clone the homebrew tap, write the cask, validate, commit & push.
push_cask_to_tap() {
    local dry_run="$1" cask_content="$2" commit_msg="$3"

    if $dry_run; then
        info "[DRY RUN] Would update Casks/imonitor.rb"
        echo ""; echo "$cask_content"; return 0
    fi

    local brew_tmpdir; brew_tmpdir="$(mktemp -d)"
    info "Cloning ${GITHUB_OWNER}/${HOMEBREW_TAP_REPO}…"
    gh repo clone "${GITHUB_OWNER}/${HOMEBREW_TAP_REPO}" "$brew_tmpdir" -- --depth 1 2>&1 \
        | while IFS= read -r line; do info "$line"; done

    mkdir -p "$brew_tmpdir/Casks"
    printf '%s\n' "$cask_content" > "$brew_tmpdir/Casks/imonitor.rb"

    # Style validation (best-effort, may fail due to network)
    step "Validating cask style"
    if brew style --fix "$brew_tmpdir/Casks/imonitor.rb" 2>&1 \
            | while IFS= read -r line; do info "$line"; done; then
        success "brew style: clean"
    else
        warn "brew style check skipped or failed (non-fatal)"
    fi

    git -C "$brew_tmpdir" add -A
    if git -C "$brew_tmpdir" diff --cached --quiet; then
        info "Homebrew cask already up to date"
    else
        git -C "$brew_tmpdir" commit -m "$commit_msg"
        git -C "$brew_tmpdir" push origin main 2>&1 \
            | while IFS= read -r line; do info "$line"; done
        success "Cask pushed to ${GITHUB_OWNER}/${HOMEBREW_TAP_REPO}"
    fi

    [ -f "$LOCAL_TAP_CASK" ] && printf '%s\n' "$cask_content" > "$LOCAL_TAP_CASK"
    rm -rf "$brew_tmpdir"

    step "Verifying cask download (brew fetch)"
    if HOMEBREW_NO_AUTO_UPDATE=1 brew fetch --cask "${GITHUB_OWNER}/tap/imonitor" 2>&1 \
            | while IFS= read -r line; do info "$line"; done; then
        success "brew fetch: verified"
    else
        warn "brew fetch reported an issue (non-fatal)"
    fi
}

# ── Defaults ─────────────────────────────────────────────────────────────────
SIGN_ID="${SIGN_IDENTITY:--}"
MAKE_DMG=false
CLEAN=false

# Release flags
RELEASE_MODE=false
RELEASE_VERSION=""
DRY_RUN=false
SKIP_BREW=false
SKIP_BUILD=false
FORCE=false
FIX_SHA=false

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dmg)        MAKE_DMG=true; shift ;;
        --ci)         MAKE_DMG=true; shift ;;
        --clean)      CLEAN=true; shift ;;
        --release)
            RELEASE_MODE=true; shift
            # Optional version as next argument (if not a flag)
            if [[ $# -gt 0 && "$1" != -* ]]; then
                RELEASE_VERSION="$1"; shift
            fi
            ;;
        --dry-run)    DRY_RUN=true; shift ;;
        --skip-brew)  SKIP_BREW=true; shift ;;
        --skip-build) SKIP_BUILD=true; shift ;;
        --force)      FORCE=true; shift ;;
        --fix-sha)    FIX_SHA=true; RELEASE_MODE=true; SKIP_BUILD=true; shift ;;
        --help|-h)
            cat <<HELP
Usage: $0 [OPTIONS]

Build:
  (no flags)        Build Release .app
  --dmg             Build + package as DMG
  --ci              CI mode (build + DMG)
  --clean           Remove all build artefacts

Release:
  --release [VER]   Full release: build + DMG + git tag + GitHub Release + Homebrew cask
                    (VER defaults to MARKETING_VERSION from project.yml)
  --dry-run         Preview release without publishing
  --skip-brew       Skip Homebrew cask update
  --skip-build      Use existing DMG (skip build step)
  --fix-sha         Re-download DMG from GitHub & fix cask SHA only
  --force           Overwrite existing tag/release

Other:
  --help, -h        Show this help

Environment:
  SIGN_IDENTITY      Code-sign identity (default: "-" for ad-hoc)
  MARKETING_VERSION  Override version string
HELP
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Release-only flags make no sense without --release
if ! $RELEASE_MODE; then
    $DRY_RUN    && fail "--dry-run requires --release"
    $SKIP_BREW  && fail "--skip-brew requires --release"
    $SKIP_BUILD && fail "--skip-build requires --release"
    $FORCE      && fail "--force requires --release"
fi

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

# ── Release setup ────────────────────────────────────────────────────────────
if $RELEASE_MODE; then
    # Resolve release version
    if [ -n "$RELEASE_VERSION" ]; then
        VERSION="$RELEASE_VERSION"
    fi

    # Validate version format
    echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$' \
        || fail "Invalid version: $VERSION"

    # Dry-run implies skip-build
    if $DRY_RUN; then
        SKIP_BUILD=true
    fi

    # Release always needs a DMG (unless fixing SHA or skipping build)
    if ! $FIX_SHA && ! $SKIP_BUILD; then
        MAKE_DMG=true
    fi

    # Update MARKETING_VERSION in project.yml so xcodegen picks it up
    if ! $DRY_RUN && ! $SKIP_BUILD && ! $FIX_SHA; then
        sed -i '' "s/MARKETING_VERSION: .*/MARKETING_VERSION: ${VERSION}/" project.yml
        success "Updated MARKETING_VERSION to ${VERSION} in project.yml"
    fi
fi

# DMG paths (needed by both build and release sections)
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"

# ── Banner (release mode) ────────────────────────────────────────────────────
if $RELEASE_MODE; then
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║   iMonitor – Release Automation                  ║${RESET}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════╝${RESET}"
    echo -e "  ${DIM}Version:${RESET}   ${BOLD}${VERSION}${RESET}  Dry run: $($DRY_RUN && echo "YES" || echo "no")"
    echo ""
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Build, Sign & Package (skipped for --fix-sha / --skip-build / --dry-run)
# ══════════════════════════════════════════════════════════════════════════════
if ! $SKIP_BUILD && ! $FIX_SHA; then

    # ── Step 1: Build via xcodebuild (unsigned) ─────────────────────────────
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

    # ── Step 2: Code sign manually ──────────────────────────────────────────
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

    # ── Step 3: Package DMG ─────────────────────────────────────────────────
    if $MAKE_DMG; then
        step "Packaging DMG"
        rm -rf "$DIST_DIR"
        mkdir -p "$DIST_DIR"

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

else
    # --skip-build / --fix-sha / --dry-run: no build, but verify DMG exists
    if $RELEASE_MODE && ! $FIX_SHA && ! $DRY_RUN; then
        [ -f "$DMG_PATH" ] || fail "DMG not found: $DMG_PATH (--skip-build requires existing DMG)"
        SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
        info "Using existing DMG: $DMG_NAME (SHA256: $SHA256)"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Release publishing (only in --release mode)
# ══════════════════════════════════════════════════════════════════════════════
if $RELEASE_MODE; then
    TAG="v${VERSION}"

    # ── Prerequisites ────────────────────────────────────────────────────────
    step "Validating release prerequisites"
    command -v gh &>/dev/null || fail "gh CLI not found (brew install gh)"
    if ! $DRY_RUN; then
        gh auth status &>/dev/null 2>&1 || fail "gh not authenticated (run: gh auth login)"
        success "gh CLI authenticated"
    else
        info "[DRY RUN] Skipping gh auth check"
    fi
    git rev-parse --git-dir &>/dev/null || fail "Not a git repo"
    if ! $DRY_RUN && git tag -l "$TAG" | grep -q "$TAG"; then
        $FORCE && warn "Tag $TAG exists — will overwrite (--force)" || fail "Tag $TAG exists. Use --force."
    fi
    success "Prerequisites OK"

    # ── --fix-sha: download DMG from GitHub, fix cask SHA, exit ──────────────
    if $FIX_SHA; then
        step "Fix Cask SHA256 (re-download from GitHub)"
        if ! $DRY_RUN; then
            VTMPDIR="$(mktemp -d)"
            verify_dmg_from_github "$TAG" "$VTMPDIR"
            rm -rf "$VTMPDIR"
        else
            SHA256_DMG="<verified>"
        fi

        CASK_CONTENT="$(build_cask_content)"
        push_cask_to_tap "$DRY_RUN" "$CASK_CONTENT" "Fix SHA256 for imonitor ${VERSION}

sha256: ${SHA256_DMG}
Release: https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/tag/${TAG}"

        echo ""
        echo -e "${GREEN}${BOLD}✅ SHA256 fixed${RESET}"
        exit 0
    fi

    # ── Step R1: Git tag ────────────────────────────────────────────────────
    step "Creating git tag: $TAG"
    if ! $DRY_RUN; then
        # Remove existing tag if --force
        if git tag -l "$TAG" | grep -q "$TAG"; then
            git tag -d "$TAG" 2>/dev/null || true
            git push origin ":refs/tags/$TAG" 2>/dev/null || true
        fi
        # Commit any uncommitted changes
        if [ -n "$(git status --porcelain)" ]; then
            git add -A
            git commit -m "release: ${TAG}" || true
        fi
        git push origin main 2>&1 || warn "Push to main skipped"
        git tag -a "$TAG" -m "${APP_NAME} ${TAG}"
        git push origin "$TAG"
        success "Tag $TAG pushed"
    else
        info "[DRY RUN] Would create & push tag $TAG"
    fi

    # ── Step R2: GitHub Release ─────────────────────────────────────────────
    step "Creating GitHub Release"
    RELEASE_NOTES="## ${APP_NAME} ${TAG}

### Installation

\`\`\`bash
brew tap ${GITHUB_OWNER}/tap
brew install --cask imonitor
\`\`\`

Or download the DMG below, open and drag **iMonitor.app** to **Applications**.

### Features
- CPU / Memory / GPU utilization with animated bar charts
- Per-process CPU% and Memory display
- System process monitoring (CPU/Memory-active processes without network)
- Network speed monitoring per process
- Per-IP network traffic tracking (net mode)
- Universal binary (Apple Silicon + Intel)
- Dark mode support

### Requirements
macOS 11.0+ (Big Sur or later)

---

**SHA256:** \`${SHA256:-<pending>}\`"

    if ! $DRY_RUN; then
        $FORCE && gh release delete "$TAG" --repo "${GITHUB_OWNER}/${GITHUB_REPO}" --yes 2>/dev/null || true
        gh release create "$TAG" "$DMG_PATH" \
            --repo "${GITHUB_OWNER}/${GITHUB_REPO}" \
            --title "${APP_NAME} ${TAG}" \
            --notes "$RELEASE_NOTES"
        success "Release: https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/tag/${TAG}"
    else
        info "[DRY RUN] Would create GitHub release $TAG with $DMG_NAME"
    fi

    # ── Step R3: Update Homebrew cask ───────────────────────────────────────
    if ! $SKIP_BREW; then
        step "Updating Homebrew cask"
        if ! $DRY_RUN; then
            # Verify the DMG is downloadable from GitHub before updating the cask
            VTMPDIR="$(mktemp -d)"
            verify_dmg_from_github "$TAG" "$VTMPDIR"
            rm -rf "$VTMPDIR"
        else
            SHA256_DMG="<verified>"
        fi

        CASK_CONTENT="$(build_cask_content)"
        push_cask_to_tap "$DRY_RUN" "$CASK_CONTENT" "Update imonitor to ${VERSION}

sha256: ${SHA256_DMG}
Release: https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/tag/${TAG}"
    fi

    # ── Summary ─────────────────────────────────────────────────────────────
    echo ""
    echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
    if $DRY_RUN; then
        echo -e "${YELLOW}${BOLD}  Dry run complete${RESET}"
    else
        echo -e "${GREEN}${BOLD}  Release ${TAG} published!${RESET}"
    fi
    echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
    echo ""
    echo -e "  ${DIM}Install:${RESET}  brew tap ${GITHUB_OWNER}/tap && brew install --cask imonitor"
    echo -e "  ${DIM}Upgrade:${RESET}  brew update && brew upgrade --cask imonitor"
    echo ""
    exit 0
fi

# ── Final message (non-release build) ────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}Build complete${RESET}"
