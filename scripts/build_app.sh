#!/usr/bin/env bash
# 构建 Easy Paste beta 版 Universal .app 并生成 pkg 安装包。
# 用法：./scripts/build_app.sh
# 输出：dist/EasyPaste.app  +  dist/EasyPaste-installer.pkg

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="EasyPaste"
DISPLAY_NAME="Easy Paste"
BUNDLE_ID="com.easypaste.app"
VERSION="0.1.0-beta"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
MIN_MACOS_VERSION="13.0"

DIST="dist"
APP_DIR="$DIST/$APP_NAME.app"
PKG_PATH="$DIST/$APP_NAME-installer.pkg"

echo "==> 清理旧产物"
rm -rf "$APP_DIR" "$PKG_PATH" "$DIST/$APP_NAME-beta.zip"

echo "==> Release Universal 编译（arm64 + x86_64）"
if ! swift build -c release --arch arm64 --arch x86_64; then
  echo "Universal 编译失败：需要同时产出 arm64 和 x86_64，已停止打包。" >&2
  exit 1
fi

# 找到 universal 产物路径。
BIN=""
for cand in \
  ".build/apple/Products/Release/$APP_NAME" \
  ".build/release/$APP_NAME"; do
  if [ -x "$cand" ]; then BIN="$cand"; break; fi
done
if [ -z "$BIN" ]; then
  echo "找不到 Universal release 二进制" >&2
  exit 1
fi
echo "==> 二进制：$BIN"

ARCH_INFO="$(lipo -info "$BIN" 2>/dev/null || true)"
echo "==> 架构：$ARCH_INFO"
if [[ "$ARCH_INFO" != *"x86_64"* || "$ARCH_INFO" != *"arm64"* ]]; then
  echo "Universal 架构校验失败：产物必须同时包含 x86_64 和 arm64。" >&2
  exit 1
fi

echo "==> 构造 .app bundle"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "Assets/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MIN_MACOS_VERSION</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Easy Paste 通过模拟 ⌘V 把内容粘贴回前台应用</string>
    <key>NSAccessibilityUsageDescription</key>
    <string>Easy Paste 需要辅助功能权限以便监听全局快捷键并把粘贴动作发送到前台应用</string>
</dict>
</plist>
EOF

# 简单的 PkgInfo
printf "APPL????" > "$APP_DIR/Contents/PkgInfo"

# 移除可能残留的扩展属性，避免 Gatekeeper 干扰
xattr -cr "$APP_DIR" 2>/dev/null || true

# 优先用稳定的本机 Apple Development 证书签名。
# ad-hoc 签名每次重打包都会改变代码身份，macOS 辅助功能/TCC 可能要求反复重新授权。
SIGN_IDENTITY="${EASYPASTE_CODESIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
    | head -1)"
fi

if [ -n "$SIGN_IDENTITY" ]; then
  echo "==> 签名：$SIGN_IDENTITY"
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"
else
  echo "==> Ad-hoc 签名（未找到本机代码签名证书）"
  codesign --force --deep --sign - "$APP_DIR" 2>&1 | tail -3 || true
fi

# codesign / local filesystem metadata may leave provenance xattrs. Strip them
# before pkgbuild so the installer payload does not contain AppleDouble files.
xattr -cr "$APP_DIR" 2>/dev/null || true
codesign --verify --deep --strict "$APP_DIR"

echo "==> 生成 pkg 安装包"
INSTALLER_IDENTITY="${EASYPASTE_INSTALLER_IDENTITY:-}"
if [ -z "$INSTALLER_IDENTITY" ]; then
  INSTALLER_IDENTITY="$(security find-identity -v -p basic 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Installer:[^"]*\)".*/\1/p' \
    | head -1)"
fi

if [ -n "$INSTALLER_IDENTITY" ]; then
  echo "==> pkg 签名：$INSTALLER_IDENTITY"
  COPYFILE_DISABLE=1 pkgbuild \
    --component "$APP_DIR" \
    --install-location "/Applications" \
    --identifier "$BUNDLE_ID.pkg" \
    --version "$VERSION" \
    --sign "$INSTALLER_IDENTITY" \
    "$PKG_PATH"
else
  echo "==> 未找到 Developer ID Installer 证书，生成未签名 pkg"
  echo "    未签名 pkg 适合本机测试；公开分发需要 Developer ID Installer 签名和 notarization。"
  COPYFILE_DISABLE=1 pkgbuild \
    --component "$APP_DIR" \
    --install-location "/Applications" \
    --identifier "$BUNDLE_ID.pkg" \
    --version "$VERSION" \
    "$PKG_PATH"
fi

echo
echo "完成 ✓"
echo "  - $APP_DIR"
echo "  - $PKG_PATH"
echo
echo "使用方法："
echo "  1) open $PKG_PATH  ，按安装器提示安装到 /Applications"
echo "  2) 首次运行右键 → 打开（绕过 Gatekeeper 提示，如系统需要）"
echo "  3) 系统设置 → 隐私与安全 → 辅助功能，给 $DISPLAY_NAME 打勾"
echo "  4) ⌘⇧V 呼出面板"
