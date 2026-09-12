#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
app_version="${1:?Usage: scripts/set-version.sh X.Y or X.Y.Z}"
[[ "$app_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo 'Use a numeric X.Y or X.Y.Z version.' >&2; exit 1; }
printf '%s\n' "$app_version" > VERSION
