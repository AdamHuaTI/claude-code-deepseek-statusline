#!/usr/bin/env bash
#
# Install the status line for Claude Code, and optionally configure the model.
#
#   ./install.sh                     install the status line only
#   ./install.sh --deepseek          also apply DeepSeek's official Claude Code
#                                    environment (recommended for DeepSeek users)
#   ./install.sh --with-1m-suffix    only raise the assumed context window
#   ./install.sh --uninstall         remove the status line registration
#
# Options:
#   --compact-window N   auto-compact threshold in tokens (default 786432)
#
# Your existing ~/.claude/settings.json is backed up before anything is written.

set -euo pipefail

CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
SCRIPT_NAME="ds-statusline"
SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$SCRIPT_NAME"
TARGET="$CLAUDE_DIR/$SCRIPT_NAME"

DEEPSEEK=0
SUFFIX=0
UNINSTALL=0
COMPACT_WINDOW=786432

while [ $# -gt 0 ]; do
    case "$1" in
        --deepseek) DEEPSEEK=1; SUFFIX=1 ;;
        --with-1m-suffix) SUFFIX=1 ;;
        --compact-window) shift; COMPACT_WINDOW="${1:?--compact-window needs a value}" ;;
        --uninstall) UNINSTALL=1 ;;
        -h|--help) sed -n '3,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

command -v python3 >/dev/null 2>&1 || {
    echo "error: python3 is required but was not found on PATH" >&2
    exit 1
}

mkdir -p "$CLAUDE_DIR"

if [ "$UNINSTALL" -eq 1 ]; then
    python3 - "$SETTINGS" <<'PY'
import json, os, sys
path = sys.argv[1]
if not os.path.exists(path):
    print("nothing to do: no settings.json")
    raise SystemExit(0)
with open(path, encoding="utf-8") as fh:
    settings = json.load(fh)
if settings.pop("statusLine", None) is not None:
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(settings, fh, indent=2)
        fh.write("\n")
    print("removed statusLine from", path)
else:
    print("nothing to do: statusLine was not registered")
PY
    rm -f "$TARGET"
    echo "uninstalled. restart Claude Code to apply."
    exit 0
fi

install -m 0755 "$SOURCE" "$TARGET"
echo "installed  $TARGET"

if [ ! -f "$SETTINGS" ]; then
    echo '{}' > "$SETTINGS"
fi
cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
echo "backed up  $SETTINGS"

python3 - "$SETTINGS" "$TARGET" "$SUFFIX" "$DEEPSEEK" "$COMPACT_WINDOW" <<'PY'
import json, sys

path, target = sys.argv[1], sys.argv[2]
suffix, deepseek = sys.argv[3] == "1", sys.argv[4] == "1"
compact_window = sys.argv[5]

with open(path, encoding="utf-8") as fh:
    settings = json.load(fh)

settings["statusLine"] = {"type": "command", "command": target}


def with_1m(value, fallback="deepseek-flash"):
    value = value or fallback
    return value if value.endswith("[1m]") else f"{value}[1m]"


if suffix:
    env = settings.setdefault("env", {})
    if deepseek:
        # DeepSeek's guide names the main model explicitly; fall back to Flash.
        env["ANTHROPIC_MODEL"] = with_1m(env.get("ANTHROPIC_MODEL"))
        settings["model"] = with_1m(settings.get("model"))
    else:
        # Only rewrite what is already configured -- do not invent a model choice.
        if env.get("ANTHROPIC_MODEL"):
            env["ANTHROPIC_MODEL"] = with_1m(env["ANTHROPIC_MODEL"])
        if settings.get("model"):
            settings["model"] = with_1m(settings["model"])
    # Leave the small/fast model alone unless the user already set one; DeepSeek's
    # guide covers that slot with ANTHROPIC_DEFAULT_HAIKU_MODEL instead.
    if env.get("ANTHROPIC_SMALL_FAST_MODEL"):
        env["ANTHROPIC_SMALL_FAST_MODEL"] = with_1m(env["ANTHROPIC_SMALL_FAST_MODEL"])
    # Only meaningful once the window is raised above; without the "[1m]" suffix the
    # CLI caps this at its assumed 200k.
    env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = compact_window

if deepseek:
    # DeepSeek's own Claude Code guide:
    # https://api-docs.deepseek.com/quick_start/agent_integrations/claude_code
    env = settings.setdefault("env", {})
    env.setdefault("ANTHROPIC_BASE_URL", "https://api.deepseek.com/anthropic")
    env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = "deepseek-flash[1m]"
    env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = "deepseek-flash[1m]"
    env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = "deepseek-flash"
    env["CLAUDE_CODE_SUBAGENT_MODEL"] = "deepseek-flash"

with open(path, "w", encoding="utf-8") as fh:
    json.dump(settings, fh, indent=2)
    fh.write("\n")

print("registered statusLine in", path)
if suffix:
    print(f'raised the assumed context window ("[1m]") and set the auto-compact threshold to {compact_window}')
if deepseek:
    print("applied DeepSeek's official Claude Code model environment")
PY

cat <<'NOTE'

Restart Claude Code to apply.

The status line only corrects what is *displayed*. Auto-compaction is scheduled by
the CLI from its own assumed window, which is 200000 for any model id it does not
recognise -- it has no way to ask the provider. The "[1m]" suffix makes that
assumed window 1000000, which is what fixes compaction.

DeepSeek models (all 1M context, 384K max output):

  deepseek-flash   DeepSeek-V4.1-Flash -- current, supports vision. [recommended]
  deepseek-v4-pro  V4-Pro, being phased out: since 2026-09-14 every request is
                   served by V4.1-Flash and billed at V4.1-Flash rates.

Still accepted as legacy ids, all served by V4.1-Flash:
  deepseek-v4-flash, deepseek-v4-flash-vision-exp, deepseek-chat, deepseek-reasoner

Not set by this script, because it is a cost/quality trade-off rather than a fix:

  CLAUDE_CODE_EFFORT_LEVEL=max

See README.md for the full configuration table.
NOTE
