#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
#  iMonitor – Release Automation Script
#
#  Automates the full release cycle:
#    1. Build .app + DMG via build.sh
#    2. Create git tag & push
#    3. Create GitHub Release with assets
#    4. Update Homebrew tap Cask
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
BUILD_SCRIPT="${PROJECT_ROOT}/build.sh"
DIST_DIR="${PROJECT_ROOT}/dist"

GITHUB_OWNER="aresnasa"
GITHUB_REPO="iMonitor"
HOMEBREW_TAP_REPO="homebrew-tap"
APP_NAME="iMonitor"
BUNDLE_ID="com.aresnasa.iMonitor"
LOCAL_TAP_CASK="/opt/homebrew/Library/Taps/${GITHUB_OWNER}/homebrew-tap/Casks/imonitor.rb"

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
  desc "Menu bar system monitor – CPU, Memory, GPU, Network"
  homepage "https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :ventura

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
    #    The build-machine signature is invalidated when Homebrew copies the
    #    .app; without re-signing macOS 14+ / Sequoia blocks the app.
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
end
CASK_EOF
}

# ══════════════════════════════════════════════════════════════════════════════
#  Helper: push_cask_to_tap
# ══════════════════════════════════════════════════════════════════════════════
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

# ══════════════════════════════════════════════════════════════════════════════
#  Argument parsing
# ══════════════════════════════════════════════════════════════════════════════

VERSION=""
DRY_RUN=false
SKIP_BREW=false
SKIP_BUILD=false
FORCE=false
FIX_SHA=false

for arg in "$@"; do
    case "$arg" in
        --dry-run)    DRY_RUN=true ;;
        --skip-brew)  SKIP_BREW=true ;;
        --skip-build) SKIP_BUILD=true ;;
        --fix-sha)    FIX_SHA=true; SKIP_BUILD=true ;;
        --force)      FORCE=true ;;
        --help|-h)    echo "Usage: $0 VERSION [--dry-run] [--skip-brew] [--skip-build] [--fix-sha] [--force]"; exit 0 ;;
        -*)           echo "Unknown: $arg"; exit 1 ;;
        *)
            if [ -z "$VERSION" ]; then VERSION="$arg"
            else echo "Unexpected: $arg"; exit 1; fi
            ;;
    esac
done

[ -z "$VERSION" ] && { echo "Error: VERSION required"; exit 1; }
echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$' || fail "Invalid version: $VERSION"

TAG="v${VERSION}"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="${DIST_DIR}/${DMG_NAME}"

# ── --fix-sha ────────────────────────────────────────────────────────────────
if $FIX_SHA; then
    echo -e "${CYAN}${BOLD}iMonitor – Fix Cask SHA256${RESET}\n"
    VTMPDIR="$(mktemp -d)"; verify_dmg_from_github "$TAG" "$VTMPDIR"; rm -rf "$VTMPDIR"
    CASK_CONTENT="$(build_cask_content)"
    push_cask_to_tap "$DRY_RUN" "$CASK_CONTENT" "Fix SHA256 for imonitor ${VERSION}

sha256: ${SHA256_DMG}
Release: https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/tag/${TAG}"
    echo -e "\n${GREEN}${BOLD}✅ SHA256 fixed${RESET}"; exit 0
fi

# ── Banner ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║   iMonitor – Release Automation                  ║${RESET}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════╝${RESET}"
echo -e "  ${DIM}Version:${RESET}   ${BOLD}${VERSION}${RESET}  Dry run: $($DRY_RUN && echo "YES" || echo "no")"
echo ""

# ── Prerequisites ────────────────────────────────────────────────────────────
step "Validating prerequisites"
command -v gh &>/dev/null || fail "gh CLI not found"
gh auth status &>/dev/null 2>&1 || fail "gh not authenticated"
success "gh CLI authenticated"
git -C "$PROJECT_ROOT" rev-parse --git-dir &>/dev/null || fail "Not a git repo"
if git -C "$PROJECT_ROOT" tag -l "$TAG" | grep -q "$TAG"; then
    $FORCE && warn "Tag $TAG exists — will overwrite (--force)" || fail "Tag $TAG exists. Use --force."
fi
success "Prerequisites OK"

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 1: Build .app + DMG
# ══════════════════════════════════════════════════════════════════════════════
if ! $SKIP_BUILD; then
    step "Building ${APP_NAME} v${VERSION}"

    # Update MARKETING_VERSION in project.yml so xcodegen picks it up
    if ! $DRY_RUN; then
        sed -i '' "s/MARKETING_VERSION: .*/MARKETING_VERSION: ${VERSION}/" "${PROJECT_ROOT}/project.yml"
        success "Updated MARKETING_VERSION to ${VERSION} in project.yml"
    fi

    if $DRY_RUN; then
        info "[DRY RUN] Would run: MARKETING_VERSION=${VERSION} bash build.sh --ci"
    else
        MARKETING_VERSION="$VERSION" bash "$BUILD_SCRIPT" --ci
        [ -f "$DMG_PATH" ] || fail "DMG not found: $DMG_PATH"
        success "DMG built: $DMG_NAME"
    fi
else
    step "Skipping build (--skip-build)"
    [ -f "$DMG_PATH" ] || fail "DMG not found: $DMG_PATH"
fi

LOCAL_SHA256=""
if ! $DRY_RUN && [ -f "$DMG_PATH" ]; then
    LOCAL_SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
    info "SHA256: $LOCAL_SHA256"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 2: Git tag
# ══════════════════════════════════════════════════════════════════════════════
step "Creating git tag: $TAG"
if ! $DRY_RUN; then
    git -C "$PROJECT_ROOT" tag -l "$TAG" | grep -q "$TAG" && {
        git -C "$PROJECT_ROOT" tag -d "$TAG" 2>/dev/null || true
        git -C "$PROJECT_ROOT" push origin ":refs/tags/$TAG" 2>/dev/null || true
    }
    [ -n "$(git -C "$PROJECT_ROOT" status --porcelain)" ] && {
        git -C "$PROJECT_ROOT" add -A
        git -C "$PROJECT_ROOT" commit -m "release: ${TAG}" || true
    }
    git -C "$PROJECT_ROOT" push origin main 2>&1 || warn "Push skipped"
    git -C "$PROJECT_ROOT" tag -a "$TAG" -m "${APP_NAME} ${TAG}"
    git -C "$PROJECT_ROOT" push origin "$TAG"
    success "Tag $TAG pushed"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 3: GitHub Release
# ══════════════════════════════════════════════════════════════════════════════
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
- Universal binary (Apple Silicon + Intel)
- Dark mode support

### Requirements
macOS 13.0+ (Ventura or later)

---

**SHA256:** \`${LOCAL_SHA256}\`"

if ! $DRY_RUN; then
    $FORCE && gh release delete "$TAG" --repo "${GITHUB_OWNER}/${GITHUB_REPO}" --yes 2>/dev/null || true
    gh release create "$TAG" "$DMG_PATH" \
        --repo "${GITHUB_OWNER}/${GITHUB_REPO}" \
        --title "${APP_NAME} ${TAG}" \
        --notes "$RELEASE_NOTES"
    success "Release: https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/tag/${TAG}"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 4: Update Homebrew cask
# ══════════════════════════════════════════════════════════════════════════════
if ! $SKIP_BREW; then
    step "Updating Homebrew cask"
    if ! $DRY_RUN; then
        VTMPDIR="$(mktemp -d)"; verify_dmg_from_github "$TAG" "$VTMPDIR"; rm -rf "$VTMPDIR"
    else
        SHA256_DMG="<verified>"
    fi
    CASK_CONTENT="$(build_cask_content)"
    push_cask_to_tap "$DRY_RUN" "$CASK_CONTENT" "Update imonitor to ${VERSION}

sha256: ${SHA256_DMG}
Release: https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/tag/${TAG}"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
$DRY_RUN && echo -e "${YELLOW}${BOLD}  Dry run complete${RESET}" || echo -e "${GREEN}${BOLD}  Release ${TAG} published!${RESET}"
echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${DIM}Install:${RESET}  brew tap ${GITHUB_OWNER}/tap && brew install --cask imonitor"
echo -e "  ${DIM}Upgrade:${RESET}  brew update && brew upgrade --cask imonitor"
echo ""
