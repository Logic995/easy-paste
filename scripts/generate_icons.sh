#!/usr/bin/env bash
# 从当前图标源稿生成 macOS AppIcon.icns。
# 仅在修改图标源稿后运行；日常构建直接使用已提交的 icns。

set -euo pipefail

cd "$(dirname "$0")/.."

SOURCE="Assets/AppIcon-GeneratedMask.svg"
OUTPUT="Assets/AppIcon.icns"
ICONSET="$(mktemp -d)/AppIcon.iconset"

trap 'rm -rf "$(dirname "$ICONSET")"' EXIT

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "缺少 rsvg-convert。请先安装 librsvg：brew install librsvg" >&2
  exit 1
fi

mkdir -p "$ICONSET"

render() {
  local pixels="$1"
  local filename="$2"
  rsvg-convert --width "$pixels" --height "$pixels" "$SOURCE" > "$ICONSET/$filename"
}

render 16 icon_16x16.png
render 32 icon_16x16@2x.png
render 32 icon_32x32.png
render 64 icon_32x32@2x.png
render 128 icon_128x128.png
render 256 icon_128x128@2x.png
render 256 icon_256x256.png
render 512 icon_256x256@2x.png
render 512 icon_512x512.png
render 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o "$OUTPUT"
echo "已生成 $OUTPUT"
