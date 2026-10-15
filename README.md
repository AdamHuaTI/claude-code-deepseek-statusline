# ds-statusline

A Claude Code status line that shows **true context usage, cost and balance** when Claude Code
is pointed at an Anthropic-compatible provider — and the configuration that makes
**auto-compaction fire at the right time**.

Ships with DeepSeek support, and works with any other provider via environment variables.

```
deepseek-flash  ctx █░░░░░░░░░  2.4%  (26k/1.0M · compact@786k)
$0.234  ·  bal CNY 12.34  ·  peak
```

## The problem

Claude Code recognises models by name. Point it at a provider it does not know — anything through
`ANTHROPIC_BASE_URL`, or any model id that is not a `claude-*` name — and its context-window
resolver falls back to a hardcoded **200,000 tokens**. It has no way to ask the provider for the
real value.

Everything derived from that number is then wrong:

| Symptom | Cause |
|---|---|
| Context percentage looks inflated | computed against 200k, not the real window |
| Auto-compaction fires far too early, discarding usable context | triggers at ~92% of the assumed window |
| `/cost` shows the wrong figure or an unknown-model warning | priced with an Anthropic rate table |

On a model with a 1M window, that assumed 200k is five times too small — so a long session gets
summarised and thrown away while the model still had ~800k tokens of room left.

The two environment variables that look like the fix do not work on current builds:

- `CLAUDE_CODE_MAX_CONTEXT_TOKENS` is only honoured when `DISABLE_COMPACT` is also set, which
  disables the very feature being fixed.
- `CLAUDE_CODE_AUTO_COMPACT_WINDOW` is applied as `min(assumed, configured)`, so on its own it can
  only *lower* the window — never raise it. It becomes useful only once the window is raised.

DeepSeek documents this workaround in its own
[Claude Code integration guide](https://api-docs.deepseek.com/quick_start/agent_integrations/claude_code),
which is what the installer follows.

## Install

```bash
git clone <this-repo> && cd claude_with_deepseek
./install.sh --deepseek
```

Then **restart Claude Code**. Environment variables are read at process start.

| Command | Effect |
|---|---|
| `./install.sh` | Register the status line only. |
| `./install.sh --deepseek` | Also apply DeepSeek's official Claude Code model environment. |
| `./install.sh --with-1m-suffix` | Raise the assumed window without changing model choices. |
| `./install.sh --compact-window 500k` | Override the auto-compact threshold (default `786432`). |
| `./install.sh --uninstall` | Reverse everything. |

`settings.json` is backed up before anything is written, and unrelated keys are preserved.

<details>
<summary>Manual install</summary>

Copy `ds-statusline` to `~/.claude/ds-statusline`, make it executable, and add to
`~/.claude/settings.json`:

```json
{
  "statusLine": { "type": "command", "command": "~/.claude/ds-statusline" },
  "env": {
    "ANTHROPIC_MODEL": "deepseek-flash[1m]",
    "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "786432"
  },
  "model": "deepseek-flash[1m]"
}
```
</details>

## Supported models

Every model DeepSeek currently serves has a **1M context window** and **384K max output**.

| Model id | Status | Notes |
|---|---|---|
| `deepseek-flash` | **current** | DeepSeek-V4.1-Flash. Supports vision. Use this. |
| `deepseek-v4-pro` | being phased out | Since 2026-09-14, requests route to V4.1-Flash and are **billed at V4.1-Flash rates**. |
| `deepseek-v4-flash` | legacy | Retired; routes to V4.1-Flash. |
| `deepseek-v4-flash-vision-exp` | legacy | Retired; routes to V4.1-Flash. |
| `deepseek-chat`, `deepseek-reasoner` | legacy | Still accepted and resolve to the 1M model. |

Because `deepseek-v4-pro` is currently served by V4.1-Flash, both presets carry **Flash** rates.
The V4-Pro rate card is preserved in a comment in `ds-statusline` to restore when V4.1-Pro ships.

If your endpoint is DeepSeek's, Claude model names are mapped server-side and the status line
follows the same rules: `claude-opus*` → `deepseek-v4-pro`, `claude-haiku*` / `claude-sonnet*` →
`deepseek-flash`.

## Why the `[1m]` suffix

Claude Code resolves the context window for any model whose name carries a `[1m]` suffix to
exactly 1,000,000 tokens, and strips the suffix before the request goes out. DeepSeek accepts and
echoes the bracketed name as-is, so no proxy or rewrite is needed.

The status line alone corrects what you *see*. The suffix is what corrects what the CLI *does* —
auto-compaction is scheduled from the CLI's own assumed window, not from the status line.

Only use it if your model's real window is about 1M. Otherwise leave the model name alone and set
`DS_CONTEXT_WINDOW` to the true value: that fixes the display without changing how compaction is
scheduled.

## Configuration

All optional. Defaults target DeepSeek.

| Variable | Default | Purpose |
|---|---|---|
| `DS_CONTEXT_WINDOW` | detected preset, else `1048576` | Context window. Accepts `1M`, `500k` or a plain number. |
| `DS_PRICING_JSON` | DeepSeek rates | Full pricing override (USD per 1M tokens), shape `{"peak":{...},"offpeak":{...}}`. |
| `DS_BALANCE_URL` | DeepSeek's endpoint | Balance API. Empty string disables it. |
| `DS_BALANCE_DISABLE` | unset | Set to `1` to skip the balance request entirely. |
| `DS_FORCE_OFFPEAK` | unset | Set to `1` to ignore peak pricing. |
| `DS_CURRENCY` | from the API response | Override the balance currency label. |

For a provider with no balance endpoint:

```bash
export DS_BALANCE_URL=""
```

`--deepseek` writes the environment DeepSeek's guide recommends:

```json
"env": {
  "ANTHROPIC_BASE_URL": "https://api.deepseek.com/anthropic",
  "ANTHROPIC_MODEL": "deepseek-flash[1m]",
  "ANTHROPIC_DEFAULT_OPUS_MODEL": "deepseek-flash[1m]",
  "ANTHROPIC_DEFAULT_SONNET_MODEL": "deepseek-flash[1m]",
  "ANTHROPIC_DEFAULT_HAIKU_MODEL": "deepseek-flash",
  "CLAUDE_CODE_SUBAGENT_MODEL": "deepseek-flash",
  "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "786432"
}
```

`CLAUDE_CODE_EFFORT_LEVEL=max` is in DeepSeek's guide but is deliberately **not** set here: it
raises thinking-token usage and therefore cost, so it is a trade-off rather than a fix.

## How it works

Claude Code pipes a JSON payload to the status line on stdin. The useful parts are
`transcript_path`, `model.display_name` and `context_window.total_input_tokens` — the last being
the raw, provider-agnostic context size of the most recent request. The payload's own
`cost.total_cost_usd` is computed with the wrong rate table and is ignored.

- **Context** — `total_input_tokens` divided by the real window, with the auto-compact threshold
  marked when `CLAUDE_CODE_AUTO_COMPACT_WINDOW` is set (that is the number that decides when
  context is actually discarded).
- **Cost** — the session transcript is streamed and summed, then priced at your provider's rates.
  Assistant records repeat in the transcript once per streamed update, so they are de-duplicated
  by `message.id`; without that, cost is overstated several-fold.
- **Balance** — fetched from the provider's balance endpoint.

Two caches keep it cheap, because the status line re-renders far more often than either input
changes: the transcript aggregate is memoised on `(size, mtime)` and the balance for 60 seconds.
A cold render is ~280 ms, dominated by the balance request; a warm one is ~60 ms.

## Caveats

- **Cost is an estimate** from token counts at published rates — not an authoritative bill.
- **Peak/off-peak pricing** uses UTC hours (01:00–04:00 and 06:00–10:00, Mon–Fri). Chinese public
  holidays are not modelled, so a holiday weekday is priced as peak — an over-estimate.
- **Rates and model availability change.** DeepSeek phased V4-Pro out mid-September 2026; verify
  against the [pricing page](https://api-docs.deepseek.com/quick_start/pricing) before relying on
  the figures.
- The script reads your API key from `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_API_KEY`, falling back
  to the `env` block of `~/.claude/settings.json`. **No credentials are stored in this repo.**
- Tested against Claude Code 2.1.160. The resolver behaviour it works around is version-specific;
  if a future release reads the window from the provider, the suffix becomes unnecessary.

## Requirements

Python 3.8+ (standard library only — no dependencies). No build step.

## License

MIT — see [LICENSE](LICENSE).
