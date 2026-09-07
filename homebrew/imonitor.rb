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

  depends_on macos: :big_sur

  app "iMonitor.app"

  postflight_steps do
    run "/bin/zsh",
        args: ["-c", <<~SH]
          app="{{appdir}}/iMonitor.app"

          # 1. Strip extended attributes (removes quarantine flag)
          /usr/bin/xattr -cr "$app"

          # 2. Re-sign nested frameworks / dylibs / bundles with ad-hoc identity.
          #    Skip .bundle dirs that lack Info.plist (not real signable bundles).
          for nested in "$app"/Contents/**/*.framework(N) "$app"/Contents/**/*.dylib(N); do
            /usr/bin/codesign --force --sign - --timestamp=none "$nested"
          done
          for nested in "$app"/Contents/**/*.bundle(N); do
            [[ -f "$nested/Info.plist" ]] || continue
            /usr/bin/codesign --force --sign - --timestamp=none "$nested"
          done

          # 3. Re-sign the main app bundle with ad-hoc identity + entitlements.
          #    The build-machine signature is invalidated when Homebrew copies the
          #    .app; without re-signing macOS 14+ / Sequoia blocks the app.
          ent="$app/Contents/Resources/iMonitor-adhoc.entitlements"
          if [[ -f "$ent" ]]; then
            /usr/bin/codesign --force --sign - --timestamp=none --entitlements "$ent" "$app"
          else
            /usr/bin/codesign --force --sign - --timestamp=none "$app"
          fi

          # 4. Touch the bundle so Launch Services picks up the new signature.
          /usr/bin/touch "$app"
        SH
  end

  zap trash: [
    "~/Library/Caches/com.aresnasa.iMonitor",
    "~/Library/Preferences/com.aresnasa.iMonitor.plist",
  ]
end
