#!/bin/bash

set -euo pipefail

CURRENT_ARCH_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --current-arch)
      CURRENT_ARCH_ONLY=1
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Usage: $0 [--current-arch]" >&2
      exit 2
      ;;
  esac
done

TMP="$(mktemp -d "${TMPDIR%/}/eucaly.XXXXXX")"
ARCHIVE_PATH="$TMP/eucaly.xcarchive"
EXPORT_PLIST="$TMP/eucaly-export.plist"
EXPORT_PATH="$HOME/Applications"
CURRENT_ARCH="$(uname -m)"

mkdir -p "$EXPORT_PATH"

xcodebuild_args=(
  -project eucaly.xcodeproj \
  -scheme eucaly \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  archive \
  STRIP_INSTALLED_PRODUCT=YES \
  COPY_PHASE_STRIP=YES
)

if [[ "$CURRENT_ARCH_ONLY" -eq 1 ]]; then
  xcodebuild_args+=(
    ONLY_ACTIVE_ARCH=YES
    "ARCHS=$CURRENT_ARCH"
  )
fi

xcodebuild "${xcodebuild_args[@]}"

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
