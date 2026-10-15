#!/bin/bash
# UpPear local 1.0 packaging. Codex, 2026-10-14.
# Uses the existing WB build script and keeps staging outside FileProvider.
# No publishing, signing identity selection, installation, or app upgrade.
set -euo pipefail

UPPEAR_PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPPEAR_DD="${UPPEAR_DERIVED_DATA:-/private/tmp/UpPear-dd}"
UPPEAR_STAGING="$(mktemp -d /private/tmp/UpPear-package.XXXXXX)"
trap 'rm -rf "$UPPEAR_STAGING"' EXIT
cd "$UPPEAR_PROJECT_DIR"

if ! git diff --quiet || ! git diff --cached --quiet || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
  echo "Save a local source checkpoint before packaging so the app and source archive match." >&2
  exit 1
fi
python3 - <<'PY'
from pathlib import Path
import subprocess
original = subprocess.check_output(['git', 'show', '5.4.3:LICENSE.md'])
assert Path('LICENSE.md').read_bytes() == original, 'Upstream license has changed'
assert Path('UpPear/Resources/LICENSE.md').read_bytes() == original, 'Bundled license differs'
PY

scripts/build_app.sh Release
UPPEAR_APP="$UPPEAR_DD/Build/Products/Release/UpPear.app"
UPPEAR_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$UPPEAR_APP/Contents/Info.plist")"
UPPEAR_PACKAGE="UpPear-$UPPEAR_VERSION-macOS-arm64"
UPPEAR_RELEASE_DIR="$UPPEAR_STAGING/$UPPEAR_PACKAGE"
mkdir -p "$UPPEAR_RELEASE_DIR" dist
/usr/bin/ditto --noextattr --norsrc "$UPPEAR_APP" "$UPPEAR_RELEASE_DIR/UpPear.app"
cp LICENSE.md NOTICE.md THIRD_PARTY_NOTICES.md "$UPPEAR_RELEASE_DIR/"
cp UpPear/Resources/Sparkle-LICENSE.txt "$UPPEAR_RELEASE_DIR/"
cp docs/RELEASE_README.md "$UPPEAR_RELEASE_DIR/README.md"
/usr/bin/codesign --verify --deep --strict "$UPPEAR_RELEASE_DIR/UpPear.app"

UPPEAR_RELEASE_MANIFEST="$UPPEAR_RELEASE_DIR/build-manifest.json" \
UPPEAR_RELEASE_APP="$UPPEAR_RELEASE_DIR/UpPear.app" python3 - <<'PY'
from pathlib import Path
import json, os, plistlib, hashlib, subprocess
app = Path(os.environ['UPPEAR_RELEASE_APP'])
info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
manifest = {
    'product': 'UpPear', 'author': 'suchsu', 'version': info['CFBundleShortVersionString'],
    'sourceCommit': info['UpPearSourceCommit'],
    'upstreamCommit': info['UpPearUpstreamCommit'],
    'minimumMacOS': info['LSMinimumSystemVersion'], 'architecture': 'arm64',
    'signing': 'ad-hoc', 'notarized': False, 'sparkle': '2.8.0',
    'licenseSHA256': hashlib.sha256(Path('LICENSE.md').read_bytes()).hexdigest(),
    'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
    'appIcon': {
        'format': 'Icon Composer', 'name': 'UpPear',
        'sourceSHA256': {
            str(path.relative_to('UpPear/Resources/UpPear.icon')): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(Path('UpPear/Resources/UpPear.icon').rglob('*')) if path.is_file()
        },
    },
}
Path(os.environ['UPPEAR_RELEASE_MANIFEST']).write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n')
PY

/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$UPPEAR_RELEASE_DIR" "dist/$UPPEAR_PACKAGE.zip"
git archive --format=zip --prefix="UpPear-$UPPEAR_VERSION-source/" HEAD > "dist/UpPear-$UPPEAR_VERSION-source.zip"
UPPEAR_SOURCE_ZIP="dist/UpPear-$UPPEAR_VERSION-source.zip" \
UPPEAR_SOURCE_PREFIX="UpPear-$UPPEAR_VERSION-source/" python3 - <<'PY'
import os, subprocess, zipfile
revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
with zipfile.ZipFile(os.environ['UPPEAR_SOURCE_ZIP'], 'a') as archive:
    archive.writestr(os.environ['UPPEAR_SOURCE_PREFIX']+'SOURCE_REVISION', revision+'\n')
PY
# Deliver the sealed archive rather than copying an unzipped app into the
# Documents/FileProvider tree, which immediately restores FinderInfo and
# makes strict signature verification fail even after xattr removal.
(cd dist && shasum -a 256 "$UPPEAR_PACKAGE.zip" "UpPear-$UPPEAR_VERSION-source.zip" > SHA256SUMS.txt)
echo "Local package: $UPPEAR_PROJECT_DIR/dist/$UPPEAR_PACKAGE.zip"
