#!/usr/bin/env bash
# PreToolUse(Bash): while duo is on, refuse git commands that stage, commit, discard or move the user's work.
# A guard against mistakes, not a security boundary: a determined command (a script, an alias) can still get past it.
set -uo pipefail
source "$(dirname "$0")/common.sh"
duo_enabled || exit 0
CMD=$(jq -r '.tool_input.command // empty' <<<"$DUO_INPUT")
# global options may sit between "git" and the subcommand: -C <path>, -c <key=value>, --no-pager, --git-dir=<dir> ...
GIT_OPTS='([[:space:]]+(-[Cc][[:space:]]+[^[:space:]]+|--?[[:alnum:]-]+(=[^[:space:]]+)?))*'
BLOCKED='add|commit|stash|push|pull|reset|restore|checkout|switch|clean|rm|mv|merge|rebase|cherry-pick|revert'
if grep -Eq "(^|[;&|(\`[:space:]])git${GIT_OPTS}[[:space:]]+(${BLOCKED})([[:space:];&|)]|\$)" <<<"$CMD"; then
  jq -n '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"duo mode: git commands that stage, commit, discard or switch away from the work are blocked. Leave all changes unstaged; the user reviews and commits manually. Read-only git (status, diff, log, show) is fine."}}'
fi
