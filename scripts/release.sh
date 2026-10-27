#!/bin/zsh
# Archive, export with Developer ID, notarize and staple GHMac Client and Server.
# Usage: scripts/release.sh [notary-keychain-profile] [client|server|both]   (defaults: GHENotary, both)
# One-time setup: xcrun notarytool store-credentials GHENotary --apple-id <id> --team-id 49G92DYD5H
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${1:-GHENotary}"
WHICH="${2:-both}"
BUILD=.build/release
mkdir -p "$BUILD"
xcodegen generate --quiet

cat > "$BUILD/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>49G92DYD5H</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
EOF

release_one() {
  local scheme="$1" appname="$2"
  local out="$BUILD/$scheme"
  rm -rf "$out"; mkdir -p "$out"
  xcodebuild -project GHMac.xcodeproj -scheme "$scheme" -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$out/$scheme.xcarchive" archive
  xcodebuild -exportArchive -archivePath "$out/$scheme.xcarchive" \
    -exportOptionsPlist "$BUILD/ExportOptions.plist" -exportPath "$out/export"
  local app="$out/export/$appname.app"
  local zip="$out/${appname// /-}.zip"
  codesign --verify --deep --strict --verbose=2 "$app"
  ditto -c -k --keepParent "$app" "$zip"
  xcrun notarytool submit "$zip" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$app"
  spctl -a -vv "$app"
  ditto -c -k --keepParent "$app" "$zip"
  echo "Done: $app and $zip"
}

[[ "$WHICH" == client || "$WHICH" == both ]] && release_one GHEClient "GHMac Client"
[[ "$WHICH" == server || "$WHICH" == both ]] && release_one GHEServer "GHMac Server"
