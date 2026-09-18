---
name: duo-off
description: Turn OFF the Claude+Cursor duo review loop (removes the $DUO_HOME/.claude/duo.on marker). Use when the user says "duo off" or wants plain Claude again.
---

!`H="${DUO_HOME:-$(jq -r ".env.DUO_HOME // empty" "$HOME/.claude/settings.json")}"; [ -n "$H" ] || { echo "duo: DUO_HOME is not set — run install.sh <folder>"; exit 0; }; rm -f "$H/.claude/duo.on" && echo "duo mode: OFF"`

Duo mode is now OFF: the Cursor review hooks and the git-staging block are inert. Confirm this to the user in one line. Normal workflow applies again.
