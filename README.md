# MacStatusBarMonitor

MacStatusBarMonitor 是一个轻量的 macOS 状态栏监控工具，用紧凑的菜单栏文字实时显示 CPU、内存、磁盘和网络速度。

## Features

- 状态栏显示 `C` / `M` / `D` 百分比，分别代表 CPU、Memory、Disk。
- 网络上传和下载速度显示在右侧上下两行。
- 固定宽度绘制，数值刷新时不会因为字符长度变化抖动。
- 菜单内可查看详细数值、设置 `Refresh Rate`、切换 `Launch at Login`、退出应用。
- 只显示在 macOS 状态栏，不显示 Dock 图标。

## Install From Release

1. 打开仓库的 GitHub Releases 页面。
2. 下载最新的 `MacStatusBarMonitor-*-macos.dmg`。
3. 打开 DMG，把 `MacStatusBarMonitor.app` 拖到 `Applications`。
4. 启动应用后，在状态栏点击监控文本即可打开菜单。

如果 macOS 提示应用来自未识别开发者，是因为当前 Release 使用 ad-hoc 签名，没有 Apple Developer ID 公证。可以在 `System Settings > Privacy & Security` 里允许打开，或从源码自行构建。

## Local Build

Requirements:

- macOS 13 或更高版本
- Xcode Command Line Tools
- Swift 6 toolchain

Build the `.app`:

```bash
cd mac-status-bar-monitor
chmod +x scripts/build_app.sh
./scripts/build_app.sh
```

Build output:

```text
dist/MacStatusBarMonitor.app
```

Run locally:

```bash
open dist/MacStatusBarMonitor.app
```

## Package A Release Locally

生成和 GitHub Release 一致的安装包：

```bash
cd mac-status-bar-monitor
chmod +x scripts/build_app.sh scripts/package_release.sh
RELEASE_VERSION=v1.0.0 scripts/package_release.sh
```

Output:

```text
dist/release/MacStatusBarMonitor-v1.0.0-macos.dmg
dist/release/MacStatusBarMonitor-v1.0.0-macos.zip
dist/release/MacStatusBarMonitor-v1.0.0-checksums.txt
```

## GitHub Release Workflow

The workflow lives at `.github/workflows/release.yml`.

It runs automatically when pushing a tag that starts with `v`, for example:

```bash
git tag v1.0.0
git push origin v1.0.0
```

On tag builds, GitHub Actions will:

- build the Swift release binary
- create `MacStatusBarMonitor.app`
- package a DMG installer
- package a ZIP archive
- generate SHA256 checksums
- publish all assets to the matching GitHub Release

You can also run the workflow manually from GitHub Actions. Manual runs always upload workflow artifacts. Set `publish_release` to `true` if you also want the run to create or update a GitHub Release.

## Refresh Rate

Click the status bar item and open `Refresh Rate` to choose a common refresh interval:

- `1 Second`
- `2 Seconds`
- `5 Seconds`
- `10 Seconds`
- `30 Seconds`

The selected interval is stored in `UserDefaults`.

## Launch At Login

Click the status bar item and toggle `Launch at Login`. The app uses `SMAppService.mainApp` to register or unregister itself with macOS login items.

If the menu shows `Launch at Login (Requires Approval)`, open macOS Login Items settings and approve the app.

## How It Works

- CPU is calculated from `host_statistics` tick deltas.
- Memory is estimated from `host_statistics64` active, wired, and compressed pages.
- Disk usage reads the root filesystem `/`.
- Network speed is calculated from `getifaddrs` byte deltas across active non-loopback interfaces.
