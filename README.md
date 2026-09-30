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

## What each reviewer is told

Every Cursor call is a fresh session (no `--resume`), so each prompt carries its own context:

| Section | Plan review | Diff review | Source |
|---|---|---|---|
| `TASK TITLE` | yes | yes | session title (`customTitle`, else `aiTitle`) |
| `ORIGINAL REQUEST` | yes | yes | your first message this session — survives truncation |
| `TASK CONTEXT` | yes | yes | all your typed messages, in order (tool output, skills and system reminders filtered out) |
| `APPROVED PLAN` | — | yes | cached when the plan review returns APPROVE, so the code is checked against what was agreed |
| `PLAN` / `DIFF` | the plan | `git diff` + untracked files | |

## Files

| File | Purpose |
|---|---|
| `hooks/common.sh` | gate (`DUO_HOME` + marker), round counters, `duo_ask` (Cursor call), transcript context |
| `hooks/review-plan.sh` | `PreToolUse` on `ExitPlanMode` |
| `hooks/review-diff.sh` | `Stop` — reviews `git diff` + untracked files |
| `hooks/block-git-staging.sh` | `PreToolUse` on `Bash` — denies `git add/commit/stash/push/reset/restore` while duo is on |
| `skills/duo-on`, `skills/duo-off` | `/duo-on` `/duo-off` — create/remove the marker file and brief Claude on the rules |
| `hooks.settings.json` | fragment merged into `~/.claude/settings.json` by the installer |
| `statusline-duo.snippet.sh` | adds ` \| DUO` to the status line while active (superseded by `../statusline-command.sh`) |
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
| `DUO_PLAN_MODEL` | `grok-4.7-high` | model for the plan review (approach, fit, missing requirements) |
| `DUO_DIFF_MODEL` | `grok-4.7-high` | model for the diff review (bugs, contracts, tests) |
| `DUO_MODEL` | `grok-4.7-high` | fallback used for either review when the two above are unset |
| `DUO_MAX_ROUNDS` | `3` | cap for plan rounds and, separately, diff rounds |
| `DUO_CTX_CHARS` | `12000` | max chars of your own messages forwarded to Cursor (most recent kept; truncation is marked) |
| `DUO_TASK_CHARS` | `2000` | max chars of the opening request quoted in the task header |
| `DUO_PROMPT_LOG` | unset | file to append every prompt sent to Cursor — for debugging what a reviewer actually saw |

Round counters live in `/tmp/claude-duo-<session>-*`; delete them to reset a session.

## Uninstall

Remove the three hook entries and the `env` keys from `~/.claude/settings.json` (or restore `settings.json.bak-duo`), delete the two symlinks in `~/.claude/skills/`, and remove the "duo indicator" block from the status line script.

## Choosing reviewer models

`agent --list-models` lists ~240 ids, shaped `<family>-<effort>[-fast]` (effort: none→low→medium→high→xhigh→max).

- **Never pick a Claude model as the reviewer.** The value of this loop is independent failure modes; a same-family reviewer shares the implementer's blind spots.
- Avoid `auto` (non-deterministic reviewer) and the Flash/Mini/Nano tiers (a reviewer that misses things manufactures false confidence).
- `-fast` variants buy little here — hooks run while you wait anyway.
- Usage limits are per-family on Cursor plans: if one family is exhausted, another may still work (`agent -p --model <id> "Reply OK"` is a cheap probe).
- Notable families: Codex 5.3 (code-specialised), GPT-5.6 Sol/Terra/Luna (1M general), GPT-5.5/5.4/5.2, Grok 4.7/4.6, Gemini Flash, Kimi, GLM.

## Status line

`~/.config/ai/statusline-command.sh` (copy it to `~/.claude/statusline-command.sh`) renders:

```
 <dir> | <model> | Ctx: 24% (240.9k tok) | 5h 14%↺3h39m · 7d 13%↺5d | DUO grok-4.7-high | cur: grok ok
```

- **Ctx / 5h / 7d** come from the status-line JSON (`context_window`, `rate_limits.*.used_percentage` and `.resets_at`); `↺` is time until that window resets.
- **DUO** names the configured reviewers: one id when both reviews use the same model, otherwise `<plan>-><diff>` (e.g. `DUO gpt-5.6-sol-high->gpt-5.3-codex-high`). Read from `env` in settings, so it reflects what the next review will actually use.
- **cur:** is last-known Cursor state per model family, written by the hooks on every review (`~/.claude/duo-cursor-status.json`). Cursor publishes no usage API and its CLI has no usage command, so this is *state at the last review*, not a live percentage: `ok`, or `⛔<n>d` when that family reported a weekly limit. It only shows while duo is on. Probing Cursor to refresh it would itself consume usage.

## Known limits

- The diff review sees the **whole** uncommitted diff of the repo, including your own pre-existing uncommitted work.
- Cursor sees your messages and the plan/diff, not Claude's replies or reasoning.
- Each Cursor call is a full agent run over the repo: expect 30 s – 3 min per review. Hook timeouts are 600 s (plan) / 900 s (diff).
- The plan reviewed is the plan file **this session** wrote (resolved from the transcript). If that cannot be determined the plan review is skipped rather than reviewing an unrelated plan.
- **Each Cursor call is a fresh session** — no `--resume`/`--continue`. The diff reviewer does not see the plan, and round N does not remember round N-1. Anything a reviewer must know has to be in its prompt.
- If Cursor errors (weekly usage limit, bad model id, not logged in) the review is skipped **fail-open** — Claude proceeds and the status message quotes Cursor's error.
- `agent` CLI flags (`-p`, `--mode ask`, `--output-format`, `--trust`) are as of Cursor CLI 2026.09; if a review returns nothing, run the `agent -p …` line from `common.sh` manually.
