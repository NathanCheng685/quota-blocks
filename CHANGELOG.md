# Changelog

## Unreleased

- Name the exact Claude plan in the menu, the way Claude Code does: the display name from the account profile when the server sends one (for example “Pro 100”), otherwise the Max tier (“Max 5x”, “Max 20x”). The credential’s subscription type only says “pro” or “max” and can lag behind the subscription, so it is now the fallback. The profile is read at most every six hours.
- Show Claude limit resets granted to the account (for example the Claude Opus 5.5 launch reset): how many are left and the deadline, with the grant name as a tooltip. Quota Blocks only displays them; spending one stays a `/limit-reset` in Claude Code. The usage request now identifies itself with the installed Claude Code version, since Anthropic only reports resets to a recent CLI.
- Show the ChatGPT/Codex 5-hour session window in the menu alongside the weekly limit whenever the app server reports one, with its own reset date.
- Show the current subscription plan next to each provider name in the menu (for example “ChatGPT · Pro 100”, “Claude · Max”), read from the ChatGPT/Codex app server’s plan type and the Claude credential’s subscription type.
- Read the Claude keychain item by running `/usr/bin/security` — the same system tool Claude Code writes it with — instead of an in-process Keychain query, so macOS no longer shows a keychain password dialog on every refresh.
- Treat a credential with `expiresAt: 0` as “unknown expiry” instead of “expired since 1970”, and treat a blanked keychain stub (empty tokens) as signed out; both patterns appear after Claude Code storage migrations.
- Honor HTTP 429 `Retry-After` from the Claude usage endpoint: keep showing the last snapshot, skip refreshes until the announced time, and say so in the menu.
- Explain unavailability in the menu with the concrete reason and fix — signed out (including the exact `claude` + `/login` command for Claude), expired credentials, rate limited (with the retry time), or a temporary error.
- Also run the no-cost `claude` refresh probe when no credentials are readable at all, so the app self-heals after Claude Code moves its credential storage.
- Recognize the local self-signed Quota Blocks code-signing identity during builds so reinstalling does not silently fall back to ad-hoc signing.
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
