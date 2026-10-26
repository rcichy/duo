# --- duo indicator (appends " | DUO" when the Claude+Cursor loop is on for this session's slot) ---
duo=""
duo_home="${DUO_HOME:-$(jq -r '.env.DUO_HOME // empty' "$HOME/.claude/settings.json" 2>/dev/null)}"
[ -n "$duo_home" ] && case "$dir/" in "$duo_home"/*) [ -f "$("$HOME/.config/ai/duo/duo-mode.sh" marker "$(echo "$input" | jq -r '.workspace.project_dir // .cwd')" 2>/dev/null)" ] && duo=" | DUO";; esac
