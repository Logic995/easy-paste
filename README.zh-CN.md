# Easy Paste

[English](./README.md)

Easy Paste 是一个原生 macOS 剪贴板工具，目标是做出接近 Paste 的丝滑体验：复制后快速入列，面板快速呼出，选择后稳定粘贴。

## 主要功能

- 记录文本、链接、富文本和图片剪贴板历史。
- Paste 风格底部面板：玻璃背板、横向卡片、搜索、Pinboard 分组。
- 面板首帧轻量渲染，图片、应用图标、富文本预览异步补齐。
- 快速粘贴：
  - `Command + Shift + V`：呼出面板
  - `Command + 1...9`：直接粘贴对应卡片
  - `Command + Shift + 1...9`：以纯文本粘贴对应卡片
  - `←` / `→`：切换卡片
  - `Return`：粘贴选中卡片
  - `Esc`：关闭面板
- 按住 `Shift` 进入纯文本粘贴模式。
- 来源提供 RTF / HTML 时，原样粘贴会保留富文本格式。
- 图片卡片展示尺寸和大小。
- 搜索支持 `type:json`、`type:sql`、`app:Safari`、`pinned`、`today` 等 token。
- 设置支持主题、快捷键、粘贴行为、隐私、历史保留、忽略应用和玻璃透明度。

## 存储

本地数据保存在：

```text
~/Library/Application Support/EasyPaste/
```

- `EasyPaste.sqlite`：列表、搜索、设置等元信息。
- `Blobs/`：图片、RTF、HTML 等较大内容。

## 构建运行

```bash
swift run EasyPaste
```

启动时直接显示面板：

```bash
swift run EasyPaste -- --show-on-launch
```

开启性能日志：

```bash
swift run EasyPaste -- --debug-performance --show-on-launch
```

日志位置：

```text
~/Library/Application Support/EasyPaste/performance.log
```

## 打包

```bash
./scripts/build_app.sh
```

输出：

```text
dist/EasyPaste.app
dist/EasyPaste-beta.zip
```

安装到本机：

```bash
cp -R dist/EasyPaste.app /Applications/EasyPaste.app
open /Applications/EasyPaste.app
```

## 测试

```bash
swift test
```

测试覆盖内容类型识别、格式化辅助函数、设置、Pinboard、SQLite/Blob 迁移、Blob 保留、历史清理和 OCR 排序行为。

## 权限

Easy Paste 需要 macOS「辅助功能」权限，用于全局快捷键兜底监听，以及把 `Command + V` 发送回当前应用。

路径：

```text
系统设置 -> 隐私与安全性 -> 辅助功能 -> Easy Paste
```

## TODO

- 格式化输出 / 格式化粘贴工作流：支持 JSON、XML、YAML、SQL、Markdown、纯文本的低成本单手操作。
