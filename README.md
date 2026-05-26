# Easy Paste

<p>
  <strong>English</strong> |
  <a href="./README.zh-CN.md">简体中文</a>
</p>

Easy Paste is a native macOS clipboard manager focused on a fast, fluid Paste-like experience.

## Requirements

- macOS 13.0 or later.
- Xcode / Swift toolchain for source builds.

## Features

- Clipboard history for text, links, rich text, and images.
- Paste-style bottom panel with glass background, horizontal cards, search, and Pinboards.
- Fast first-frame rendering with async image, icon, and preview hydration.
- Quick paste: `Command + Shift + V`, `Command + 1...9`, `Command + Shift + 1...9`.
- Plain-text paste mode with `Shift`.
- Rich text preservation when the source provides RTF or HTML.
- Image cards with dimensions and file size.
- Local SQLite + blob storage under `~/Library/Application Support/EasyPaste/`.

## Build

```bash
swift run EasyPaste
swift run EasyPaste -- --show-on-launch
swift test
```

Package the app:

```bash
./scripts/build_app.sh
```

Outputs:

```text
dist/EasyPaste.app
dist/EasyPaste-beta.zip
```

## Permission

Easy Paste needs macOS Accessibility permission to listen for fallback shortcuts and send `Command + V` to the active app.

```text
System Settings -> Privacy & Security -> Accessibility -> Easy Paste
```

## TODO

- Format paste/output workflow for JSON, XML, YAML, SQL, Markdown, and plain text.
