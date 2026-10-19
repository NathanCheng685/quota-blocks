# Quota Blocks for macOS

A compact, native macOS menu bar app for seeing your remaining ChatGPT/Codex and Claude subscription quotas at a glance.

The menu bar item uses two compact rows and automatically adjusts between roughly 73–78 pt wide so percentages are never compressed. Each row contains a provider icon, five small blocks, and the remaining weekly percentage. Click it for your current plan next to each provider name (for example “ChatGPT · Pro” or “Claude · Max”), reset dates with weekdays, the 5-hour session and weekly limits for both providers, Claude’s Fable limit, and any limit reset Anthropic has granted your Claude account (how many are left and the deadline). When a provider cannot be read, the menu says exactly why — signed out (with the command that fixes it), expired credentials, or a temporarily rate-limited endpoint. The menu can switch between English and Chinese and control whether Quota Blocks launches at login.

> Quota Blocks is an independent, unofficial open-source project. It is not affiliated with, endorsed by, or sponsored by OpenAI or Anthropic.

## What it reads

- **ChatGPT/Codex:** the five-hour session and seven-day rate-limit windows exposed by the locally installed ChatGPT or Codex app server.
- **Claude:** the local Claude Code OAuth session and Anthropic’s usage endpoint, including the 5-hour session, weekly all-models limit, and Fable limit when present. Claude Code has stored its session in the login keychain (2.0, 2.2+) and in `~/.claude/.credentials.json` (2.1); Quota Blocks reads both and uses the freshest usable token. The keychain item is read by running `/usr/bin/security` — the same system tool Claude Code writes it with — so macOS never shows a keychain password dialog for Quota Blocks. Quota Blocks treats these credentials as strictly read-only; Claude Code remains responsible for login and token refresh. When the stored access token has expired or gone missing, Quota Blocks runs your own `claude` CLI once with a deliberately invalid model name — Claude Code refreshes its own session first and the request fails before consuming any quota — then simply re-reads what Claude Code wrote.
- **Claude limit resets:** the same usage request also returns one-off resets granted to the account, such as a model launch promotion. Anthropic only reports them to a recent Claude Code CLI, so the request identifies itself with the version of `claude` you have installed. Quota Blocks only shows a reset; spending one stays a deliberate `/limit-reset` in Claude Code.
- The plan shown next to each provider comes from the same local data: the ChatGPT/Codex app server reports its plan type, and the Claude credential records the subscription type.
- Percentages always mean **remaining quota**, not used quota.
- Credentials stay on the Mac and are never included in the app bundle or repository. See [PRIVACY.md](../PRIVACY.md).

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

每行包含服务图标、5 个小额度块和周剩余百分比。点击后可以在 ChatGPT／Claude 名称右侧看到当前订阅方案（例如「ChatGPT · Pro」「Claude · Max」），并查看包含星期的完整重置日期，以及 ChatGPT 和 Claude 的 5 小时、周额度与 Claude 的 Fable 限额，以及 Anthropic 给 Claude 账号的重置机会（剩余次数和截止时间）；无法读取时菜单会直接说明原因（未登录时附带修复命令、凭据过期或接口临时限流）。菜单支持中英文切换和开机自动启动开关。

安装前请先登录 ChatGPT／Codex 与 Claude Code，然后运行：

```bash
./scripts/install-local.sh
```

应用每 2 分钟自动刷新，并在首次运行后默认开机自动启动。它不会重置额度，也没有“立即刷新／重置”按钮；重置机会只做显示，要用时在 Claude Code 里运行 /limit-reset。

## Attribution

The ChatGPT and Claude SVG paths are adapted from the MIT-licensed [CodexBar](https://github.com/steipete/CodexBar). OpenAI, ChatGPT, Anthropic, Claude, and Fable are trademarks of their respective owners.

## License

[MIT](../LICENSE)
