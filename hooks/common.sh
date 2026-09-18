#!/usr/bin/env bash
# Shared helpers for the Claude<->Cursor "duo" review loop.
# Hooks are registered globally (~/.claude/settings.json) but are a no-op unless BOTH hold:
#   1. the session cwd is inside DUO_HOME (set by install.sh in settings.json "env")
#   2. DUO_HOME/.claude/duo.on exists   (toggle with /duo-on and /duo-off)

DUO_HOME="${DUO_HOME:-$(jq -r '.env.DUO_HOME // empty' "$HOME/.claude/settings.json" 2>/dev/null)}"
[ -n "$DUO_HOME" ] || exit 0
DUO_INPUT=$(cat)
DUO_SESSION=$(jq -r '.session_id // "nosession"' <<<"$DUO_INPUT")
DUO_CWD=$(jq -r '.cwd // empty' <<<"$DUO_INPUT")
[ -z "$DUO_CWD" ] && DUO_CWD="${CLAUDE_PROJECT_DIR:-$PWD}"

duo_enabled() {
  case "$DUO_CWD/" in "$DUO_HOME"/*) ;; *) return 1 ;; esac
  [ -f "$DUO_HOME/.claude/duo.on" ] && command -v agent >/dev/null 2>&1
}

# repo root of the current session (falls back to cwd when not in git)
DUO_ROOT=$(cd "$DUO_CWD" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || echo "$DUO_CWD")

DUO_MODEL="${DUO_MODEL:-gpt-5.3-codex-high}"
DUO_MAX_ROUNDS="${DUO_MAX_ROUNDS:-3}"
DUO_STATE="/tmp/claude-duo-$DUO_SESSION"
DUO_PLANS="${DUO_PLANS:-$HOME/.claude/plans}"

# duo_round <name>  -> prints the round number after incrementing, or "cap" if exhausted
duo_round() {
  local f="$DUO_STATE-$1-rounds" n
  n=$(cat "$f" 2>/dev/null || echo 0)
  if [ "$n" -ge "$DUO_MAX_ROUNDS" ]; then rm -f "$f"; echo cap; return; fi
  echo $((n+1)) | tee "$f"
}
duo_reset_round() { rm -f "$DUO_STATE-$1-rounds"; }

# duo_ask <prompt>  -> runs Cursor (read-only) in the repo root, prints its answer
duo_ask() {
  (cd "$DUO_ROOT" && agent -p --trust --mode ask --model "$DUO_MODEL" --output-format text "$1" 2>/dev/null)
}

# duo_user_context -> the user's own typed messages from this session's transcript, in order
# (skips tool results, skill expansions and <system-reminder> blocks; capped at DUO_CTX_CHARS)
DUO_CTX_CHARS="${DUO_CTX_CHARS:-12000}"
duo_user_context() {
  local t; t=$(jq -r '.transcript_path // empty' <<<"$DUO_INPUT")
  [ -f "$t" ] || return 0
  jq -r 'select(.type=="user" and (.message.content|type)=="string")
         | .message.content | select(startswith("<")|not) | "> " + . + "\n"' "$t" 2>/dev/null \
    | tail -c "$DUO_CTX_CHARS"
}
