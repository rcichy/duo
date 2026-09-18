# --- duo indicator (appends " | DUO" when the Claude+Cursor loop is active for this cwd) ---
duo=""
duo_home="${DUO_HOME:-$(jq -r '.env.DUO_HOME // empty' "$HOME/.claude/settings.json" 2>/dev/null)}"
[ -n "$duo_home" ] && case "$dir/" in "$duo_home"/*) [ -f "$duo_home/.claude/duo.on" ] && duo=" | DUO";; esac
