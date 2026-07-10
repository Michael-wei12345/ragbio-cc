#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="RagBio"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
BUILD_SCRIPT="$ROOT_DIR/scripts/build-app.sh"

"$BUILD_SCRIPT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_DIR/Contents/Info.plist")"
PACKAGE_NAME="$APP_NAME-macOS-$VERSION+$BUILD"
STAGING_DIR="$DIST_DIR/$PACKAGE_NAME"
ZIP_PATH="$DIST_DIR/$PACKAGE_NAME.zip"

rm -rf "$STAGING_DIR" "$ZIP_PATH"
mkdir -p "$STAGING_DIR"
cp -R "$APP_DIR" "$STAGING_DIR/$APP_NAME.app"

cat > "$STAGING_DIR/INSTALL.txt" <<'TXT'
RagBio 安装说明

1. 把 RagBio.app 拖到“应用程序”文件夹。
2. 第一次打开时，如果 macOS 提示无法验证开发者：
   - 先右键点击 RagBio.app，选择“打开”；
   - 如果仍被拦截，进入“系统设置 > 隐私与安全性”，点击“仍要打开”。
3. 这是内部测试包。正式分发版本需要 Apple Developer ID 签名并 notarize，才能最大程度避免 Gatekeeper 拦截。

使用前请在 RagBio 的“设置”里配置自己的大模型 API Key。不要共享个人 API Key。
TXT

/usr/bin/xattr -cr "$STAGING_DIR"
(cd "$DIST_DIR" && COPYFILE_DISABLE=1 /usr/bin/zip --symlinks -r -X "$PACKAGE_NAME.zip" "$PACKAGE_NAME" >/dev/null)

codesign --verify --deep --strict --verbose=2 "$STAGING_DIR/$APP_NAME.app"

echo "Packaged $ZIP_PATH"
