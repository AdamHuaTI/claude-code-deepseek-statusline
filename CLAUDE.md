# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A single-file status line (`ds-statusline`, Python 3, standard library only) plus an installer that
make Claude Code behave correctly when it is pointed at an Anthropic-compatible provider instead of
Anthropic's own API — most commonly DeepSeek.

There is no build step, no package manifest and no test framework. The only artefact the CLI
consumes is the status line script, referenced by absolute path from `~/.claude/settings.json`.

## Commands

Run the status line by hand. It reads a JSON payload on stdin and writes display lines to stdout:

```
echo '{"model":{"display_name":"deepseek-flash[1m]"},"context_window":{"total_input_tokens":25567}}' | ./ds-statusline
```

Smoke-test against a real session transcript, which is the shape Claude Code actually sends:

```
echo "{\"transcript_path\":\"$HOME/.claude/projects/<project>/<session-id>.jsonl\",\"model\":{\"display_name\":\"deepseek-flash[1m]\"},\"context_window\":{\"total_input_tokens\":25567}}" | ./ds-statusline
```

Exercise the failure paths — a status line that raises breaks the UI, so these matter more than the
happy path:

```
echo '' | ./ds-statusline
echo '{"model":{"display_name":"m"}}' | ./ds-statusline
echo 'not json' | ./ds-statusline
```

Check the installer's JSON merge without clobbering a real config. `CLAUDE_DIR` redirects every
path it touches, so this is safe to run against a temp directory:

```
CLAUDE_DIR=$(mktemp -d) ./install.sh
CLAUDE_DIR=$(mktemp -d) ./install.sh --deepseek
CLAUDE_DIR=$(mktemp -d) ./install.sh --with-1m-suffix
CLAUDE_DIR=$(mktemp -d) ./install.sh --deepseek --compact-window 500k
CLAUDE_DIR=$(mktemp -d) ./install.sh --uninstall
```

Confirm the `ANTHROPIC_BASE_URL` gating in `detect_preset()` still holds — `claude-*` names must
only map onto DeepSeek presets when the base URL is DeepSeek's:

```
python3 -c "
import os; os.environ['ANTHROPIC_BASE_URL']='https://api.deepseek.com/anthropic'
src=open('ds-statusline').read(); m=type(os)('m'); exec(compile(src,'ds-statusline','exec'), m.__dict__)
m._SETTINGS_ENV={}
print(m.detect_preset('claude-opus-4-8'), m.detect_preset('deepseek-flash[1m]'))
"
```

Validate a settings edit before starting a session — a malformed file silently disables the config:

```
python3 -m json.tool ~/.claude/settings.json
```

## Why the configuration is shaped this way

Claude Code identifies models by name and cannot ask a provider for its context window. For any
model id it does not recognise, its resolver ends in a hardcoded fallback:

```js
function Gv(model, betas){
  if (FH(process.env.DISABLE_COMPACT) && process.env.CLAUDE_CODE_MAX_CONTEXT_TOKENS) return parseInt(...);
  if (IZ(model)) return 1e6;   // model name carries a "[1m]" suffix
  ...
  return Z36;                  // Z36 = 200000
}
```

So an unrecognised model of any real size is treated as 200 000. For a model with a 1M window that
is roughly five times too small: the built-in context percentage is inflated, auto-compaction fires
at ~92 % of 200 k (≈184 k) and discards context the model could still hold, and `/cost` takes the
`tengu_unknown_model_cost` path and prices the tokens with an Anthropic rate table.

On Claude Code 2.1.160 the two environment variables that appear to address this do not:

- `CLAUDE_CODE_MAX_CONTEXT_TOKENS` is only honoured when `DISABLE_COMPACT` is set, which disables
  the very feature being fixed.
- `CLAUDE_CODE_AUTO_COMPACT_WINDOW` is applied as `min(Gv(), configured)`, so it can only lower the
  window — never raise it.

The one working lever is the `[1m]` name suffix, which makes `Gv()` return `1e6`. DeepSeek accepts
and echoes a bracketed model name, so no proxy or rewrite is needed. That is why the documented
configuration carries the suffix on the long-context slots — `ANTHROPIC_MODEL`,
`ANTHROPIC_DEFAULT_OPUS_MODEL`, `ANTHROPIC_DEFAULT_SONNET_MODEL` and `model` — but not on the
small/fast slot (`ANTHROPIC_DEFAULT_HAIKU_MODEL`), which never accumulates long context and is
deliberately left on the cheaper unsuffixed id.

The residual gap is that `Gv()` returns exactly `1000000` while DeepSeek's real window is
`1048576`. That is why the status line overrides the window itself rather than trusting
`context_window.context_window_size` from the payload.

## Model and pricing data

`PRESETS` and `ALIASES` encode what DeepSeek serves. As of 2026-10, every model DeepSeek offers
has a 1M window and 384K max output, and the generation has converged on a single model:

- `deepseek-flash` is DeepSeek-V4.1-Flash, the current model.
- `deepseek-v4-pro` is being **phased out**. Since 04:00 UTC on 2026-09-14 every request has been
  served by V4.1-Flash and billed at V4.1-Flash rates, until V4.1-Pro launches. Both presets
  therefore carry Flash rates; the V4-Pro card is kept in a comment in `ds-statusline` to restore.
  Do not "fix" this by copying the Pro column out of the pricing page without checking the current
  release notes first — it over-estimates cost roughly four-fold.
- `deepseek-v4-flash`, `deepseek-v4-flash-vision-exp`, `deepseek-chat` and `deepseek-reasoner`
  are legacy ids that are still accepted and still resolve to the current 1M model. A 160K-token
  request against `deepseek-chat` succeeds, which is what rules out the old 128K V3 model.
- `deepseek-v4.1-flash` and similar spellings are **rejected** — the API's error message names
  `deepseek-flash` and `deepseek-v4-pro` as the supported ids.

Verified facts behind these claims were obtained from the live API rather than the docs, which
lag: `GET /models` for windows, `GET /user/balance` for billing, and a token-length probe for
legacy ids. Prefer repeating those probes over trusting a stale table.

## How the status line works

Claude Code pipes a JSON payload to the status line command on stdin. The fields that matter are
`transcript_path`, `model.display_name` and `context_window.total_input_tokens`. The payload's
`cost.total_cost_usd` is computed with the wrong rate table and is deliberately ignored.

Three derived quantities, in the order `render()` assembles them:

- **Context** — `total_input_tokens / window`, where the window comes from `context_window()`
  (`DS_CONTEXT_WINDOW`, else the detected preset, else 1048576). When
  `CLAUDE_CODE_AUTO_COMPACT_WINDOW` is set, the threshold it implies is appended to the context
  detail — that is the number that actually decides when context is discarded, so it is more
  actionable than the window itself.
- **Cost** — from `aggregate()`, which streams the session transcript and sums
  `cache_read_input_tokens` (cache hit), `input_tokens` + `cache_creation_input_tokens`
  (cache miss) and `output_tokens`, then applies the resolved rate table for the current
  peak/off-peak window.
- **Balance** — `balance()`, an optional provider endpoint parsed by `parse_balance()`.

Model-to-preset matching lives in `detect_preset()` and is deliberately fuzzy (substring match on
the normalised id) because providers alias model names freely.

## Constraints to preserve

- **The script must never raise.** `main()` wraps `render()` and falls back to printing a bare
  model name. A status line that exits non-zero or prints nothing degrades the UI.
- **No secrets in the repository.** The API key is read at run time from `ANTHROPIC_AUTH_TOKEN` or
  `ANTHROPIC_API_KEY`, falling back to the `env` block of `~/.claude/settings.json`. Do not inline
  it into the script, the installer, the docs or any test fixture.
- **Deduplicate transcript records by `message.id`.** A single assistant turn is written to the
  JSONL once per streamed update, so summing without de-duplication overstates cost several-fold.
- **Keep `install.sh` non-destructive.** It must back up `settings.json` before writing, preserve
  unrelated keys, and be reversible via `--uninstall`. It must not invent settings the user never
  had — `--with-1m-suffix` only rewrites model names that are already configured, and the
  small/fast slot is left alone unless already set, because DeepSeek's guide covers it with
  `ANTHROPIC_DEFAULT_HAIKU_MODEL` instead.
- **Parse token counts leniently.** `CLAUDE_CODE_AUTO_COMPACT_WINDOW` accepts `786432`, `500k` and
  `1M`, so `parse_token_count()` handles all three. A plain `int()` here silently drops the
  auto-compact marker from the display for anyone using the suffixed form.
- **Gate the `claude-*` mapping on the base URL.** `detect_preset()` maps `claude-opus*` and
  `claude-sonnet*` onto DeepSeek presets only when `ANTHROPIC_BASE_URL` actually points at
  DeepSeek; otherwise a genuine Anthropic model would be mispriced.
- **Peak hours** are 01:00–04:00 and 06:00–10:00 UTC, Monday–Friday, excluding Chinese public
  holidays; weekends are off-peak. Holiday dates are not modelled, so a holiday weekday is billed
  as peak, which over-estimates rather than under-estimates.
- **Pricing is a published-rate estimate, not a bill.** Verify `PRESETS` against the provider's
  current pricing page before changing it, and prefer adding a preset over hardcoding a value.
