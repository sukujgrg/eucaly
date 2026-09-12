#!/bin/bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/build.sh [--help]

Build and export an Apple Silicon (arm64) app to ~/Applications.
Use make release to sign, notarize, and publish a distribution release.

Options:
  --help  Show this help text.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

cd "$(dirname "$0")/.."
BUILD_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/eucaly.XXXXXX")"
trap 'rm -rf "$BUILD_TEMP_DIR"' EXIT
ARCHIVE_PATH="$BUILD_TEMP_DIR/eucaly.xcarchive"
EXPORT_PLIST="$BUILD_TEMP_DIR/eucaly-export.plist"
EXPORT_PATH="$HOME/Applications"

mkdir -p "$EXPORT_PATH"

xcodebuild \
  -project eucaly.xcodeproj \
  -scheme eucaly \
  -configuration Release \
  -derivedDataPath build/DerivedData \
  -archivePath "$ARCHIVE_PATH" \
  archive \
  STRIP_INSTALLED_PRODUCT=YES \
  COPY_PHASE_STRIP=YES \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO

cat > "$EXPORT_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>mac-application</string>
  <key>signingStyle</key><string>manual</string>
  <key>stripSwiftSymbols</key><true/>
  <key>compileBitcode</key><false/>
  <key>signingCertificate</key><string></string>
  <key>provisioningProfiles</key><dict/>
</dict>
</plist>
PLIST

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_PLIST"
