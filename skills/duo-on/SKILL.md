---
name: duo-on
description: Turn ON the Claude+Cursor duo review loop for repos under $DUO_HOME (Cursor reviews plans and diffs via hooks). Use when the user says "duo on", "enable duo", or wants Cursor to review this work.
---

!`H="${DUO_HOME:-$(jq -r ".env.DUO_HOME // empty" "$HOME/.claude/settings.json")}"; [ -n "$H" ] || { echo "duo: DUO_HOME is not set — run install.sh <folder>"; exit 0; }; mkdir -p "$H/.claude" && touch "$H/.claude/duo.on" && echo "duo mode: ON (marker $H/.claude/duo.on)"`

Duo mode is now ON for any session whose cwd is under `$DUO_HOME`. Confirm this to the user in one line, then follow these rules for the rest of the session (or until `/duo-off`):

1. **Plan first.** For any non-trivial code change, enter plan mode (EnterPlanMode) and write the plan to the plan file before implementing. When you call ExitPlanMode, a hook sends the plan to Cursor (GPT/Codex) for review. If Cursor requests changes, the tool call is denied and you get its notes: evaluate each point on its merits, fold in the valid ones, add a short "Reviewer notes" section to the plan explaining any you reject, then call ExitPlanMode again. Max 3 rounds.
2. **Implement**, then stop as normal. A Stop hook sends the uncommitted diff to Cursor. If it returns CHANGES you are blocked from stopping and receive the findings: verify each against the actual code, fix what is real, state briefly why you skip anything you disagree with, then stop again. Max 3 rounds.
3. **Never stage or commit.** `git add`/`commit`/`stash`/`push`/`reset`/`restore` are blocked by hook while duo is on. Leave everything unstaged for the user.
4. When you finish, summarize what Cursor raised and what you accepted vs rejected.

If the current cwd is not under `$DUO_HOME`, tell the user the hooks will not fire here.
