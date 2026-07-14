# Quota Blocks

A compact, native macOS menu bar app for seeing your remaining ChatGPT/Codex and Claude subscription quotas at a glance.

The 78 × 22 pt menu bar item uses two rows. Each row contains a provider icon, five small blocks, and the remaining weekly percentage. Click it for full reset dates and Claude’s 5-hour, weekly, and Fable limits. The menu can switch between English and Chinese.

> Quota Blocks is an independent, unofficial open-source project. It is not affiliated with, endorsed by, or sponsored by OpenAI or Anthropic.

## What it reads

- **ChatGPT/Codex:** the seven-day rate-limit window exposed by the locally installed ChatGPT or Codex app server.
- **Claude:** the local Claude Code OAuth session and Anthropic’s usage endpoint, including the 5-hour session, weekly all-models limit, and Fable limit when present.
- Percentages always mean **remaining quota**, not used quota.
- Credentials stay on the Mac and are never included in the app bundle or repository. See [PRIVACY.md](PRIVACY.md).

## Requirements

- macOS 14 or later.
- ChatGPT/Codex installed and signed in for the ChatGPT row.
- Claude Code signed in for the Claude row.
- Xcode Command Line Tools when installing from source.

## Install from source

Clone the repository, then run:

```bash
./scripts/install-local.sh
```

This builds the app locally, installs it in `/Applications`, and opens it. You can also give this repository URL to an AI coding agent and ask it to run the same installer.

Build without installing:

```bash
./scripts/build-app.sh
```

Run parser tests and a live local probe:

```bash
swift run QuotaBlocks --self-test
"dist/Quota Blocks.app/Contents/MacOS/QuotaBlocks" --probe-live
```

## 中文

Quota Blocks 是一个原生 macOS 菜单栏小应用，用两行紧凑信息同时显示 ChatGPT／Codex 与 Claude 的剩余额度。

每行包含服务图标、5 个小额度块和周剩余百分比。点击后可查看完整重置日期，以及 Claude 的 5 小时、周额度和 Fable 限额；菜单支持中英文切换。

安装前请先登录 ChatGPT／Codex 与 Claude Code，然后运行：

```bash
./scripts/install-local.sh
```

应用每 2 分钟自动刷新。它不会重置额度，也没有“立即刷新／重置”按钮。

## Attribution

The ChatGPT and Claude SVG paths are adapted from the MIT-licensed [CodexBar](https://github.com/steipete/CodexBar). OpenAI, ChatGPT, Anthropic, Claude, and Fable are trademarks of their respective owners.

## License

[MIT](LICENSE)
