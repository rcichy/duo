#!/usr/bin/env bash
# Shared helpers for the Claude<->Cursor "duo" review loop.
# Hooks are registered globally (~/.claude/settings.json) but are a no-op unless BOTH hold:
#   1. the session was started in a slot (git checkout) inside DUO_HOME (set by install.sh in settings.json "env")
#   2. that slot is switched on: DUO_HOME/.claude/duo.on.d/<slot> exists (/duo-on and /duo-off, see slot.sh)

DUO_HOME="${DUO_HOME:-$(jq -r '.env.DUO_HOME // empty' "$HOME/.claude/settings.json" 2>/dev/null)}"
[ -n "$DUO_HOME" ] || exit 0
source "$(dirname "${BASH_SOURCE[0]}")/slot.sh"
DUO_INPUT=$(cat)
DUO_SESSION=$(jq -r '.session_id // "nosession"' <<<"$DUO_INPUT")
DUO_CWD=$(jq -r '.cwd // empty' <<<"$DUO_INPUT")
[ -z "$DUO_CWD" ] && DUO_CWD="${CLAUDE_PROJECT_DIR:-$PWD}"
DUO_SLOT_ROOT=$(duo_slot_root "${CLAUDE_PROJECT_DIR:-$DUO_CWD}" "$DUO_HOME")

duo_enabled() {
  local on
  on=$(duo_slot_file "$DUO_HOME" "$DUO_SLOT_ROOT" duo.on) || return 1
  [ -f "$on" ] && command -v agent >/dev/null 2>&1
}

# repo root of the current session (falls back to cwd when not in git)
DUO_ROOT=$(cd "$DUO_CWD" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || echo "$DUO_CWD")

# A slot that is not a git checkout but holds one checkout per repo (a workspace for a task that spans several
# repos) is reviewed as a whole: Cursor runs in the slot directory and sees the changes of every checkout in it.
# DUO_HOME itself never counts as one, although it holds checkouts too.
DUO_MULTI=0
DUO_WHERE="the current repository"
if [ "$DUO_SLOT_ROOT" != "$DUO_HOME" ] && ! git -C "$DUO_SLOT_ROOT" rev-parse --git-dir >/dev/null 2>&1 \
   && compgen -G "$DUO_SLOT_ROOT/*/.git" >/dev/null; then
  DUO_MULTI=1 DUO_ROOT="$DUO_SLOT_ROOT"
  DUO_WHERE="the repositories checked out in the subdirectories of the current directory (diff paths start with the subdirectory)"
fi

# duo_checkouts -> the git checkouts a review covers, one per line: each one in a multi-repo slot, else DUO_ROOT
duo_checkouts() {
  local d
  if [ "$DUO_MULTI" = 1 ]; then
    for d in "$DUO_ROOT"/*/; do [ -e "$d.git" ] && printf '%s\n' "${d%/}"; done
  else
    git -C "$DUO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 && printf '%s\n' "$DUO_ROOT"
  fi
  return 0
}

# duo_prefix <checkout> -> its path relative to DUO_ROOT, with a trailing slash ("" for DUO_ROOT itself)
duo_prefix() { [ "$1" = "$DUO_ROOT" ] || printf '%s/' "${1#"$DUO_ROOT"/}"; }

# duo_diff -> the uncommitted changes (tracked and untracked files) of every checkout, paths relative to DUO_ROOT
duo_diff() {
  local c p f
  while IFS= read -r c; do
    p=$(duo_prefix "$c")
    git -C "$c" diff --src-prefix="a/$p" --dst-prefix="b/$p"
    while IFS= read -r f; do
      [ -n "$f" ] && (cd "$c" && git diff --no-index --src-prefix="a/$p" --dst-prefix="b/$p" /dev/null "$f" 2>/dev/null)
    done < <(git -C "$c" ls-files --others --exclude-standard)
  done < <(duo_checkouts)
  return 0
}

DUO_MODEL="${DUO_MODEL:-grok-4.7-high}"          # fallback for both reviews
DUO_PLAN_MODEL="${DUO_PLAN_MODEL:-$DUO_MODEL}"        # plan review: architectural judgement, wide repo read
DUO_DIFF_MODEL="${DUO_DIFF_MODEL:-$DUO_MODEL}"        # diff review: code-level bug hunting
DUO_MAX_ROUNDS="${DUO_MAX_ROUNDS:-3}"
DUO_STATE="/tmp/claude-duo-$DUO_SESSION"

# Rounds are counted per user request: a new user message resets them, and only a valid review that
# blocks consumes one. A reviewer that returns nothing (usage limit, crash) never burns a round.
# State file "$DUO_STATE-<name>-rounds" holds "<rounds used> <user message count when counted>".

# duo_round_status <name> -> rounds already used for the current request, or "cap" when exhausted
duo_round_status() {
  local f="$DUO_STATE-$1-rounds" n=0 turns saved
  turns=$(duo_user_turns)
  if [ -f "$f" ] && read -r n saved < "$f" && [ "$saved" != "$turns" ]; then
    duo_reset_round "$1"; n=0
  fi
  if [ "${n:-0}" -ge "$DUO_MAX_ROUNDS" ]; then echo cap; else echo "${n:-0}"; fi
}

# duo_round_consume <name> -> records one more used round, prints its number
duo_round_consume() {
  local f="$DUO_STATE-$1-rounds" n=0 saved
  [ -f "$f" ] && read -r n saved < "$f"
  n=$(( ${n:-0} + 1 ))
  echo "$n $(duo_user_turns)" > "$f"
  echo "$n"
}

duo_reset_round() { rm -f "$DUO_STATE-$1-rounds" "$DUO_STATE-$1-last-review" "$DUO_STATE-$1-escalated"; }

# duo_verdict <review> <word>... -> the verdict word from the first line that consists of one of them alone
# (markdown emphasis and punctuation ignored, a short preamble before it tolerated); nothing when no line does.
duo_verdict() {
  local review="$1" line w; shift
  while IFS= read -r line; do
    line=$(tr -d '*`#.:[:space:]' <<<"$line" | tr '[:lower:]' '[:upper:]')
    for w in "$@"; do [ "$line" = "$w" ] && { echo "$w"; return 0; }; done
  done < <(printf '%s\n' "$review" | head -20)
  return 0
}

# duo_has_tag <review> <TAG> -> success when a finding carries [TAG]
duo_has_tag() { grep -qiF "[$2]" <<<"$1"; }

# duo_failure_reason -> why the last Cursor call gave no usable review (after the retry), for the user
duo_failure_reason() {
  local answer; answer=$(sed 1d "$DUO_STATE-last-answer" 2>/dev/null)
  if [ -z "$(tr -d '[:space:]' <<<"$answer")" ]; then duo_why_empty
  else printf 'no verdict line in the answer: %s' "$(head -c 300 <<<"$answer" | tr '\n' ' ')"
  fi
  printf ' (details: %s)' "$DUO_STATE-last-answer"
}

# duo_ask <model> <prompt>  -> runs Cursor (read-only) in the repo root, prints its answer.
# Each call is a fresh Cursor session: nothing is threaded between rounds or between the two reviews,
# so anything a reviewer must know has to be in the prompt.
# Every call leaves its raw answer, exit code and duration in "$DUO_STATE-last-answer" (and appends it to
# "$DUO_STATE-answers.log") for diagnosis. The call is
# capped below the hook timeouts (1800s) so a slow reviewer is reported instead of silently killed.
DUO_AGENT_TIMEOUT="${DUO_AGENT_TIMEOUT:-1500}"

# duo_timeout_cmd <seconds> -> "timeout <s>" (GNU coreutils; "gtimeout" on macOS with brew coreutils), or nothing
# when neither exists: the call then runs uncapped and only the hook timeout (1800s) stops it.
duo_timeout_cmd() {
  local t
  for t in timeout gtimeout; do command -v "$t" >/dev/null 2>&1 && { printf '%s %s' "$t" "$1"; return 0; }; done
  return 0
}
duo_ask() {
  local model="$1" prompt="$2" out rc start limit=() stream=""
  [ -n "${DUO_PROMPT_LOG:-}" ] && printf '===== %s =====\n%s\n' "$model" "$prompt" >> "$DUO_PROMPT_LOG"
  start=$(date +%s)
  if duo_use_herdr && duo_ask_herdr "$model" "$prompt"; then
    out=$(cat "$DUO_STATE-herdr-out" 2>/dev/null)
    rc=$(cat "$DUO_STATE-herdr-rc")
    stream="$DUO_STATE-herdr-stream.jsonl"
  else
    read -r -a limit <<<"$(duo_timeout_cmd "$DUO_AGENT_TIMEOUT")"
    out=$(cd "$DUO_ROOT" && ${limit[@]+"${limit[@]}"} agent -p --trust --mode ask --model "$model" --output-format text "$prompt" 2>"$DUO_STATE-stderr")
    rc=$?
  fi
  [ "$rc" = 124 ] && printf 'agent timed out after %ss\n' "$DUO_AGENT_TIMEOUT" >> "$DUO_STATE-stderr"
  printf '===== %s model=%s rc=%s %ss prompt=%s chars =====\n%s\n' "$(date '+%F %T')" "$model" "$rc" \
    "$(( $(date +%s) - start ))" "${#prompt}" "$out" > "$DUO_STATE-last-answer"
  cat "$DUO_STATE-last-answer" >> "$DUO_STATE-answers.log"
  duo_archive "$prompt" "$stream"
  duo_record_cursor "$model" "$out"
  printf '%s' "$out"
}

# Every Cursor call is kept for /duo-advisor, which reads a session afterwards: what Cursor was given decides what it
# could catch. DUO_LOG_DIR/<session>/<n>-<hook>.prompt.md is the prompt, .answer.md the answer with its header
# line (model, exit code, duration), .reads the files Cursor read and searched (herdr runs only). An empty
# DUO_LOG_DIR keeps nothing.
DUO_LOG_DIR="${DUO_LOG_DIR-$HOME/.claude/duo-log}"

# duo_archive <prompt> <stream file or ""> -> files the call that just ended ($DUO_STATE-last-answer) in the archive
duo_archive() {
  [ -n "$DUO_LOG_DIR" ] || return 0
  local d="$DUO_LOG_DIR/$DUO_SESSION" n base
  mkdir -p "$d" 2>/dev/null || return 0
  n=$(find "$d" -name '*.prompt.md' 2>/dev/null | wc -l)
  base="$d/$(printf '%03d' $((n + 1)))-$(basename "$0" .sh)"
  printf '%s\n' "$1" > "$base.prompt.md"
  cp "$DUO_STATE-last-answer" "$base.answer.md"
  [ -n "$2" ] && [ -s "$2" ] && jq -Rr 'fromjson? | select(.type == "tool_call" and .subtype == "started")
      | .tool_call | to_entries[] | select(.key | endswith("ToolCall"))
      | "\(.key | sub("ToolCall$"; "")) \(.value.args | [.path, .pattern, .globPattern, .command] | map(select(. != null) | tostring) | join("  "))"' \
      "$2" > "$base.reads" 2>/dev/null
  return 0
}

# --- herdr ------------------------------------------------------------------------------------
# With DUO_USE_HERDR=1 and Claude running inside herdr, the Cursor call runs in a herdr pane split off Claude's
# pane, so you can watch what the reviewer reads and says. The hook still waits for the answer and handles it
# exactly as before; herdr-run.sh hands it back through files. Outside herdr, or if the pane cannot be
# created, the call runs directly as usual.
DUO_USE_HERDR="${DUO_USE_HERDR:-0}"
DUO_HERDR_SPLIT="${DUO_HERDR_SPLIT:-right}"   # where the review pane opens next to Claude: right | down
DUO_HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

duo_use_herdr() {
  case "$DUO_USE_HERDR" in 1|true|yes|on) ;; *) return 1 ;; esac
  [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ] && command -v herdr >/dev/null 2>&1
}

# duo_herdr_pane -> this session's review pane: split off Claude's pane on first use, reused afterwards,
# recreated if you closed it
duo_herdr_pane() {
  local f="$DUO_STATE-herdr-pane" pane
  pane=$(cat "$f" 2>/dev/null)
  if [ -z "$pane" ] || ! herdr pane get "$pane" >/dev/null 2>&1; then
    rm -f "$DUO_STATE-herdr-prompt"   # a new pane has nothing left running
    pane=$(herdr pane split --pane "$HERDR_PANE_ID" --direction "$DUO_HERDR_SPLIT" --cwd "$DUO_ROOT" --no-focus 2>/dev/null \
           | jq -r '.result.pane.pane_id // empty')
    [ -n "$pane" ] || return 1
    herdr pane rename "$pane" "duo: cursor" >/dev/null 2>&1
    echo "$pane" > "$f"
  fi
  printf '%s' "$pane"
}

# duo_ask_herdr <model> <prompt> -> runs the Cursor call in the review pane and waits for it; on success the
# answer is in "$DUO_STATE-herdr-out" and the exit code in "$DUO_STATE-herdr-rc". Fails (so the caller runs
# Cursor directly) only when nothing was started.
duo_ask_herdr() {
  local model="$1" prompt="$2" pane deadline
  pane=$(duo_herdr_pane) || return 1
  # the previous run never finished (its hook was killed): interrupt it before typing into the pane
  if [ -f "$DUO_STATE-herdr-prompt" ] && [ ! -f "$DUO_STATE-herdr-rc" ]; then
    herdr pane send-keys "$pane" ctrl+c >/dev/null 2>&1; sleep 1
  fi
  rm -f "$DUO_STATE-herdr-rc" "$DUO_STATE-herdr-out"
  printf '%s' "$prompt" > "$DUO_STATE-herdr-prompt"
  herdr pane run "$pane" "$(printf '%q ' bash "$DUO_HOOKS_DIR/herdr-run.sh" "$DUO_STATE" "$model" "$DUO_ROOT" \
    "$DUO_AGENT_TIMEOUT" "$(basename "$0" .sh)")" >/dev/null 2>&1 || return 1
  deadline=$(( $(date +%s) + DUO_AGENT_TIMEOUT + 60 ))   # herdr-run.sh enforces the timeout; this is a backstop
  until [ -f "$DUO_STATE-herdr-rc" ]; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      herdr pane send-keys "$pane" ctrl+c >/dev/null 2>&1
      printf 'herdr pane %s did not finish the review\n' "$pane" >> "$DUO_STATE-stderr"
      echo 124 > "$DUO_STATE-herdr-rc"
      break
    fi
    sleep 1
  done
  return 0
}

# duo_review <model> <prompt> <verdict words>... -> a review with a recognisable verdict, asking a second time when
# the first answer came back empty or without one; a timeout is not retried (a second call would outlive the hook).
# Prints nothing when no usable review was obtained.
duo_review() {
  local model="$1" prompt="$2" review; shift 2
  review=$(duo_ask "$model" "$prompt")
  if [ -z "$(duo_verdict "$review" "$@")" ] && ! grep -q "timed out" "$DUO_STATE-stderr" 2>/dev/null; then
    review=$(duo_ask "$model" "$prompt")
  fi
  [ -n "$(duo_verdict "$review" "$@")" ] && printf '%s' "$review"
  return 0
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

DUO_CTX_CHARS="${DUO_CTX_CHARS:-12000}"
DUO_TASK_CHARS="${DUO_TASK_CHARS:-2000}"
DUO_REPLY_CHARS="${DUO_REPLY_CHARS:-6000}"

# duo_user_entries -> one JSON object per line, in transcript order: {k:"msg"|"img"|"answer", t:text}
#   msg    = text the user typed (string messages, text blocks of messages with attachments, and messages
#            sent while Claude was working, stored as queued_command attachments)
#   img    = an image the user attached (Cursor cannot see it; Claude transcribes it into the plan)
#   answer = the user's answer to a question Claude asked with AskUserQuestion
# Skips tool output, meta entries (skill expansions, image paths), <system-reminder> blocks and
# "Stop hook feedback" (the previous round is passed separately).
duo_user_entries() {
  local t; t=$(jq -r '.transcript_path // empty' <<<"$DUO_INPUT")
  [ -f "$t" ] || return 0
  jq -c 'def typed: select(startswith("<")|not) | select(startswith("Stop hook feedback")|not);
    if .type=="attachment" and .attachment.type? == "queued_command" then
      (.attachment.prompt? // empty | strings | typed | {k:"msg", t:.})
    else
    select(.type=="user") | (.isMeta == true) as $meta | .message.content as $c
    | if ($c|type)=="string" then ($c | select($meta|not) | typed | {k:"msg", t:.})
      else $c[]?
        | if .type=="text" then (.text | select($meta|not) | typed | {k:"msg", t:.})
          elif .type=="image" and ($meta|not) then {k:"img", t:"[image attached — Claude must transcribe it into the plan Requirements section]"}
          elif .type=="tool_result" then
            ((.content | if type=="array" then (map(.text? // "") | join("")) else tostring end)
             | select(test("^(The user answered|User has answered)")) | {k:"answer", t:.})
          else empty end
      end
    end' "$t" 2>/dev/null
}

# duo_user_turns -> number of messages the user typed so far (a new one starts a new request)
duo_user_turns() { duo_user_entries | jq -s '[.[] | select(.k=="msg")] | length'; }

# duo_user_context -> the user's messages, attachments and answers from this session, in order
# (capped at DUO_CTX_CHARS, most recent kept)
duo_user_context() {
  local all
  all=$(duo_user_entries | jq -r 'if .k=="answer" then "> [user answered a question from Claude] " + .t
                                   else "> " + .t end + "\n"')
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

# --- asides ----------------------------------------------------------------------------------
# A message opening with the aside marker is a side question (a decision, a "why did you ...").
# Claude answers it, but the Stop hook skips the review for that turn: the diff is mid-implementation,
# so reviewing it would waste a Cursor call and confuse the round counter.
DUO_ASIDE_RE="${DUO_ASIDE_RE:-^[[:space:]]*/?btw([[:space:]]|,|:|$)}"
DUO_ASIDE_FLAG="$DUO_STATE-aside"
DUO_ASIDE_FLAG_SLOT=$(duo_slot_file "$DUO_HOME" "$DUO_SLOT_ROOT" duo-aside)   # set by the /btw skill, which has no session id

# duo_aside_consume -> 0 when this turn is an aside; clears the mark so it lasts exactly one turn
duo_aside_consume() {
  if [ -f "$DUO_ASIDE_FLAG" ] || [ -f "$DUO_ASIDE_FLAG_SLOT" ]; then
    rm -f "$DUO_ASIDE_FLAG" "$DUO_ASIDE_FLAG_SLOT"
    return 0
  fi
  return 1
}

DUO_ASIDE_CHARS="${DUO_ASIDE_CHARS:-4000}"

# duo_aside_record -> append this aside exchange (the question and Claude's answer) to the session log.
# The user's message already reaches a reviewer through TASK CONTEXT; the answer is what would be lost,
# and the answer is usually where the decision is.
duo_aside_record() {
  local q a f="$DUO_STATE-asides"
  q=$(duo_user_entries | jq -r 'select(.k=="msg") | .t' 2>/dev/null | tail -1)
  a=$(duo_last_claude_text)
  [ -n "$q$a" ] || return 0
  { [ -n "$q" ] && printf 'Q (user, asked alongside the work): %s\n' "$q"
    [ -n "$a" ] && printf 'A (Claude): %s\n' "$a"
    printf '\n'; } >> "$f"
}

# duo_aside_context -> the accumulated side discussion, for both review prompts
duo_aside_context() {
  local f="$DUO_STATE-asides"
  [ -s "$f" ] || return 0
  printf 'SIDE DISCUSSION — questions the user asked Claude alongside the implementation, with Claude'"'"'s answers.
No review ran at the time. Treat decisions settled here as agreed context: do not re-litigate them, and do flag
anything in the plan or diff that contradicts them.

%s
' "$(tail -c "$DUO_ASIDE_CHARS" "$f")"
}

# --- prose gate ------------------------------------------------------------------------------
# Non-code text is reviewed by Claude with an editing skill, not by Cursor: Cursor is aimed at code,
# and a prose pass costs a Cursor call it cannot spend well.
DUO_PROSE_RE="${DUO_PROSE_RE:-\.(md|markdown|mdx|rst|txt|adoc)$}"
DUO_PROSE_MIN_LINES="${DUO_PROSE_MIN_LINES:-5}"   # skip the pass for typo-sized prose changes
DUO_PROSE_SKILL="${DUO_PROSE_SKILL:-no-ai-slop}"  # empty disables the gate

# Rules of the team guide that a linter can check are checked on the lines the change adds, before any Cursor call:
# old code that breaks them is no excuse for new code that does. DUO_NEW_CODE_RUFF lists ruff rule codes (e.g.
# "ANN001,ANN201,PLC0415"); empty disables the check, and so does a missing ruff.
# DUO_NEW_CODE_RUFF_STRICT lists the codes among them that apply even where a repo's per-file-ignores turn them off.
# Both are read from settings.json first: a session keeps the env it started with, and the lists grow meanwhile.
for v in DUO_NEW_CODE_RUFF DUO_NEW_CODE_RUFF_STRICT; do
  if jq -e --arg v "$v" '.env | has($v)' "$HOME/.claude/settings.json" >/dev/null 2>&1; then
    printf -v "$v" '%s' "$(jq -r --arg v "$v" '.env[$v]' "$HOME/.claude/settings.json")"
  fi
done
DUO_NEW_CODE_RUFF="${DUO_NEW_CODE_RUFF:-}" DUO_NEW_CODE_RUFF_STRICT="${DUO_NEW_CODE_RUFF_STRICT:-}"

# duo_new_code_findings -> "path:line: CODE message" for each finding on an added line, paths relative to DUO_ROOT
duo_new_code_findings() {
  [ -n "$DUO_NEW_CODE_RUFF" ] && command -v ruff >/dev/null 2>&1 || return 0
  local c
  while IFS= read -r c; do
    python3 -I "$(dirname "${BASH_SOURCE[0]}")/new-code-check.py" "$c" "$DUO_NEW_CODE_RUFF" "$(duo_prefix "$c")" \
      "$DUO_NEW_CODE_RUFF_STRICT" 2>/dev/null
  done < <(duo_checkouts)
  return 0
}

# duo_prose_skill_available -> 0 when that skill is installed for this session
duo_prose_skill_available() {
  [ -n "$DUO_PROSE_SKILL" ] || return 1
  [ -d "$HOME/.claude/skills/$DUO_PROSE_SKILL" ] && return 0
  [ -d "$DUO_ROOT/.claude/skills/$DUO_PROSE_SKILL" ] && return 0
  compgen -G "$HOME/.claude/plugins/*/skills/$DUO_PROSE_SKILL" >/dev/null 2>&1
}

# duo_prose_pending -> changed prose files not yet handed to the editing skill, one per line
duo_prose_pending() {
  local c p tracked untracked changed="" added=0 f
  while IFS= read -r c; do
    p=$(duo_prefix "$c")
    tracked=$(git -C "$c" diff --name-only 2>/dev/null | grep -Ei "$DUO_PROSE_RE" || true)
    untracked=$(git -C "$c" ls-files --others --exclude-standard 2>/dev/null | grep -Ei "$DUO_PROSE_RE" || true)
    changed+=$(printf '%s\n%s\n' "$tracked" "$untracked" | sed "/^\$/d; s|^|$p|")$'\n'
    added=$(( added + $(git -C "$c" diff --numstat 2>/dev/null | grep -Ei "$DUO_PROSE_RE" | awk '{s+=$1} END{print s+0}') ))
    while IFS= read -r f; do
      [ -n "$f" ] && added=$(( added + $(wc -l < "$c/$f" 2>/dev/null || echo 0) ))
    done <<<"$untracked"
  done < <(duo_checkouts)
  changed=$(sed '/^$/d' <<<"$changed" | sort -u)
  [ -n "$changed" ] || return 0
  [ "$added" -ge "$DUO_PROSE_MIN_LINES" ] || return 0
  comm -23 <(printf '%s\n' "$changed") <(sort -u "$DUO_STATE-prose-done" 2>/dev/null)
}

duo_prose_mark_done() { printf '%s\n' "$1" >> "$DUO_STATE-prose-done"; }

# duo_last_claude_text -> Claude's most recent text reply (its accepted/rejected summary after a review)
duo_last_claude_text() {
  local t; t=$(jq -r '.transcript_path // empty' <<<"$DUO_INPUT")
  [ -f "$t" ] || return 0
  jq -rs '[.[] | select(.type=="assistant") | [.message.content[]? | select(.type=="text") | .text]
           | join("\n") | select(length > 0)] | last // empty' "$t" 2>/dev/null | tail -c "$DUO_REPLY_CHARS"
}

# duo_save_review <name> <review> / duo_previous_round <name> -> reviewer memory between rounds
duo_save_review() { printf '%s' "$2" > "$DUO_STATE-$1-last-review"; }
duo_previous_round() {
  local f="$DUO_STATE-$1-last-review"
  [ -s "$f" ] || return 0
  printf 'PREVIOUS ROUND — your findings from the last round, then Claude'"'"'s response (what it changed and why it rejected the rest).
Do not repeat a finding Claude rejected unless you have new evidence, and state that evidence. If you still believe a
rejected point matters and Claude'"'"'s reasoning does not convince you, tag it [ESCALATE] so the user decides.
YOUR FINDINGS:
%s

CLAUDE'"'"'S RESPONSE:
%s

' "$(cat "$f")" "$(duo_last_claude_text)"
}

# duo_review_guide -> the team review guide shared by every repo under DUO_HOME, injected into both prompts
# (Cursor only auto-loads rules from the repo it runs in, so it would never find this file on its own)
DUO_REVIEW_GUIDE="${DUO_REVIEW_GUIDE:-$DUO_HOME/review-guide.md}"
duo_review_guide() {
  [ -s "$DUO_REVIEW_GUIDE" ] || return 0
  printf 'TEAM REVIEW GUIDE (%s) — how the human reviewers of this team review merge requests.
Apply it; it takes precedence over generic advice.
%s

' "$DUO_REVIEW_GUIDE" "$(cat "$DUO_REVIEW_GUIDE")"
}

# duo_rubric -> what to look for and how to tag findings; shared by the plan and the diff review
duo_rubric() {
  cat <<'EOF'
Focus, in this order:
1. Requirements: compare against the requirements quoted in the plan and the user's messages. Flag anything
   missing, or built differently without a stated reason. Check each behaviour the plan states (an order, an empty
   case, which rows a count includes) against the requirements and design decisions it quotes: a statement that
   contradicts them is a [BLOCKER], even when the plan calls it intended.
2. Correctness and failure modes: bugs, unhandled errors, what happens when a dependency (storage, broker, DB,
   network) fails midway, concurrency and thread-safety, transactions and locks. Trace the empty cases (NULL, empty
   string, empty list or array, no rows) through every new sort, filter and aggregate. A helper must not change
   what it is given (a query, a list, a dict) unless that is its job.
3. Blast radius: effects beyond the task (global state, signals, model or field behaviour, shared connections,
   settings), and sibling code paths with the same problem that were left unfixed (search the repo for them).
4. Tests: requirements and failure paths without a test; tests that do not exercise the change.
5. Simplicity: over-engineering, speculative generality, unused code, defensive code for impossible states.
   Prefer the simplest fix. Never ask for machinery "for the future".
6. Team review guide, when there is one: go through it rule by rule against the plan or the added lines. A clear
   breach of a guide rule in new code is a [BLOCKER]: the team's reviewers would ask for it anyway, and it is cheap
   to fix now. The surrounding code breaking the same rule is no excuse; only a reason the guide itself accepts is.
Skip formatting and style the team review guide does not ask for.

Tag every finding with exactly one of:
[BLOCKER]  must change before merge: a bug, a missing requirement, data loss, a broken contract
[SHOULD]   worth doing, not blocking
[NIT]      minor
[ESCALATE] a decision for the user rather than for you or Claude: a product, scope or ops trade-off (including
           a deviation that changes what users see, such as a count, a filter result or an order, compared with
           the ticket, its design documents or another screen), or a point where you still disagree with Claude
           after its response. Escalating a real disagreement is expected and useful; it is better than dropping
           the point or repeating it. Never escalate again what the user already decided (their answers to
           Claude's questions are in TASK CONTEXT) unless you bring new evidence, and name it.
Only [BLOCKER] makes Claude change the work before continuing. [ESCALATE] items are put to the user.
EOF
}
