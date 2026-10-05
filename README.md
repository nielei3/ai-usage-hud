# UsageHUD

Menu-bar usage HUD for Claude Code and Codex. A single `NSStatusItem` shows the
tighter of the two providers' rate limits; clicking it opens a non-activating
`NSPanel` with today's token totals, the rolling 5-hour block (est) and every
rate-limit window the CLIs report.

## Build

```sh
swift build -c release
scripts/make-bundle.sh   # assembles build/UsageHUD.app (unsigned)
open build/UsageHUD.app  # or run the binary directly
```

## Sandbox

App Sandbox is intentionally **off** — the product reads `~/.claude/projects`
and `~/.codex/sessions` directly, and sandboxing it would break the whole point.
Do not enable it.

## Data locations

`DataLocations.resolve` reads env vars first, then falls back to the home
defaults:

| env var | default |
| --- | --- |
| `USAGE_HUD_CLAUDE_DIR` | `~/.claude/projects` |
| `USAGE_HUD_CODEX_DIR` | `~/.codex/sessions` |

The overrides exist for end-to-end fixtures — point them at a fixture tree and
launch the built binary directly so the environment reaches the process (an
`env` prefix on `open` does not survive LaunchServices).

## Tests

```sh
swift test   # 38 tests, 14 suites, all deterministic (manual clock + injected calendar)
```
