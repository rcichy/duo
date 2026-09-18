#!/usr/bin/env bash
# PreToolUse(Bash): while duo is on, refuse commands that stage/commit/discard work.
set -uo pipefail
source "$(dirname "$0")/common.sh"
duo_enabled || exit 0
CMD=$(jq -r '.tool_input.command // empty' <<<"$DUO_INPUT")
if grep -Eq '(^|[;&|[:space:]])git[[:space:]]+(add|commit|stash|push|reset|restore|checkout[[:space:]]+--)([[:space:]]|$)' <<<"$CMD"; then
  jq -n '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"duo mode: leave all changes unstaged; the user reviews and commits manually."}}'
fi
