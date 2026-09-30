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

DUO_MODEL="${DUO_MODEL:-grok-4.7-high}"          # fallback for both reviews
DUO_PLAN_MODEL="${DUO_PLAN_MODEL:-$DUO_MODEL}"        # plan review: architectural judgement, wide repo read
DUO_DIFF_MODEL="${DUO_DIFF_MODEL:-$DUO_MODEL}"        # diff review: code-level bug hunting
DUO_MAX_ROUNDS="${DUO_MAX_ROUNDS:-3}"
DUO_STATE="/tmp/claude-duo-$DUO_SESSION"

# duo_round <name>  -> prints the round number after incrementing, or "cap" if exhausted
duo_round() {
  local f="$DUO_STATE-$1-rounds" n
  n=$(cat "$f" 2>/dev/null || echo 0)
  if [ "$n" -ge "$DUO_MAX_ROUNDS" ]; then rm -f "$f"; echo cap; return; fi
  echo $((n+1)) | tee "$f"
}
duo_reset_round() { rm -f "$DUO_STATE-$1-rounds"; }

# duo_ask <model> <prompt>  -> runs Cursor (read-only) in the repo root, prints its answer.
# Each call is a fresh Cursor session: nothing is threaded between rounds or between the two reviews,
# so anything a reviewer must know has to be in the prompt.
duo_ask() {
  local model="$1" prompt="$2" out
  [ -n "${DUO_PROMPT_LOG:-}" ] && printf '===== %s =====\n%s\n' "$model" "$prompt" >> "$DUO_PROMPT_LOG"
  out=$(cd "$DUO_ROOT" && agent -p --trust --mode ask --model "$model" --output-format text "$prompt" 2>"$DUO_STATE-stderr")
  duo_record_cursor "$model" "$out"
  printf '%s' "$out"
}

# duo_record_cursor <model> <output> -> note whether this model answered or is rate-limited.
# Cursor exposes no usage API, so the status line shows this last-known state, not a live figure.
duo_record_cursor() {
  local model="$1" out="$2" cache="$HOME/.claude/duo-cursor-status.json" state=ok resets=0 err days tmp
  if [ -z "$out" ]; then
    err=$(head -c 300 "$DUO_STATE-stderr" 2>/dev/null)
    case "$err" in
      *"usage limit"*|*"Usage limit"*)
        state=limited
        days=$(printf '%s' "$err" | sed -n 's/.*resets in \([0-9][0-9]*\) day.*/\1/p')
        [ -n "$days" ] && resets=$(( $(date +%s) + days * 86400 ))
        ;;
      *) return 0 ;;   # some other failure: claim nothing
    esac
  fi
  tmp=$(mktemp) || return 0
  if jq -n --arg m "$model" --arg s "$state" --argjson r "$resets" \
        --argjson old "$(cat "$cache" 2>/dev/null || echo '{}')" \
        '$old + {($m): {state:$s, resets_at:$r, at:(now|floor)}}' > "$tmp" 2>/dev/null; then
    mv "$tmp" "$cache"
  else
    rm -f "$tmp"
  fi
}

# duo_why_empty -> Cursor's own error (usage limit, bad model id, not logged in), for the fail-open message
duo_why_empty() {
  [ -s "$DUO_STATE-stderr" ] && head -c 300 "$DUO_STATE-stderr" | tr '\n' ' ' || echo "no output and no error from 'agent' — check: agent login"
}

# duo_user_context -> the user's own typed messages from this session's transcript, in order
# (skips tool results, skill expansions and <system-reminder> blocks; capped at DUO_CTX_CHARS)
DUO_CTX_CHARS="${DUO_CTX_CHARS:-12000}"
DUO_TASK_CHARS="${DUO_TASK_CHARS:-2000}"
duo_user_context() {
  local t; t=$(jq -r '.transcript_path // empty' <<<"$DUO_INPUT")
  [ -f "$t" ] || return 0
  local all
  all=$(jq -r 'select(.type=="user" and (.message.content|type)=="string")
               | .message.content | select(startswith("<")|not) | "> " + . + "\n"' "$t" 2>/dev/null)
  if [ "${#all}" -gt "$DUO_CTX_CHARS" ]; then
    printf '[...earlier messages omitted; the original request is quoted above...]\n%s' \
      "$(printf '%s' "$all" | tail -c "$DUO_CTX_CHARS")"
  else
    printf '%s' "$all"
  fi
}

# duo_task_header -> session title + the user's opening request, so a reviewer always sees the goal
# even when the message log above is truncated.
duo_task_header() {
  local t title first
  t=$(jq -r '.transcript_path // empty' <<<"$DUO_INPUT")
  [ -f "$t" ] || return 0
  title=$(jq -r 'select(.type=="custom-title") | .customTitle' "$t" 2>/dev/null | tail -1)
  [ -n "$title" ] || title=$(jq -r 'select(.type=="ai-title") | .aiTitle' "$t" 2>/dev/null | tail -1)
  first=$(jq -r 'select(.type=="user" and (.message.content|type)=="string")
                 | .message.content | select(startswith("<")|not)' "$t" 2>/dev/null \
          | head -1 | head -c "$DUO_TASK_CHARS")
  [ -n "$title" ] && printf 'TASK TITLE: %s\n' "$title"
  [ -n "$first" ] && printf 'ORIGINAL REQUEST (the user opening message this session):\n%s\n' "$first"
  return 0
}

# the approved plan is cached here by review-plan.sh and read back by review-diff.sh
DUO_PLAN_CACHE="$DUO_STATE-approved-plan"
