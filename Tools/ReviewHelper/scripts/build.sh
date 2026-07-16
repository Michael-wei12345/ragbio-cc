#!/bin/bash
set -euo pipefail

helper_root="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="$(cd "$helper_root/../.." && pwd)"
destination="$repo_root/.build/review-helper/dev/helper"

cd "$helper_root"
npm ci
npm test
npm run build

rm -rf "$destination"
mkdir -p "$destination"
cp -R dist package.json package-lock.json "$destination/"
cd "$destination"
npm ci --omit=dev --ignore-scripts
