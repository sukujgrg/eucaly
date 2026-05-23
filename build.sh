#!/bin/bash

set -euo pipefail

CURRENT_ARCH_ONLY=0
VERSION=""

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
EXPORT_PATH="$HOME/Applications"
CURRENT_ARCH="$(uname -m)"

if [[ -f VERSION ]]; then
  VERSION="$(tr -d '[:space:]' < VERSION)"
fi

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

if [[ -n "$VERSION" ]]; then
  xcodebuild_args+=("MARKETING_VERSION=$VERSION")
fi

if [[ "$CURRENT_ARCH_ONLY" -eq 1 ]]; then
  xcodebuild_args+=(
    ONLY_ACTIVE_ARCH=YES
    "ARCHS=$CURRENT_ARCH"
  )
fi

xcodebuild "${xcodebuild_args[@]}"

APP_PATH="$ARCHIVE_PATH/Products/Applications/eucaly.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Expected archived app at $APP_PATH" >&2
  exit 1
fi

rm -rf "$EXPORT_PATH/eucaly.app"
cp -R "$APP_PATH" "$EXPORT_PATH/eucaly.app"
