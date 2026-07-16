#!/bin/bash
set -euo pipefail

script_root="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_root/../../.." && pwd)"
runtime_root="${1:-$repo_root/.build/review-spike/RagBio.app/Contents/Resources/ReviewRuntime}"
node_binary="$runtime_root/node"
codex_binary="$runtime_root/codex/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"

if [[ ! -x "$node_binary" || ! -x "$codex_binary" ]]; then
  echo "Review runtime is incomplete." >&2
  exit 1
fi

echo "Runtime root: $runtime_root"
echo "Node version: $($node_binary --version)"
echo "Node architecture: $(file "$node_binary")"
echo "Codex architecture: $(file "$codex_binary")"
echo "Runtime sizes:"
du -sh "$runtime_root" "$runtime_root/helper" "$runtime_root/codex"

echo "Node dynamic libraries:"
otool -L "$node_binary"
echo "Codex dynamic libraries:"
otool -L "$codex_binary"

echo "Node signature:"
codesign --verify --deep --strict --verbose=2 "$node_binary"
codesign -dv --verbose=4 "$node_binary" 2>&1
echo "Codex signature:"
codesign --verify --deep --strict --verbose=2 "$codex_binary"
codesign -dv --verbose=4 "$codex_binary" 2>&1
