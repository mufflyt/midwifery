#!/usr/bin/env bash
# Mirror this repo's gitignored files (data, artifacts, AMCB/NPI linkage
# files, manuscript builds) into a Dropbox folder for backup. Excludes pure
# build junk (node_modules, __pycache__, lockfiles, htmlwidget dependency
# dirs) that adds no value to keep and is trivially reinstalled.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --show-toplevel)"
DEST="$HOME/Dropbox/midwifery_gitignored_backup"

EXCLUDES=(
  --exclude 'node_modules/'
  --exclude '__pycache__/'
  --exclude '@archive/__pycache__/'
  --exclude 'tests/__pycache__/'
  --exclude 'package.json'
  --exclude 'package-lock.json'
  --exclude '*.lock'
  --exclude 'docs/cnm_national_leaflet_map_files/'
  --exclude 'docs/maps/midwifery_access_map_v2_files/'
)

cd "$REPO_ROOT"
mkdir -p "$DEST"

git status --ignored --porcelain \
  | awk '{print $2}' \
  | rsync -avh --files-from=- "${EXCLUDES[@]}" ./ "$DEST/"

echo "Backed up to $DEST"
