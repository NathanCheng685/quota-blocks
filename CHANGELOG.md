# Changelog

## Unreleased

- Read Claude Code’s file-based credentials (`~/.claude/.credentials.json`, primary since Claude Code 2.1) alongside the legacy Keychain item, and pick the freshest usable token.
- When the stored Claude access token has expired, ask Claude Code to refresh itself with a no-cost `claude` CLI probe instead of reporting “signed out”; Quota Blocks still never refreshes or rewrites the shared rotating tokens.
- Distinguish “credentials expired” from “not signed in”, and add a `--probe-credentials` diagnostic mode that reports credential sources and Security framework status codes without printing secrets.
- Read current Claude Code OAuth credentials from macOS Keychain without refreshing or rewriting Claude Code’s rotating tokens.
- Keep the last known quota on temporary network failures while surfacing signed-out states immediately.
- Added weekdays to English reset dates.
- Added launch-at-login by default with a bilingual menu toggle.

## 0.1.0 — 2026-07-14

- Added a compact two-row menu bar view for remaining ChatGPT and Claude weekly quota.
- Added detailed Claude 5-hour, weekly, and Fable limits.
- Added complete reset dates.
- Added a persistent Chinese／English menu switch.
- Added automatic background refresh every two minutes.
