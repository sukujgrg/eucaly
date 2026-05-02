#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/release-notarize-distribute.sh --notary-profile PROFILE [options]

Required:
  --notary-profile PROFILE   notarytool keychain profile name.

Optional:
  --project PATH             Xcode project path (default: eucaly.xcodeproj)
  --scheme NAME              Xcode scheme (default: eucaly)
  --configuration NAME       Build configuration (default: Release)
  --version VERSION          Release version (default: Git tag, VERSION file, else Xcode MARKETING_VERSION)
  --build-number NUMBER      Build number (default: tag +BUILD suffix, else Xcode CURRENT_PROJECT_VERSION)
  --skip-version-file-check  Do not require VERSION file to match release version.
  --output-dir DIR           Output directory (default: build/release)
  --team-id TEAM_ID          Apple Developer Team ID for export signing.
  --signing-identity NAME    Override CODE_SIGN_IDENTITY at archive time.
  --current-arch             Build only current machine architecture.
  --allow-provisioning       Pass -allowProvisioningUpdates to xcodebuild.

GitHub distribution:
  --github                   Upload artifacts to GitHub release using gh CLI.
  --repo OWNER/REPO          GitHub repository slug. Required when --github is set if origin cannot be derived.
  --tag TAG                  Git tag for the release (default: exact tag at HEAD, else v<VERSION>)
  --notes FILE               Release notes file path for gh release create.
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

ensure_developer_id_identity() {
  local identities
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"

  if [[ -n "$SIGNING_IDENTITY" ]]; then
    if ! grep -F "Developer ID Application:" <<< "$identities" | grep -F "$SIGNING_IDENTITY" >/dev/null; then
      fail "Developer ID Application signing identity '$SIGNING_IDENTITY' was not found in the active keychain. Install the certificate and private key, then verify with: security find-identity -v -p codesigning"
    fi

    return 0
  fi

  if ! grep -F "Developer ID Application:" <<< "$identities" >/dev/null; then
    fail "No Developer ID Application signing identity found in the active keychain. Install the certificate and private key from Apple Developer, then verify with: security find-identity -v -p codesigning"
  fi
}

PROJECT="eucaly.xcodeproj"
SCHEME="eucaly"
CONFIGURATION="Release"
OUTPUT_DIR="build/release"
NOTARY_PROFILE=""
TEAM_ID=""
SIGNING_IDENTITY=""
VERSION=""
BUILD_NUMBER=""
CURRENT_ARCH_ONLY=false
ALLOW_PROVISIONING=false
PUBLISH_GITHUB=false
REPO=""
TAG=""
NOTES_FILE=""
SKIP_VERSION_FILE_CHECK=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      PROJECT="$2"
      shift 2
      ;;
    --scheme)
      SCHEME="$2"
      shift 2
      ;;
    --configuration)
      CONFIGURATION="$2"
      shift 2
      ;;
    --version)
      VERSION="$2"
      shift 2
      ;;
    --build-number)
      BUILD_NUMBER="$2"
      shift 2
      ;;
    --skip-version-file-check)
      SKIP_VERSION_FILE_CHECK=true
      shift
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --notary-profile)
      NOTARY_PROFILE="$2"
      shift 2
      ;;
    --team-id)
      TEAM_ID="$2"
      shift 2
      ;;
    --signing-identity)
      SIGNING_IDENTITY="$2"
      shift 2
      ;;
    --current-arch)
      CURRENT_ARCH_ONLY=true
      shift
      ;;
    --allow-provisioning)
      ALLOW_PROVISIONING=true
      shift
      ;;
    --github)
      PUBLISH_GITHUB=true
      shift
      ;;
    --repo)
      REPO="$2"
      shift 2
      ;;
    --tag)
      TAG="$2"
      shift 2
      ;;
    --notes)
      NOTES_FILE="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

derive_repo_from_origin() {
  local origin_url
  origin_url="$(git config --get remote.origin.url 2>/dev/null || true)"
  [[ -n "$origin_url" ]] || return 1

  if [[ "$origin_url" =~ ^https://github.com/([^/]+/[^/.]+)(\.git)?$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi

  if [[ "$origin_url" =~ ^git@github.com:([^/]+/[^/.]+)(\.git)?$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

derive_version_from_tag() {
  local tag="$1"
  local normalized_tag="${tag#refs/tags/}"
  normalized_tag="${normalized_tag#v}"
  local version_part="${normalized_tag%%+*}"

  if [[ "$version_part" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    printf '%s' "$version_part"
    return 0
  fi

  return 1
}

derive_build_from_tag() {
  local tag="$1"
  local normalized_tag="${tag#refs/tags/}"
  normalized_tag="${normalized_tag#v}"

  if [[ "$normalized_tag" =~ \+([0-9]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

find_exact_head_tag() {
  command -v git >/dev/null 2>&1 || return 1
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  git describe --tags --exact-match 2>/dev/null || return 1
}

ensure_clean_git_state() {
  command -v git >/dev/null 2>&1 || return 0
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  if [[ -n "$(git status --porcelain)" ]]; then
    fail "Working tree is dirty. Commit or stash changes before creating a release."
  fi
}

ensure_no_pending_pushes() {
  command -v git >/dev/null 2>&1 || return 0
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  local upstream
  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
  [[ -n "$upstream" ]] || fail "Current branch has no upstream. Push the branch and set upstream before releasing."

  local counts behind ahead
  counts="$(git rev-list --left-right --count "${upstream}...HEAD" 2>/dev/null || true)"
  [[ -n "$counts" ]] || fail "Unable to compare HEAD with upstream '$upstream'."
  read -r behind ahead <<< "$counts"
  [[ -n "$ahead" ]] || fail "Unable to parse upstream comparison for '$upstream'."

  if [[ "$ahead" != "0" ]]; then
    fail "Current branch is ahead of upstream by $ahead commit(s). Push before releasing."
  fi
}

ensure_remote_tag_exists() {
  local tag="$1"
  command -v git >/dev/null 2>&1 || fail "git is required to verify GitHub release tags."
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "GitHub release requires a Git repository."

  git rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1 \
    || fail "Tag '$tag' does not exist locally. Create and push it before running release-github."

  git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1 \
    || fail "Tag '$tag' does not exist on origin. Push it before running release-github."
}

get_build_setting() {
  local key="$1"
  xcodebuild -showBuildSettings -project "$PROJECT" -scheme "$SCHEME" 2>/dev/null \
    | awk -F' = ' -v key="$key" '$1 ~ key"$" { print $2; exit }'
}

if [[ -z "$NOTARY_PROFILE" ]]; then
  fail "--notary-profile is required"
fi

if [[ -n "$TAG" ]]; then
  TAG_VERSION="$(derive_version_from_tag "$TAG" || true)"
  [[ -n "$TAG_VERSION" ]] || fail "Tag '$TAG' is not a valid release tag. Use vX.Y.Z or vX.Y.Z+BUILD."

  if [[ -n "$VERSION" && "$VERSION" != "$TAG_VERSION" ]]; then
    fail "--version ($VERSION) does not match --tag ($TAG => $TAG_VERSION)"
  fi
  VERSION="$TAG_VERSION"
fi

if [[ -z "$VERSION" ]]; then
  HEAD_TAG="$(find_exact_head_tag || true)"
  if [[ -n "$HEAD_TAG" ]]; then
    TAG="$HEAD_TAG"
    VERSION="$(derive_version_from_tag "$HEAD_TAG" || true)"
  fi

  if [[ -z "$VERSION" && -f VERSION ]]; then
    VERSION="$(tr -d '[:space:]' < VERSION)"
  fi

  if [[ -z "$VERSION" ]]; then
    VERSION="$(get_build_setting MARKETING_VERSION)"
  fi

  [[ -n "$VERSION" ]] || fail "Unable to determine version. Pass --version, add VERSION file, or create a Git tag like vX.Y.Z."
fi

ensure_clean_git_state
ensure_no_pending_pushes

if [[ "$PUBLISH_GITHUB" == true ]]; then
  if [[ -z "$REPO" ]]; then
    REPO="$(derive_repo_from_origin || true)"
  fi
  [[ -n "$REPO" ]] || fail "--repo OWNER/REPO is required when --github is set (or configure an origin remote)"
  if [[ -z "$TAG" ]]; then
    TAG="$(find_exact_head_tag || true)"
  fi
  [[ -n "$TAG" ]] || fail "GitHub release requires an existing Git tag at HEAD. Create and push a tag like v$VERSION first."
  ensure_remote_tag_exists "$TAG"
fi

if [[ -z "$BUILD_NUMBER" && -n "$TAG" ]]; then
  BUILD_NUMBER="$(derive_build_from_tag "$TAG" || true)"
fi

if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER="$(get_build_setting CURRENT_PROJECT_VERSION)"
fi

if [[ -n "$BUILD_NUMBER" && ! "$BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  fail "--build-number must be numeric or dot-separated numeric."
fi

if [[ "$SKIP_VERSION_FILE_CHECK" == false && -f VERSION ]]; then
  VERSION_FILE_VALUE="$(tr -d '[:space:]' < VERSION)"
  [[ -n "$VERSION_FILE_VALUE" ]] || fail "VERSION file is empty. Set it to $VERSION."
  [[ "$VERSION_FILE_VALUE" == "$VERSION" ]] || fail "VERSION file ($VERSION_FILE_VALUE) does not match release version ($VERSION). Update VERSION first or use --skip-version-file-check."
fi

require_command xcodebuild
require_command xcrun
require_command ditto
require_command shasum
require_command security

ensure_developer_id_identity

if [[ "$PUBLISH_GITHUB" == true ]]; then
  require_command gh
fi

TMP_DIR="$(mktemp -d "${TMPDIR%/}/eucalyRelease.XXXXXX")"
ARCHIVE_PATH="$TMP_DIR/$SCHEME.xcarchive"
EXPORT_PATH="$TMP_DIR/export"
EXPORT_PLIST="$TMP_DIR/exportOptions.plist"
NOTARY_JSON="$TMP_DIR/notary-result.json"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$OUTPUT_DIR" "$EXPORT_PATH"

cat > "$EXPORT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>stripSwiftSymbols</key><true/>
  <key>compileBitcode</key><false/>
EOF

if [[ -n "$TEAM_ID" ]]; then
  printf '  <key>teamID</key><string>%s</string>\n' "$TEAM_ID" >> "$EXPORT_PLIST"
fi

cat >> "$EXPORT_PLIST" <<'EOF'
</dict>
</plist>
EOF

BUILD_ARGS=(
  "MARKETING_VERSION=$VERSION"
)

if [[ -n "$BUILD_NUMBER" ]]; then
  BUILD_ARGS+=("CURRENT_PROJECT_VERSION=$BUILD_NUMBER")
fi

if [[ "$CURRENT_ARCH_ONLY" == true ]]; then
  CURRENT_ARCH="$(uname -m)"
  BUILD_ARGS+=(
    "ARCHS=$CURRENT_ARCH"
    "ONLY_ACTIVE_ARCH=YES"
  )
fi

if [[ -n "$SIGNING_IDENTITY" ]]; then
  BUILD_ARGS+=("CODE_SIGN_IDENTITY=$SIGNING_IDENTITY")
fi

ARCHIVE_CMD=(
  xcodebuild
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -archivePath "$ARCHIVE_PATH"
  archive
  SKIP_INSTALL=NO
  STRIP_INSTALLED_PRODUCT=YES
  COPY_PHASE_STRIP=YES
)

if [[ "$ALLOW_PROVISIONING" == true ]]; then
  ARCHIVE_CMD+=(-allowProvisioningUpdates)
fi

ARCHIVE_CMD+=("${BUILD_ARGS[@]}")

echo "==> Archiving ($SCHEME $CONFIGURATION)"
"${ARCHIVE_CMD[@]}"

echo "==> Exporting signed app"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_PLIST"

APP_PATH="$(find "$EXPORT_PATH" -maxdepth 1 -type d -name "*.app" -print -quit)"
[[ -n "$APP_PATH" ]] || fail "No exported .app found in $EXPORT_PATH"

APP_NAME="$(basename "$APP_PATH" .app)"
NOTARIZE_ZIP="$TMP_DIR/$APP_NAME-$VERSION-notary.zip"
FINAL_ZIP="$OUTPUT_DIR/$APP_NAME-$VERSION-notarized.zip"
FINAL_SHA="$FINAL_ZIP.sha256"
FINAL_APP="$OUTPUT_DIR/$APP_NAME.app"

echo "==> Creating zip for notarization"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$NOTARIZE_ZIP"

echo "==> Submitting for notarization"
xcrun notarytool submit "$NOTARIZE_ZIP" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait \
  --output-format json > "$NOTARY_JSON"

if ! grep -q '"status"[[:space:]]*:[[:space:]]*"Accepted"' "$NOTARY_JSON"; then
  echo "Notarization response:"
  cat "$NOTARY_JSON"
  fail "Notarization did not return Accepted status."
fi

echo "==> Stapling app"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "==> Preparing distributable artifacts"
rm -rf "$FINAL_APP"
cp -R "$APP_PATH" "$FINAL_APP"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$FINAL_ZIP"
shasum -a 256 "$FINAL_ZIP" > "$FINAL_SHA"

if [[ "$PUBLISH_GITHUB" == true ]]; then
  echo "==> Publishing to GitHub release: $REPO ($TAG)"
  if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    gh release upload "$TAG" "$FINAL_ZIP" "$FINAL_SHA" --repo "$REPO" --clobber
  else
    CREATE_ARGS=(
      gh release create "$TAG" "$FINAL_ZIP" "$FINAL_SHA"
      --repo "$REPO"
      --title "$APP_NAME $VERSION"
    )
    if [[ -n "$NOTES_FILE" ]]; then
      CREATE_ARGS+=(--notes-file "$NOTES_FILE")
    else
      CREATE_ARGS+=(--notes "Automated notarized release $VERSION")
    fi
    "${CREATE_ARGS[@]}"
  fi
fi

echo
echo "Release complete."
echo "App: $FINAL_APP"
echo "Zip: $FINAL_ZIP"
echo "SHA: $FINAL_SHA"
