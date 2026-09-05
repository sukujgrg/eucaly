#!/bin/bash

set -euo pipefail

VERSION=""

if [[ $# -gt 0 ]]; then
  echo "Usage: $0" >&2
  exit 2
fi

TMP="$(mktemp -d "${TMPDIR%/}/eucaly.XXXXXX")"
ARCHIVE_PATH="$TMP/eucaly.xcarchive"
EXPORT_PATH="$HOME/Applications"

if [[ -f VERSION ]]; then
  VERSION="$(tr -d '[:space:]' < VERSION)"
fi

mkdir -p "$EXPORT_PATH"

xcodebuild_args=(
  -project eucaly.xcodeproj \
  -scheme eucaly \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  archive \
  STRIP_INSTALLED_PRODUCT=YES \
  COPY_PHASE_STRIP=YES
)

if [[ -n "$VERSION" ]]; then
  xcodebuild_args+=("MARKETING_VERSION=$VERSION")
fi

xcodebuild "${xcodebuild_args[@]}"

APP_PATH="$ARCHIVE_PATH/Products/Applications/eucaly.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Expected archived app at $APP_PATH" >&2
  exit 1
fi

rm -rf "$EXPORT_PATH/eucaly.app"
cp -R "$APP_PATH" "$EXPORT_PATH/eucaly.app"
