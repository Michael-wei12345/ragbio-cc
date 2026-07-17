#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="RagBio"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
BUILD_SCRIPT="$ROOT_DIR/scripts/build-app.sh"
HELPER_DIR="$ROOT_DIR/Tools/ReviewHelper"
RUNTIME_DIR="$APP_DIR/Contents/Resources/ReviewRuntime"
NODE_VERSION="v24.18.0"
NODE_ARCHIVE="node-$NODE_VERSION-darwin-arm64.tar.gz"
NODE_CACHE="$HOME/Library/Caches/RagBioPackaging"
DEFAULT_NODE_BINARY="$NODE_CACHE/node-$NODE_VERSION-darwin-arm64/bin/node"
NODE_BINARY="${RAGBIO_NODE_BINARY:-$DEFAULT_NODE_BINARY}"

if [[ ! -x "$NODE_BINARY" && -z "${RAGBIO_NODE_BINARY:-}" ]]; then
    mkdir -p "$NODE_CACHE"
    curl -fL "https://nodejs.org/dist/$NODE_VERSION/$NODE_ARCHIVE" \
        -o "$NODE_CACHE/$NODE_ARCHIVE"
    curl -fsSL "https://nodejs.org/dist/$NODE_VERSION/SHASUMS256.txt" \
        -o "$NODE_CACHE/SHASUMS256.txt"
    (cd "$NODE_CACHE" && grep " $NODE_ARCHIVE\$" SHASUMS256.txt | shasum -a 256 -c -)
    tar -xzf "$NODE_CACHE/$NODE_ARCHIVE" -C "$NODE_CACHE"
fi

if [[ -z "$NODE_BINARY" || ! -x "$NODE_BINARY" ]]; then
    echo "A Node.js executable is required to package the Review Engine." >&2
    exit 1
fi

# Homebrew's Node executable can depend on libraries outside the app bundle.
# Accept only the official self-contained binary (or an equivalent override).
if otool -L "$NODE_BINARY" | tail -n +2 | awk '{print $1}' \
    | grep -Ev '^(/System/|/usr/lib/)' >/dev/null; then
    echo "The selected Node.js executable has non-system dynamic dependencies." >&2
    echo "Use the official Node.js macOS archive or set RAGBIO_NODE_BINARY accordingly." >&2
    exit 1
fi

if [[ "$(uname -m)" != "arm64" ]]; then
    echo "This internal packaging script currently produces the Apple Silicon build only." >&2
    exit 1
fi

"$BUILD_SCRIPT"

# Build and embed the complete local Review Engine. The installed app must not
# rely on Homebrew, a separate Codex installation, or this source checkout.
(cd "$HELPER_DIR" && npm run build)
rm -rf "$RUNTIME_DIR"
mkdir -p "$RUNTIME_DIR/helper"
cp "$NODE_BINARY" "$RUNTIME_DIR/node"
chmod 755 "$RUNTIME_DIR/node"
cp -R "$HELPER_DIR/dist" "$RUNTIME_DIR/helper/dist"
cp -R "$HELPER_DIR/workflow" "$RUNTIME_DIR/helper/workflow"
cp "$HELPER_DIR/package.json" "$HELPER_DIR/package-lock.json" "$RUNTIME_DIR/helper/"
cp -R "$HELPER_DIR/node_modules" "$RUNTIME_DIR/helper/node_modules"

# Remove build-only TypeScript tooling from the copied runtime while retaining
# the platform-specific Codex binary installed as an optional dependency.
(cd "$RUNTIME_DIR/helper" && npm prune --omit=dev --ignore-scripts)

# The bundled Node.js runtime requires macOS 13.5 or newer.
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 13.5" "$APP_DIR/Contents/Info.plist"

/usr/bin/xattr -cr "$APP_DIR"
codesign --force --deep --options runtime --timestamp=none --sign - "$APP_DIR"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_DIR/Contents/Info.plist")"
PACKAGE_NAME="$APP_NAME-macOS-arm64-$VERSION+$BUILD"
STAGING_DIR="$DIST_DIR/$PACKAGE_NAME"
ZIP_PATH="$DIST_DIR/$PACKAGE_NAME.zip"

rm -rf "$STAGING_DIR" "$ZIP_PATH"
mkdir -p "$STAGING_DIR"
cp -R "$APP_DIR" "$STAGING_DIR/$APP_NAME.app"

cat > "$STAGING_DIR/INSTALL.txt" <<'TXT'
RagBio 安装说明

系统要求：Apple Silicon Mac（M1/M2/M3/M4 或更新），macOS 13.5 或更新版本。

1. 把 RagBio.app 拖到“应用程序”文件夹。
2. 第一次打开时，如果 macOS 提示无法验证开发者：
   - 先右键点击 RagBio.app，选择“打开”；
   - 如果仍被拦截，进入“系统设置 > 隐私与安全性”，点击“仍要打开”。
3. 这是内部测试包。正式分发版本需要 Apple Developer ID 签名并 notarize，才能最大程度避免 Gatekeeper 拦截。

AI 搜索：请在 RagBio 的“设置”里配置测试者自己的大模型 API Key。不要共享个人 API Key。

Generate Review：不需要单独安装 Codex。第一次使用时，如果尚未登录，RagBio 会打开浏览器要求登录 ChatGPT；Review 会使用该 ChatGPT 账户可用的 Codex 额度。
TXT

/usr/bin/xattr -cr "$STAGING_DIR"
(cd "$DIST_DIR" && COPYFILE_DISABLE=1 /usr/bin/zip --symlinks -r -X "$PACKAGE_NAME.zip" "$PACKAGE_NAME" >/dev/null)

codesign --verify --deep --strict --verbose=2 "$STAGING_DIR/$APP_NAME.app"
spctl -a -vv --type execute "$STAGING_DIR/$APP_NAME.app" || true

/usr/bin/shasum -a 256 "$ZIP_PATH" > "$ZIP_PATH.sha256"

echo "Packaged $ZIP_PATH"
