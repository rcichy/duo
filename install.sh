#!/usr/bin/env bash
# Installs the Claude+Cursor "duo" review loop. Idempotent — safe to re-run.
# Usage: ./install.sh <DUO_HOME>
#   DUO_HOME = absolute path of the folder (of repos) under which duo may activate. Sessions outside it are untouched.
set -euo pipefail
DUO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DUO_HOME="${1:?usage: install.sh <DUO_HOME>   e.g. install.sh ~/Projects}"
DUO_HOME="$(cd "$DUO_HOME" && pwd)"
SETTINGS="$HOME/.claude/settings.json"
SKILLS="$HOME/.claude/skills"
STATUSLINE="$HOME/.claude/statusline-command.sh"

need() { command -v "$1" >/dev/null 2>&1 || { echo "MISSING: $1 — $2"; exit 1; }; }
need jq "brew install jq"
need claude "install Claude Code first"
command -v agent >/dev/null 2>&1 || echo "WARN: Cursor CLI 'agent' not found. Install: curl https://cursor.com/install -fsS | bash ; then: agent login"

chmod +x "$DUO_DIR"/hooks/*.sh

# 1. settings.json: env + hooks (merged, never replaces existing entries)
mkdir -p "$HOME/.claude"; [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak-duo"
FRAG=$(sed "s|__HOME__|$HOME|g; s|__DUO_HOME__|$DUO_HOME|g" "$DUO_DIR/hooks.settings.json")
jq --argjson f "$FRAG" '
  def addhooks($ev):
    (.hooks[$ev] // []) as $cur
    | ($cur | map(.hooks[0].command)) as $have
    | .hooks[$ev] = $cur + [ $f.hooks[$ev][] | select(.hooks[0].command as $c | $have | index($c) | not) ];
  .env = ((.env // {}) + $f.env)
  | reduce ($f.hooks | keys_unsorted[]) as $ev (.; addhooks($ev))
' "$SETTINGS.bak-duo" > "$SETTINGS.tmp"            # never write directly: a jq failure must not truncate settings
jq -e . "$SETTINGS.tmp" >/dev/null && mv "$SETTINGS.tmp" "$SETTINGS"
jq -e '.hooks.PreToolUse[]|select(.matcher=="ExitPlanMode")' "$SETTINGS" >/dev/null && echo "ok: hooks registered in $SETTINGS (backup: $SETTINGS.bak-duo)"

# 2. skills: symlink so git pulls update them
mkdir -p "$SKILLS"
for s in duo-on duo-off; do
  [ -L "$SKILLS/$s" ] || { rm -rf "$SKILLS/$s"; ln -s "$DUO_DIR/skills/$s" "$SKILLS/$s"; }
done
echo "ok: /duo-on and /duo-off skills linked into $SKILLS"

# 3. status line indicator
if [ -f "$STATUSLINE" ] && ! grep -q 'duo indicator' "$STATUSLINE"; then
  if grep -q '^echo " \$(basename "\$dir") | \$model\$ctx"$' "$STATUSLINE"; then
    cp "$STATUSLINE" "$STATUSLINE.bak-duo"
    python3 - "$STATUSLINE" "$DUO_DIR/statusline-duo.snippet.sh" <<'PY'
import sys; p,snip=sys.argv[1],open(sys.argv[2]).read()
s=open(p).read().replace('echo " $(basename "$dir") | $model$ctx"', snip+'\necho " $(basename "$dir") | $model$ctx$duo"')
open(p,'w').write(s)
PY
    echo "ok: status line patched ($STATUSLINE, backup .bak-duo)"
  else
    echo "TODO: status line script has an unfamiliar shape. Add the contents of statusline-duo.snippet.sh before its final echo and append \$duo to the output."
  fi
elif [ ! -f "$STATUSLINE" ]; then
  echo "TODO: no $STATUSLINE found — set one up (see README) if you want the DUO indicator."
else
  echo "ok: status line already patched"
fi

# 4. cleanup of the pre-canonical location (first laptop only)
[ -d "$DUO_HOME/.claude/hooks" ] && [ -f "$DUO_HOME/.claude/hooks/common.sh" ] && { rm -rf "$DUO_HOME/.claude/hooks"; echo "ok: removed legacy $DUO_HOME/.claude/hooks"; }

echo
echo "DUO_HOME=$DUO_HOME. Open a Claude session under it and run /duo-on. If hooks don't fire in an already-open session, run /hooks there or restart it."
