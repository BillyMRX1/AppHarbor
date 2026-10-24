#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${APPHARBOR_APP_PATH:-$REPO_ROOT/dist/AppHarbor.app}"
if [[ ! -d "$APP_PATH" ]]; then
  "$REPO_ROOT/Scripts/build-app.sh"
fi
open -n "$APP_PATH" --args "$@"
