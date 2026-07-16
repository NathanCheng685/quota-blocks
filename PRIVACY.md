# Privacy

Quota Blocks runs locally on your Mac. It does not operate a server, collect analytics, show ads, or send telemetry.

To display quota information, the app:

- starts the locally installed ChatGPT/Codex app server and requests local rate-limit data;
- reads the Claude Code OAuth credential already stored in macOS Keychain, with `~/.claude/.credentials.json` as a legacy fallback;
- sends that Claude access token only to Anthropic’s official usage endpoint at `api.anthropic.com`.

Claude Code credentials are read-only: Quota Blocks does not refresh, rotate, or write them. Credentials are never written into the app bundle, repository, logs, or a third-party service. Quota values are kept only in memory and refreshed every two minutes.

Opening a provider’s usage page from the menu launches that website in your default browser, where the provider’s own privacy policy applies.
