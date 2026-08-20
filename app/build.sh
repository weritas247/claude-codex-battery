#!/bin/bash
# Build the native menu bar app — compile with swiftc and assemble the .app bundle (no Xcode project needed)
set -e
cd "$(dirname "$0")"
APP="ClaudeCodexBattery.app"
NAME="ClaudeCodexBattery"
BID="com.dennykim.claude-codex-battery-app"
VERSION="$(cat ../VERSION)"
MACOS_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET:-12.0}"

echo "🔨 Compiling…"
rm -rf "$APP" "$NAME"
swiftc -O -target "arm64-apple-macos${MACOS_DEPLOYMENT_TARGET}" *.swift -o "$NAME" -framework Cocoa -framework QuartzCore -framework ServiceManagement -framework Security

echo "📦 Assembling .app bundle…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$NAME" "$APP/Contents/MacOS/$NAME"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp ClaudeProvider.svg "$APP/Contents/Resources/ClaudeProvider.svg"
cp CodexProvider.svg "$APP/Contents/Resources/CodexProvider.svg"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BID</string>
  <key>CFBundleName</key><string>Claude Codex Battery</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
</dict>
</plist>
PLIST

# Sign with a stable identity when one exists. Keychain "Always Allow" is recorded against the
# signature's designated requirement; an ad-hoc requirement is just this build's cdhash, so every
# rebuild voids the grant and re-prompts for the Keychain password. Any Apple-issued certificate
# keeps the requirement stable across rebuilds. (Use release.sh for public distribution.)
# A listed identity can still fail to sign (errSecInternalComponent — orphaned private key), so
# each candidate is tried until one actually succeeds instead of trusting the first match.
SIGNED=""
while IFS= read -r IDENTITY; do
  [ -n "$IDENTITY" ] || continue
  if codesign --force --deep --sign "$IDENTITY" "$APP" 2>/dev/null; then
    echo "✅ signed with: $IDENTITY"; SIGNED=1; break
  fi
done <<EOF2
$(security find-identity -v -p codesigning 2>/dev/null | grep -E '"(Developer ID Application|Apple Development|Apple Distribution)' | sed 's/.*"\(.*\)"/\1/')
EOF2
if [ -z "$SIGNED" ]; then
  # Ad-hoc fallback for Macs without any working certificate (free — passes Gatekeeper on your own Mac)
  codesign --force --deep --sign - "$APP" 2>/dev/null && echo "✅ ad-hoc signing complete" || echo "ⓘ skipped ad-hoc signing"
fi

echo "✅ Build complete: $(pwd)/$APP (v$VERSION)"
