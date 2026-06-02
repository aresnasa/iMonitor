#!/bin/bash
set -euo pipefail

# iMonitor build & release script
# Usage: ./release.sh [version]
#   version: optional, defaults to MARKETING_VERSION from project.yml
#
# Prerequisites:
#   - Apple Developer ID Application certificate installed
#   - App-specific password stored in keychain as "AC_PASSWORD"
#     (create: xcrun notarytool store-credentials AC_PASSWORD
#      --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID)
#   - gh CLI installed

REPO_OWNER="aresnasa"
REPO_NAME="iMonitor"
APP_NAME="iMonitor"
SCHEME="iMonitor"
PROJECT="iMonitor.xcodeproj"
BREW_TAP="${REPO_OWNER}/homebrew-tap"
BUNDLE_ID="com.aresnasa.iMonitor"
SIGNING_IDENTITY="Developer ID Application"
NOTARY_PROFILE="AC_PASSWORD"

# Determine version
if [ -n "${1:-}" ]; then
    VERSION="$1"
else
    VERSION=$(grep 'MARKETING_VERSION' project.yml | awk '{print $2}' | tr -d '"')
fi

echo "==> Building ${APP_NAME} v${VERSION} (Universal Binary)"

# Regenerate Xcode project
xcodegen generate 2>&1 | tail -1

# Clean and build
xcodebuild -project "${PROJECT}" -scheme "${SCHEME}" \
    -configuration Release \
    ONLY_ACTIVE_ARCH=NO \
    clean build \
    SYMROOT="$(pwd)/build" \
    | tail -5

# Verify universal binary
BINARY="build/Release/${APP_NAME}.app/Contents/MacOS/${APP_NAME}"
ARCHS=$(lipo -archs "$BINARY")
echo "==> Architecture: ${ARCHS}"
if [[ "$ARCHS" != *"arm64"* ]] || [[ "$ARCHS" != *"x86_64"* ]]; then
    echo "ERROR: Binary is not universal (expected arm64 + x86_64)"
    exit 1
fi

# Verify code signature
echo "==> Verifying code signature..."
codesign -dv "build/Release/${APP_NAME}.app" 2>&1 | grep "Signature="
if codesign -vvv --deep --strict "build/Release/${APP_NAME}.app" 2>&1; then
    echo "==> Signature valid"
else
    echo "ERROR: Code signature verification failed"
    echo "Make sure your Developer ID Application certificate is installed."
    echo "Run: security find-identity -v -p codesigning"
    exit 1
fi

# Package
PKG_DIR="build/package"
rm -rf "${PKG_DIR}"
mkdir -p "${PKG_DIR}"
cp -R "build/Release/${APP_NAME}.app" "${PKG_DIR}/"

ZIP_NAME="${APP_NAME}-v${VERSION}.zip"
cd "${PKG_DIR}"
zip -r -q "../${ZIP_NAME}" "${APP_NAME}.app"
cd - > /dev/null

ZIP_PATH="build/${ZIP_NAME}"
echo "==> Packaged: ${ZIP_PATH} ($(du -h "$ZIP_PATH" | cut -f1))"

# Notarize
echo "==> Notarizing..."
xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait 2>&1 || {
    echo "WARNING: Notarization failed. You may need to set up notarytool credentials:"
    echo "  xcrun notarytool store-credentials ${NOTARY_PROFILE}"
    echo "  --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID"
    echo ""
    echo "Continuing without notarization..."
}

# Staple notarization ticket
xcrun stapler staple "build/Release/${APP_NAME}.app" 2>&1 || echo "WARNING: Stapling failed"

# Re-package after stapling
rm -f "${ZIP_PATH}"
cd "${PKG_DIR}"
zip -r -q "../${ZIP_NAME}" "${APP_NAME}.app"
cd - > /dev/null

# Compute SHA256
SHA256=$(shasum -a 256 "$ZIP_PATH" | cut -d' ' -f1)
echo "==> SHA256: ${SHA256}"

# Create GitHub release if gh is available
if command -v gh &> /dev/null; then
    echo "==> Creating GitHub release v${VERSION}..."

    # Check if tag already exists
    if git tag -l "v${VERSION}" | grep -q "v${VERSION}"; then
        echo "Tag v${VERSION} already exists, deleting and recreating"
        git tag -d "v${VERSION}" 2>/dev/null || true
        git push origin ":refs/tags/v${VERSION}" 2>/dev/null || true
    fi
    git tag "v${VERSION}"

    # Push tag
    git push origin "v${VERSION}" 2>/dev/null || true

    # Delete existing release if any
    gh release delete "v${VERSION}" --repo "${REPO_OWNER}/${REPO_NAME}" --yes 2>/dev/null || true

    # Create release
    gh release create "v${VERSION}" "$ZIP_PATH" \
        --repo "${REPO_OWNER}/${REPO_NAME}" \
        --title "v${VERSION}" \
        --notes "## iMonitor v${VERSION}

### Features
- CPU / Memory / GPU utilization monitoring with animated bar charts
- Per-process CPU% and Memory display
- Network speed monitoring per process
- Native Apple Silicon (arm64) + Intel (x86_64) universal binary
- Dark mode support

### Installation
\`\`\`bash
brew install --cask ${BREW_TAP}/${APP_NAME}
\`\`\`
Or download the zip from the assets below." 2>&1

    echo "==> GitHub release created: https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/tag/v${VERSION}"

    # Update Homebrew tap
    DOWNLOAD_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/v${VERSION}/${ZIP_NAME}"
    echo "==> Updating Homebrew cask..."
    echo "    Download URL: ${DOWNLOAD_URL}"
    echo "    SHA256: ${SHA256}"

    # Check if homebrew-tap repo exists, create if not
    if ! gh repo view "${BREW_TAP}" &>/dev/null; then
        echo "==> Creating Homebrew tap repo: ${BREW_TAP}"
        gh repo create "${BREW_TAP}" --public --description "Homebrew tap for iMonitor"
    fi

    # Generate cask
    CASK_DIR="/tmp/${BREW_TAP//\//-}"
    rm -rf "${CASK_DIR}"
    git clone "https://github.com/${BREW_TAP}.git" "${CASK_DIR}" 2>/dev/null || mkdir -p "${CASK_DIR}"

    mkdir -p "${CASK_DIR}/Casks"

    cat > "${CASK_DIR}/Casks/${APP_NAME}.rb" << CASK_EOF
cask "imonitor" do
  version "${VERSION}"
  sha256 "${SHA256}"

  url "${DOWNLOAD_URL}"
  name "iMonitor"
  desc "macOS menu bar system monitor - CPU, Memory, GPU, Network"
  homepage "https://github.com/${REPO_OWNER}/${REPO_NAME}"

  depends_on macos: ">= :big_sur"

  app "${APP_NAME}.app"

  zap trash: [
    "~/Library/Caches/${BUNDLE_ID}",
    "~/Library/Preferences/${BUNDLE_ID}.plist",
  ]
end
CASK_EOF

    cd "${CASK_DIR}"
    git add -A
    git commit -m "bump ${APP_NAME} to v${VERSION}" || echo "No changes to commit"
    git push origin main 2>/dev/null || echo "Push may have failed, please push manually"
    cd - > /dev/null

    echo ""
    echo "==> Done! Install with:"
    echo "    brew tap ${BREW_TAP}"
    echo "    brew install --cask ${APP_NAME}"
else
    echo "==> gh CLI not found. Manual steps:"
    echo "    1. Create a GitHub release at: https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/new"
    echo "    2. Upload: ${ZIP_PATH}"
    echo "    3. Download URL: https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/v${VERSION}/${ZIP_NAME}"
    echo "    4. SHA256: ${SHA256}"
fi
