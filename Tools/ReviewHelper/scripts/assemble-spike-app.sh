#!/bin/bash
set -euo pipefail

helper_root="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="$(cd "$helper_root/../.." && pwd)"
output_root="$repo_root/.build/review-spike"
app="$output_root/RagBio.app"
contents="$app/Contents"
runtime="$contents/Resources/ReviewRuntime"
node_binary="${RAGBIO_REVIEW_NODE_BINARY:-$(command -v node)}"

if [[ ! -x "$node_binary" ]]; then
  echo "A runnable Node binary is required." >&2
  exit 1
fi

"$helper_root/scripts/build.sh"
cd "$repo_root"
swift build
swift_bin_path="$(swift build --show-bin-path)"

rm -rf "$output_root"
mkdir -p "$contents/MacOS" "$runtime/codex"
cp "$swift_bin_path/RagBio" "$contents/MacOS/RagBio"
cp -L "$node_binary" "$runtime/node"
cp -R "$repo_root/.build/review-helper/dev/helper" "$runtime/helper"

platform_package="$runtime/helper/node_modules/@openai/codex-darwin-arm64"
if [[ ! -d "$platform_package" ]]; then
  echo "Pinned arm64 Codex runtime is missing." >&2
  exit 1
fi
mv "$platform_package" "$runtime/codex/codex-darwin-arm64"
ln -s ../../../codex/codex-darwin-arm64 "$platform_package"

info_plist="$contents/Info.plist"
plutil -create xml1 "$info_plist"
plutil -insert CFBundleDevelopmentRegion -string en "$info_plist"
plutil -insert CFBundleExecutable -string RagBio "$info_plist"
plutil -insert CFBundleIdentifier -string com.local.RagBio.ReviewSpike "$info_plist"
plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$info_plist"
plutil -insert CFBundleName -string RagBio "$info_plist"
plutil -insert CFBundlePackageType -string APPL "$info_plist"
plutil -insert CFBundleShortVersionString -string 0.1.0 "$info_plist"
plutil -insert CFBundleVersion -string 1 "$info_plist"
plutil -insert LSMinimumSystemVersion -string 13.0 "$info_plist"

chmod +x "$contents/MacOS/RagBio" "$runtime/node"
echo "$app"
