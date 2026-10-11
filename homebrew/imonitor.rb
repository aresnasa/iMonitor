cask "imonitor" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/aresnasa/iMonitor/releases/download/v#{version}/iMonitor-#{version}.dmg"
  name "iMonitor"
  desc "Menu bar system monitor – CPU, Memory, GPU, Network"
  homepage "https://github.com/aresnasa/iMonitor"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :monterey

  app "iMonitor.app"

  postflight_steps do
    run "/bin/zsh",
        args: ["-c", <<~SH]
          app="{{appdir}}/iMonitor.app"

          # 1. Strip extended attributes (removes quarantine flag)
          /usr/bin/xattr -cr "$app"

          # 2. Keep the release signature when it verifies. Releases are signed
          #    with iMonitor's local "iMonitor Local Signing" certificate, and
          #    macOS pins privacy grants (Accessibility in particular) to that
          #    certificate - so the grant survives app updates. Re-signing
          #    ad-hoc here would pin the grant to the per-build code hash
          #    instead and silently drop it on every upgrade (the "already
          #    granted but asked again" bug). Only re-sign when the signature
          #    is broken, where ad-hoc is still better than nothing.
          if /usr/bin/codesign --verify "$app" >/dev/null 2>&1; then
            echo "iMonitor: existing signature verifies - keeping it"
          else
            echo "iMonitor: signature did not verify - re-signing ad-hoc"

            # Re-sign nested frameworks / dylibs / bundles with ad-hoc identity.
            # Skip .bundle dirs that lack Info.plist (not real signable bundles).
            for nested in "$app"/Contents/**/*.framework(N) "$app"/Contents/**/*.dylib(N); do
              /usr/bin/codesign --force --sign - --timestamp=none "$nested"
            done
            for nested in "$app"/Contents/**/*.bundle(N); do
              [[ -f "$nested/Info.plist" ]] || continue
              /usr/bin/codesign --force --sign - --timestamp=none "$nested"
            done

            # Fallback only: historically Homebrew's copy could invalidate the
            # build-machine signature, and without a valid signature macOS 14+ /
            # Sequoia blocks the app.
            ent="$app/Contents/Resources/iMonitor-adhoc.entitlements"
            if [[ -f "$ent" ]]; then
              /usr/bin/codesign --force --sign - --timestamp=none --entitlements "$ent" "$app"
            else
              /usr/bin/codesign --force --sign - --timestamp=none "$app"
            fi
          fi

          # 3. Touch the bundle so Launch Services picks up the signature.
          /usr/bin/touch "$app"
        SH
  end

  zap trash: [
    "~/Library/Caches/com.aresnasa.iMonitor",
    "~/Library/Preferences/com.aresnasa.iMonitor.plist",
  ]
end
