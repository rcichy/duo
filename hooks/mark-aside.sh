#!/usr/bin/env bash
# UserPromptSubmit: when a message starts with the aside marker (default: /btw or btw),
# mark this turn so the Stop hook skips the Cursor diff review and the prose gate.
# The turn still runs normally — only the review is suppressed, and only for that turn.
set -uo pipefail
source "$(dirname "$0")/common.sh"
duo_enabled || exit 0

# field name varies by Claude Code version; take the first that carries text
PROMPT=$(jq -r '.prompt // .user_prompt // .message.content? // .message? // empty' <<<"$DUO_INPUT" 2>/dev/null)
[ -n "${DUO_ASIDE_DEBUG:-}" ] && printf '%s' "$DUO_INPUT" > "$DUO_STATE-prompt-payload.json"
[ -n "$PROMPT" ] || exit 0

if printf '%s' "$PROMPT" | grep -qiE "$DUO_ASIDE_RE"; then
  : > "$DUO_ASIDE_FLAG"
  jq -n '{systemMessage:"duo: aside — no Cursor review for this turn"}'
fi
