#!/bin/bash
# UpPear app build script.
# Added for UpPear on 2026-10-14 by WorkBuddy (接管续作).
# Modified by Codex on 2026-10-14: embed the actual UpPear source revision.
#
# Builds the native Xcode app target (UpPear.xcodeproj / scheme "UpPear").
# DerivedData is kept OUTSIDE the project folder (default /private/tmp/UpPear-dd)
# so the build products do not pick up FileProvider extended attributes that
# break codesign, and so the project tree stays clean.
#
# Usage: scripts/build_app.sh [Debug|Release]
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-Debug}"
UPPEAR_BUILD_DESTINATION='platform=macOS'
if [[ "$CONFIGURATION" == Release ]]; then
  UPPEAR_BUILD_DESTINATION='generic/platform=macOS'
fi
DERIVED_DATA="${UPPEAR_DERIVED_DATA:-/private/tmp/UpPear-dd}"
UPPEAR_SOURCE_REVISION="${UPPEAR_SOURCE_COMMIT:-}"
if [[ -z "$UPPEAR_SOURCE_REVISION" ]]; then
  if [[ "$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null || true)" == "$PROJECT_DIR" ]]; then
    UPPEAR_SOURCE_REVISION="$(git -C "$PROJECT_DIR" rev-parse HEAD)"
  elif [[ -f "$PROJECT_DIR/SOURCE_REVISION" ]]; then
    # The source archive has no .git directory but retains its exact revision.
    UPPEAR_SOURCE_REVISION="$(cat "$PROJECT_DIR/SOURCE_REVISION")"
  else
    UPPEAR_SOURCE_REVISION="unversioned"
  fi
fi

cd "$PROJECT_DIR"

xcodebuild \
  -project UpPear.xcodeproj \
  -scheme UpPear \
  -configuration "$CONFIGURATION" \
  -destination "$UPPEAR_BUILD_DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  UPPEAR_SOURCE_COMMIT="$UPPEAR_SOURCE_REVISION" \
  build

APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/UpPear.app"
echo "Built: $APP"
