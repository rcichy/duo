# duo — Claude Code + Cursor review loop

Two-model workflow for Claude Code: Claude plans and implements, Cursor (GPT/Codex, read-only) reviews the plan and then the diff, Claude validates the feedback and fixes what is real. Changes are always left **unstaged** for the human. Enforced by Claude Code hooks, not by prompting.

```
you: "implement X"  (Claude in plan mode)
  └─ Claude writes plan → ExitPlanMode
       └─ hook: Cursor reviews plan  → REVISE: denied, Claude edits plan, retries (max 3)
                                     → APPROVE: Claude implements
            └─ Claude stops
                 └─ hook: Cursor reviews diff → CHANGES: stop blocked, Claude verifies + fixes, stops again (max 3)
                                              → LGTM: done, diff left unstaged
```

Cursor also receives your own messages from the session (extracted from the transcript) as "TASK CONTEXT", so it judges against what you actually asked for.

## Files

| File | Purpose |
|---|---|
| `hooks/common.sh` | gate (`DUO_HOME` + marker), round counters, `duo_ask` (Cursor call), transcript context |
| `hooks/review-plan.sh` | `PreToolUse` on `ExitPlanMode` |
| `hooks/review-diff.sh` | `Stop` — reviews `git diff` + untracked files |
| `hooks/block-git-staging.sh` | `PreToolUse` on `Bash` — denies `git add/commit/stash/push/reset/restore` while duo is on |
| `skills/duo-on`, `skills/duo-off` | `/duo-on` `/duo-off` — create/remove the marker file and brief Claude on the rules |
| `hooks.settings.json` | fragment merged into `~/.claude/settings.json` by the installer |
| `statusline-duo.snippet.sh` | adds ` \| DUO` to the status line while active |
| `install.sh` | idempotent installer |

## How it is scoped (important)

Hooks are registered **globally** in `~/.claude/settings.json` (Claude Code does not inherit `.claude/settings` from parent directories — verified), but every script exits immediately unless **both**:

1. the session's cwd is under `DUO_HOME` (a folder of repos you choose at install time), and
2. `DUO_HOME/.claude/duo.on` exists (toggled by `/duo-on` / `/duo-off`).

So plain Claude is unaffected everywhere else, and unaffected inside `DUO_HOME` until you opt in.

## Install on a new machine

Prerequisites: Claude Code, `jq` (`brew install jq`), Cursor CLI:

```bash
curl https://cursor.com/install -fsS | bash
agent login
agent --list-models        # confirm the model in hooks.settings.json exists (DUO_MODEL)
```

Then:

```bash
~/.config/ai/duo/install.sh /absolute/path/to/your/repos-folder
```

The installer:
- merges `env` (`DUO_HOME`, `DUO_MODEL`, `DUO_MAX_ROUNDS`) and the three hooks into `~/.claude/settings.json` (backup at `settings.json.bak-duo`; existing entries are kept; re-running adds nothing twice),
- symlinks `~/.claude/skills/duo-on` and `duo-off` to this folder (so `git pull` updates them),
- patches `~/.claude/statusline-command.sh` if it has the known shape, otherwise prints a TODO with the snippet to add.

Verify: open Claude Code inside `DUO_HOME`, run `/hooks` (three entries pointing at `~/.config/ai/duo/hooks/`), then `/duo-on` — the status line shows `DUO`.

### Instructions for Claude doing the install

1. Run `install.sh <DUO_HOME>` with the folder the user names. Do not guess the folder; ask if not given.
2. If it prints a `TODO` for the status line, edit `~/.claude/statusline-command.sh`: paste `statusline-duo.snippet.sh` before the final `echo` and append `$duo` to the echoed string. The snippet expects a variable `$dir` holding the cwd from the status-line JSON (`.cwd`).
3. Pipe-test without spending Cursor calls:
   ```bash
   echo '{"session_id":"t","cwd":"<DUO_HOME>/some-repo","tool_input":{"command":"git add ."}}' | ~/.config/ai/duo/hooks/block-git-staging.sh
   ```
   With the marker absent: no output. After `touch <DUO_HOME>/.claude/duo.on`: a JSON `deny`. Remove the marker afterwards.
4. Do not commit anything in the user's repos; the whole point of duo is that the human commits.

## Usage

```
cd <DUO_HOME>/<repo>
claude
> /duo-on
> implement X        # Claude should enter plan mode itself; or start with: claude --permission-mode plan
> /duo-off           # back to plain Claude
```

## Tuning

Set in `~/.claude/settings.json` → `env`:

| Var | Default | Meaning |
|---|---|---|
| `DUO_HOME` | (set by installer) | folder under which duo may activate |
| `DUO_MODEL` | `gpt-5.3-codex-high` | Cursor model (`agent --list-models`) |
| `DUO_MAX_ROUNDS` | `3` | cap for plan rounds and, separately, diff rounds |
| `DUO_CTX_CHARS` | `12000` | max chars of your own messages forwarded to Cursor (most recent kept) |
| `DUO_PLANS` | `~/.claude/plans` | where Claude Code writes plan files (only change if you set `plansDirectory`) |

Round counters live in `/tmp/claude-duo-<session>-*`; delete them to reset a session.

## Uninstall

Remove the three hook entries and the `env` keys from `~/.claude/settings.json` (or restore `settings.json.bak-duo`), delete the two symlinks in `~/.claude/skills/`, and remove the "duo indicator" block from the status line script.

## Known limits

- The diff review sees the **whole** uncommitted diff of the repo, including your own pre-existing uncommitted work.
- Cursor sees your messages and the plan/diff, not Claude's replies or reasoning.
- Each Cursor call is a full agent run over the repo: expect 30 s – 3 min per review. Hook timeouts are 600 s (plan) / 900 s (diff).
- `agent` CLI flags (`-p`, `--mode ask`, `--output-format`, `--trust`) are as of Cursor CLI 2026.09; if a review returns nothing, run the `agent -p …` line from `common.sh` manually.
