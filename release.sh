#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
#  iMonitor – Release Automation Script
#
#  Automates the full release cycle:
#    1. Build universal .app via xcodebuild
#    2. Package as DMG
#    3. Create git tag & push
#    4. Create GitHub Release with assets
#    5. Update Homebrew tap Cask (with brew style + fetch validation)
#
#  Usage:
#    ./release.sh 1.2.3              # Release v1.2.3
#    ./release.sh 1.2.3 --dry-run    # Preview without publishing
#    ./release.sh 1.2.3 --skip-brew  # Skip Homebrew update
#    ./release.sh 1.2.3 --fix-sha    # Re-download DMG & fix Cask SHA only
#    ./release.sh --help             # Show help
#
#  Prerequisites:
#    - gh CLI authenticated (gh auth status)
#    - git with push access to origin
#    - Xcode / Swift toolchain
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
BUILD_DIR="${PROJECT_ROOT}/build"
DIST_DIR="${PROJECT_ROOT}/dist"

GITHUB_OWNER="aresnasa"
GITHUB_REPO="iMonitor"
HOMEBREW_TAP_REPO="homebrew-tap"
APP_NAME="iMonitor"
BUNDLE_ID="com.aresnasa.iMonitor"
LOCAL_TAP_CASK="/opt/homebrew/Library/Taps/${GITHUB_OWNER}/homebrew-tap/Casks/imonitor.rb"

PROJECT_FILE="${PROJECT_ROOT}/iMonitor.xcodeproj"
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
#  Helper: verify_dmg_from_github
#
#  Downloads the DMG from GitHub Release and computes its SHA256.
# ══════════════════════════════════════════════════════════════════════════════
verify_dmg_from_github() {
    local tag="$1" tmpdir="$2"

    SHA256_DMG=""
    local url="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/download/${tag}/${DMG_NAME}"

    info "Downloading DMG from GitHub Release…"
    if curl -fsSL --progress-bar -o "${tmpdir}/dmg.dmg" "$url" 2>&1; then
        SHA256_DMG="$(shasum -a 256 "${tmpdir}/dmg.dmg" | awk '{print $1}')"
        success "SHA256: $SHA256_DMG"
    else
        fail "DMG not found in release ${tag}. Is the release published?"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  Helper: build_cask_content
# ══════════════════════════════════════════════════════════════════════════════
build_cask_content() {
    cat <<CASK_EOF
cask "imonitor" do
  version "${VERSION}"
  sha256 "${SHA256_DMG}"

  url "https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/download/v#{version}/${DMG_NAME}"
  name "${APP_NAME}"
  desc "macOS menu bar system monitor – CPU, Memory, GPU, Network"
  homepage "https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :big_sur"

  app "${APP_NAME}.app"

  postflight do
    # 1. Strip extended attributes (removes quarantine flag)
    system_command "/usr/bin/xattr",
                   args: ["-cr", "#{appdir}/${APP_NAME}.app"],
                   sudo: false

    # 2. Re-sign nested frameworks / dylibs with ad-hoc identity.
    Dir.glob("#{appdir}/${APP_NAME}.app/Contents/**/*.{framework,dylib}").each do |nested|
      system_command "/usr/bin/codesign",
                     args: ["--force", "--sign", "-", "--timestamp=none", nested],
                     sudo: false
    end
    Dir.glob("#{appdir}/${APP_NAME}.app/Contents/**/*.bundle").each do |nested|
      next unless File.exist?(File.join(nested, "Info.plist"))

      system_command "/usr/bin/codesign",
                     args: ["--force", "--sign", "-", "--timestamp=none", nested],
                     sudo: false
    end

    # 3. Re-sign the main app bundle with ad-hoc identity + entitlements.
    ent = "#{appdir}/${APP_NAME}.app/Contents/Resources/${APP_NAME}-adhoc.entitlements"
    codesign_args = ["--force", "--sign", "-", "--timestamp=none"]
    codesign_args += ["--entitlements", ent] if File.exist?(ent)
    codesign_args << "#{appdir}/${APP_NAME}.app"
    system_command "/usr/bin/codesign",
                   args: codesign_args,
                   sudo: false

    # 4. Touch the bundle so Launch Services picks up the new signature.
    system_command "/usr/bin/touch",
                   args: ["#{appdir}/${APP_NAME}.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Caches/${BUNDLE_ID}",
    "~/Library/Preferences/${BUNDLE_ID}.plist",
  ]

  caveats <<~EOS
    If macOS blocks the app after install or upgrade, run:
      xattr -cr /Applications/${APP_NAME}.app
      codesign --force --sign - --timestamp=none /Applications/${APP_NAME}.app
  EOS
end
CASK_EOF
}

# ══════════════════════════════════════════════════════════════════════════════
#  Helper: push_cask_to_tap
# ══════════════════════════════════════════════════════════════════════════════
push_cask_to_tap() {
    local dry_run="$1"
    local cask_content="$2"
    local commit_msg="$3"

    if $dry_run; then
        info "[DRY RUN] Would update Casks/imonitor.rb in ${GITHUB_OWNER}/${HOMEBREW_TAP_REPO}"
        echo ""
        echo "$cask_content"
        return 0
    fi

    local brew_tmpdir
    brew_tmpdir="$(mktemp -d)"

    info "Cloning ${GITHUB_OWNER}/${HOMEBREW_TAP_REPO}…"
    gh repo clone "${GITHUB_OWNER}/${HOMEBREW_TAP_REPO}" "$brew_tmpdir" -- --depth 1 2>&1 \
        | while IFS= read -r line; do info "$line"; done

    mkdir -p "$brew_tmpdir/Casks"
    printf '%s\n' "$cask_content" > "$brew_tmpdir/Casks/imonitor.rb"
    info "Cask written: Casks/imonitor.rb"

    # ── Style validation ───────────────────────────────────────────────────
    step "Validating cask style (brew style)"
    brew style --fix "$brew_tmpdir/Casks/imonitor.rb" 2>&1 \
        | while IFS= read -r line; do info "$line"; done || true

    local style_out
    style_out="$(mktemp)"
    if ! brew style "$brew_tmpdir/Casks/imonitor.rb" >"$style_out" 2>&1; then
        cat "$style_out" | while IFS= read -r line; do warn "$line"; done
        rm -f "$style_out" ; rm -rf "$brew_tmpdir"
        fail "brew style offenses remain — fix the cask template"
    fi
    rm -f "$style_out"
    success "brew style: clean"

    # ── Commit & push ──────────────────────────────────────────────────────
    git -C "$brew_tmpdir" add -A
    if git -C "$brew_tmpdir" diff --cached --quiet; then
        info "Homebrew cask already up to date"
    else
        git -C "$brew_tmpdir" commit -m "$commit_msg"
        git -C "$brew_tmpdir" push origin main 2>&1 \
            | while IFS= read -r line; do info "$line"; done
        success "Cask pushed to ${GITHUB_OWNER}/${HOMEBREW_TAP_REPO}"
    fi

    # ── Update local tap ──────────────────────────────────────────────────
    if [ -f "$LOCAL_TAP_CASK" ]; then
        printf '%s\n' "$cask_content" > "$LOCAL_TAP_CASK"
        success "Local tap updated: $LOCAL_TAP_CASK"
    fi

    rm -rf "$brew_tmpdir"

    # ── End-to-end download verification ──────────────────────────────────
    step "Verifying cask download (brew fetch)"
    if brew fetch --cask "${GITHUB_OWNER}/tap/imonitor" 2>&1 \
            | while IFS= read -r line; do info "$line"; done; then
        success "brew fetch: URL reachable and SHA256 verified"
    else
        warn "brew fetch reported an issue (non-fatal)"
        warn "Manual check: brew fetch --cask ${GITHUB_OWNER}/tap/imonitor"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  Argument parsing
# ══════════════════════════════════════════════════════════════════════════════

VERSION=""
DRY_RUN=false
SKIP_BREW=false
SKIP_BUILD=false
FORCE=false
FIX_SHA=false

show_help() {
    cat <<'EOF'
iMonitor – Release Script

USAGE
  ./release.sh VERSION [OPTIONS]

OPTIONS
  --dry-run      Preview all steps without executing
  --skip-brew    Skip Homebrew cask update
  --skip-build   Skip build (use existing dist/)
  --fix-sha      Re-download DMG & fix Cask SHA only
  --force        Force release even if tag exists
  --help         Show this help

EXAMPLES
  ./release.sh 0.3.0
  ./release.sh 1.0.0 --dry-run
  ./release.sh 0.3.1 --fix-sha

PREREQUISITES
  • gh CLI authenticated: gh auth status
  • git with push access to origin
  • Xcode / Swift toolchain
EOF
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        --dry-run)    DRY_RUN=true ;;
        --skip-brew)  SKIP_BREW=true ;;
        --skip-build) SKIP_BUILD=true ;;
        --fix-sha)    FIX_SHA=true; SKIP_BUILD=true ;;
        --force)      FORCE=true ;;
        --help|-h)    show_help ;;
        -*)
            echo -e "${RED}Unknown option: $arg${RESET}"
            exit 1
            ;;
        *)
            if [ -z "$VERSION" ]; then
                VERSION="$arg"
            else
                echo -e "${RED}Unexpected argument: $arg${RESET}"
                exit 1
            fi
            ;;
    esac
done

if [ -z "$VERSION" ]; then
    echo -e "${RED}Error: VERSION is required${RESET}"
    echo "Usage: $0 VERSION [--dry-run] [--skip-brew] [--skip-build] [--force]"
    exit 1
fi

if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$'; then
    fail "Invalid version format: '$VERSION' (expected: MAJOR.MINOR.PATCH)"
fi

TAG="v${VERSION}"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"

# ══════════════════════════════════════════════════════════════════════════════
#  --fix-sha: Re-download DMG, recompute SHA256, update the tap cask.
# ══════════════════════════════════════════════════════════════════════════════

if $FIX_SHA; then
    echo ""
    echo -e "${CYAN}${BOLD}iMonitor – Fix Cask SHA256${RESET}"
    echo ""

    step "Downloading DMG from GitHub Release"
    VTMPDIR="$(mktemp -d)"
    verify_dmg_from_github "$TAG" "$VTMPDIR"
    rm -rf "$VTMPDIR"

    step "Building Homebrew cask"
    CASK_CONTENT="$(build_cask_content)"

    step "Updating Homebrew tap"
    push_cask_to_tap "$DRY_RUN" "$CASK_CONTENT" "Fix SHA256 for imonitor ${VERSION}

sha256: ${SHA256_DMG}
Release: https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/tag/${TAG}"

    echo ""
    echo -e "${GREEN}${BOLD}  ✅  SHA256 fixed for ${TAG}${RESET}"
    echo ""
    exit 0
fi

# ── Banner ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║   iMonitor – Release Automation                  ║${RESET}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${DIM}Version:${RESET}   ${BOLD}${VERSION}${RESET} (tag: ${TAG})"
echo -e "  ${DIM}Dry run:${RESET}   $($DRY_RUN && echo "${YELLOW}YES${RESET}" || echo "no")"
echo -e "  ${DIM}Skip build:${RESET} $($SKIP_BUILD && echo "yes" || echo "no")"
echo -e "  ${DIM}Skip brew:${RESET}  $($SKIP_BREW && echo "yes" || echo "no")"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 0: Validate prerequisites
# ══════════════════════════════════════════════════════════════════════════════

step "Validating prerequisites"

command -v gh &>/dev/null || fail "gh CLI not found. Install: brew install gh"
gh auth status &>/dev/null 2>&1 || fail "gh CLI not authenticated. Run: gh auth login"
success "gh CLI authenticated"

git -C "$PROJECT_ROOT" rev-parse --git-dir &>/dev/null || fail "Not a git repository: $PROJECT_ROOT"

if git -C "$PROJECT_ROOT" tag -l "$TAG" | grep -q "$TAG"; then
    if $FORCE; then
        warn "Tag $TAG already exists — will be overwritten (--force)"
    else
        fail "Tag $TAG already exists. Use --force to overwrite."
    fi
fi

success "All prerequisites met"

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 1: Build .app & package as DMG
# ══════════════════════════════════════════════════════════════════════════════

if ! $SKIP_BUILD; then
    step "Building ${APP_NAME} v${VERSION} (Universal Binary)"

    # Regenerate Xcode project
    xcodegen generate 2>&1 | tail -1

    if $DRY_RUN; then
        info "[DRY RUN] Would run xcodebuild + create DMG"
    else
        # Clean and build
        xcodebuild -project "${PROJECT_FILE}" -scheme "${SCHEME}" \
            -configuration Release \
            ONLY_ACTIVE_ARCH=NO \
            clean build \
            SYMROOT="$BUILD_DIR" \
            | tail -5

        # Verify universal binary
        BINARY="${BUILD_DIR}/Release/${APP_NAME}.app/Contents/MacOS/${APP_NAME}"
        ARCHS=$(lipo -archs "$BINARY")
        echo "  Architecture: ${ARCHS}"
        if [[ "$ARCHS" != *"arm64"* ]] || [[ "$ARCHS" != *"x86_64"* ]]; then
            fail "Binary is not universal (expected arm64 + x86_64)"
        fi
        success "Universal binary built"

        # Copy ad-hoc entitlements into app bundle Resources
        ADHOC_ENT="${PROJECT_ROOT}/iMonitor/iMonitor-adhoc.entitlements"
        if [ -f "$ADHOC_ENT" ]; then
            cp "$ADHOC_ENT" "${BUILD_DIR}/Release/${APP_NAME}.app/Contents/Resources/"
            info "Copied ad-hoc entitlements into app bundle"
        fi

        # Create DMG
        step "Packaging DMG"
        rm -rf "$DIST_DIR"
        mkdir -p "$DIST_DIR"

        hdiutil create \
            -volname "${APP_NAME}" \
            -srcfolder "${BUILD_DIR}/Release/${APP_NAME}.app" \
            -ov \
            -format UDZO \
            "$DMG_PATH"

        success "DMG created: $DMG_NAME ($(du -h "$DMG_PATH" | cut -f1))"
    fi
else
    step "Skipping build (--skip-build)"
    if [ ! -f "$DMG_PATH" ]; then
        fail "DMG not found at $DMG_PATH"
    fi
    success "Using existing DMG: $DMG_PATH"
fi

# Local SHA256
LOCAL_SHA256=""
if ! $DRY_RUN && [ -f "$DMG_PATH" ]; then
    LOCAL_SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
    info "SHA256 (local): $LOCAL_SHA256"
else
    LOCAL_SHA256="<computed-after-build>"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 2: Create git tag
# ══════════════════════════════════════════════════════════════════════════════

step "Creating git tag: $TAG"

if $DRY_RUN; then
    info "[DRY RUN] Would create tag: $TAG"
else
    if git -C "$PROJECT_ROOT" tag -l "$TAG" | grep -q "$TAG"; then
        git -C "$PROJECT_ROOT" tag -d "$TAG" 2>/dev/null || true
        git -C "$PROJECT_ROOT" push origin ":refs/tags/$TAG" 2>/dev/null || true
    fi

    # Commit outstanding changes (e.g. version bumps)
    if [ -n "$(git -C "$PROJECT_ROOT" status --porcelain)" ]; then
        git -C "$PROJECT_ROOT" add -A
        git -C "$PROJECT_ROOT" commit -m "release: ${TAG}" || true
    fi

    git -C "$PROJECT_ROOT" push origin main 2>&1 || warn "Push to main skipped"
    git -C "$PROJECT_ROOT" tag -a "$TAG" -m "${APP_NAME} ${TAG}"
    git -C "$PROJECT_ROOT" push origin "$TAG"
    success "Tag $TAG created and pushed"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 3: Create GitHub Release
# ══════════════════════════════════════════════════════════════════════════════

step "Creating GitHub Release"

RELEASE_NOTES="## ${APP_NAME} ${TAG}

### Installation

#### Option 1: Homebrew (Recommended)
\`\`\`bash
brew tap ${GITHUB_OWNER}/tap
brew install --cask imonitor
\`\`\`

#### Option 2: Download DMG
1. Download the \`.dmg\` file below
2. Open the DMG and drag **iMonitor.app** into **Applications**
3. First launch: right-click iMonitor.app → select **Open**

> This is an open-source app with ad-hoc signing. macOS may warn about an unverified developer on first launch — right-click → Open to bypass.
> Alternatively: \`xattr -cr /Applications/iMonitor.app\`

### Features
- CPU / Memory / GPU utilization monitoring with animated bar charts
- Per-process CPU% and Memory display
- Network speed monitoring per process
- Native Apple Silicon (arm64) + Intel (x86_64) universal binary
- Dark mode support

### Requirements
- macOS 11.0+ (Big Sur or later)

---

**SHA256:** \`${LOCAL_SHA256}\`"

if $DRY_RUN; then
    info "[DRY RUN] Would create GitHub Release: $TAG"
    info "[DRY RUN] Asset: $DMG_NAME"
else
    RELEASE_FLAGS=(
        --title "${APP_NAME} ${TAG}"
        --notes "$RELEASE_NOTES"
    )

    if $FORCE; then
        gh release delete "$TAG" --repo "${GITHUB_OWNER}/${GITHUB_REPO}" --yes 2>/dev/null || true
    fi

    gh release create "$TAG" \
        "$DMG_PATH" \
        --repo "${GITHUB_OWNER}/${GITHUB_REPO}" \
        "${RELEASE_FLAGS[@]}"

    success "Release created: https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/tag/${TAG}"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 4: Update Homebrew cask
# ══════════════════════════════════════════════════════════════════════════════

if ! $SKIP_BREW; then
    step "Updating Homebrew cask"

    if $DRY_RUN; then
        SHA256_DMG="<verified-after-upload>"
    else
        VTMPDIR="$(mktemp -d)"
        verify_dmg_from_github "$TAG" "$VTMPDIR"
        rm -rf "$VTMPDIR"
    fi

    CASK_CONTENT="$(build_cask_content)"

    BREW_COMMIT_MSG="Update imonitor to ${VERSION}

sha256: ${SHA256_DMG}
Release: https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/tag/${TAG}"

    push_cask_to_tap "$DRY_RUN" "$CASK_CONTENT" "$BREW_COMMIT_MSG"
else
    step "Skipping Homebrew update (--skip-brew)"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  Summary
# ══════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
if $DRY_RUN; then
    echo -e "${YELLOW}${BOLD}  Dry run complete — no changes were made${RESET}"
else
    echo -e "${GREEN}${BOLD}  Release ${TAG} published successfully!${RESET}"
fi
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo ""

if ! $DRY_RUN; then
    echo -e "  ${DIM}GitHub Release:${RESET}"
    echo -e "    https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/tag/${TAG}"
    echo ""
    echo -e "  ${DIM}Install:${RESET}"
    echo -e "    brew tap ${GITHUB_OWNER}/tap"
    echo -e "    brew install --cask imonitor"
    echo ""
    echo -e "  ${DIM}Upgrade:${RESET}"
    echo -e "    brew update && brew upgrade --cask imonitor"
    echo ""
fi
