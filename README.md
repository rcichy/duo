# duo — Claude Code + Cursor review loop

Two-model workflow for Claude Code: Claude plans and implements, Cursor (GPT/Codex, read-only) reviews the plan and then the diff, Claude validates the feedback and fixes what is real. Changes are always left **unstaged** for the human. Enforced by Claude Code hooks, not by prompting.

```
you: "implement X"  (Claude in plan mode)
  └─ Claude writes plan → ExitPlanMode
       └─ hook: Cursor reviews plan  → [BLOCKER]: denied, Claude edits plan, retries (max 3 rounds)
                                     → [ESCALATE] only: denied once, Claude asks you, records the decision
                                     → APPROVE: Claude implements
            └─ Claude stops
                 └─ hook: Cursor reviews diff → [BLOCKER]: stop blocked, Claude verifies + fixes, stops again (max 3)
                                              → [ESCALATE] only: Claude asks you (no round used)
                                              → LGTM: done, diff left unstaged
```

## Findings, verdicts and rounds

- Cursor tags every finding `[BLOCKER]`, `[SHOULD]`, `[NIT]` or `[ESCALATE]`. Only a blocker makes Claude change the
  work before continuing; `[SHOULD]`/`[NIT]` are optional and shown to you; `[ESCALATE]` (a product/scope/ops
  trade-off, or a disagreement that Claude's answer did not settle) goes to you through Claude's AskUserQuestion.
- A **valid** answer has the verdict word alone on a line near the top (`APPROVE`/`REVISE`, `LGTM`/`CHANGES`);
  Cursor is told to answer with that single word when there is nothing to change. An empty or verdict-less answer
  is retried once. If the retry fails too, Claude is stopped once and told to tell you the review did not happen
  (no round used, no loop). Each call is capped at `DUO_AGENT_TIMEOUT` and logged with exit code and duration in
  `/tmp/claude-duo-<session>-answers.log`.
- Rounds are counted per request: only a review with a `[BLOCKER]` uses one, the counter resets on approval and
  whenever you send a new message, and at the cap it stays capped until one of those happens.
- Between rounds Cursor gets its previous findings plus Claude's reply (what was fixed, why the rest was rejected),
  so a rejected point is not repeated without new evidence; a real disagreement becomes `[ESCALATE]`.

## What each reviewer is told

Every Cursor call is a fresh session (no `--resume`), so each prompt carries its own context:

| Section | Plan review | Diff review | Source |
|---|---|---|---|
| `TASK TITLE` | yes | yes | session title (`customTitle`, else `aiTitle`) |
| `ORIGINAL REQUEST` | yes | yes | your first message this session — survives truncation |
| `TEAM REVIEW GUIDE` | yes | yes | `$DUO_HOME/review-guide.md` (see below) |
| `TASK CONTEXT` | yes | yes | your typed messages, a placeholder for each attached image, and your answers to Claude's AskUserQuestion prompts, in order (tool output, skills, system reminders and hook feedback filtered out) |
| `APPROVED PLAN` | — | yes | cached when the plan review approves; the plan starts with the ticket's requirements verbatim (images transcribed by Claude), so the diff is checked against them |
| `PREVIOUS ROUND` | yes | yes | Cursor's findings from the last round of this request + Claude's latest reply |
| `PLAN` / `DIFF` | the plan | `git diff` + untracked files | |

### Team review guide

`$DUO_HOME/review-guide.md` (override with `DUO_REVIEW_GUIDE`) holds how the human reviewers of every repo under
`DUO_HOME` review MRs: requirements and sibling code paths, failure modes, blast radius, transactions, tests,
simplicity, logging, conventions, with repo-specific items labelled. Cursor only auto-loads `AGENTS.md`,
`CLAUDE.md` and `.cursor/rules` of the repo it runs in, so the hooks paste the guide into both prompts. Grow it
from real review threads; a missing file just drops the section.

## Files

| File | Purpose |
|---|---|
| `hooks/common.sh` | gate (`DUO_HOME` + marker), round counters, `duo_ask` (Cursor call), transcript context |
| `hooks/review-plan.sh` | `PreToolUse` on `ExitPlanMode` |
| `hooks/review-diff.sh` | `Stop` — reviews `git diff` + untracked files |
| `hooks/block-git-staging.sh` | `PreToolUse` on `Bash` — denies `git add/commit/stash/push/reset/restore` while duo is on |
| `hooks/mark-aside.sh` | `UserPromptSubmit` - marks a `/btw` turn so the Stop hook skips the review |
| `skills/btw` | `/btw` - same marker as a slash command, and tells Claude to answer without implementing |
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
| `DUO_ASIDE_RE` | `^\s*/?btw(\s\|,\|:\|$)` | message prefix that marks a turn as an aside |
| `DUO_ASIDE_CHARS` | `4000` | max chars of recorded side discussion passed to a reviewer |
| `DUO_MAX_ROUNDS` | `3` | cap for plan rounds and, separately, diff rounds |
| `DUO_CTX_CHARS` | `12000` | max chars of your own messages forwarded to Cursor (most recent kept; truncation is marked) |
| `DUO_TASK_CHARS` | `2000` | max chars of the opening request quoted in the task header |
| `DUO_PROMPT_LOG` | unset | file to append every prompt sent to Cursor — for debugging what a reviewer actually saw |
| `DUO_REVIEW_GUIDE` | `$DUO_HOME/review-guide.md` | team review guide pasted into both prompts |
| `DUO_REPLY_CHARS` | `6000` | max chars of Claude's latest reply passed to the next round |
| `DUO_AGENT_TIMEOUT` | `1500` | seconds per Cursor call, below the 1800 s hook timeouts, so a slow reviewer is reported; a timed-out call is not retried |

Round counters, the last review and escalation flags live in `/tmp/claude-duo-<session>-*`; delete them to reset a session.

## Uninstall

Remove the three hook entries and the `env` keys from `~/.claude/settings.json` (or restore `settings.json.bak-duo`), delete the two symlinks in `~/.claude/skills/`, and remove the "duo indicator" block from the status line script.

## Choosing reviewer models

`agent --list-models` lists ~240 ids, shaped `<family>-<effort>[-fast]` (effort: none→low→medium→high→xhigh→max).

- **Never pick a Claude model as the reviewer.** The value of this loop is independent failure modes; a same-family reviewer shares the implementer's blind spots.
- Avoid `auto` (non-deterministic reviewer) and the Flash/Mini/Nano tiers (a reviewer that misses things manufactures false confidence).
- `-fast` variants buy little here — hooks run while you wait anyway.
- Usage limits are per-family on Cursor plans: if one family is exhausted, another may still work (`agent -p --model <id> "Reply OK"` is a cheap probe).
- Notable families: Codex 5.3 (code-specialised), GPT-5.6 Sol/Terra/Luna (1M general), GPT-5.5/5.4/5.2, Grok 4.7/4.6, Gemini Flash, Kimi, GLM.

## Asides (`/btw`)

A side question during implementation - a decision, a clarification, "why did you do it that way" - should not spend
a Cursor call on a half-finished diff.

Start the message with `/btw` (or plain `btw,`): Claude answers, and that turn's Stop hook skips the Cursor review
and the prose gate without consuming a round. The diff stays unreviewed, so the next ordinary turn sends it to
Cursor as usual - nothing is skipped permanently.

The discussion is not lost either. Your own messages already reach a reviewer through `TASK CONTEXT`; on an aside
turn the hook additionally records Claude's answer, and both reviews then carry a `SIDE DISCUSSION` block telling
the reviewer to treat decisions settled there as agreed - and to flag anything in the plan or diff that contradicts
them.

Two paths set the same one-turn flag, so it works however you type it: the `UserPromptSubmit` hook matches
`DUO_ASIDE_RE` against the raw message, and the `/btw` skill sets a fallback flag and tells Claude to answer rather
than implement.

## Prose (Claude-side)

Non-code text is not part of the Cursor loop. `/duo-on` tells Claude to run the `no-ai-slop` skill over the prose it
wrote or changed as a step of implementing, after the tests pass and before it stops, so Cursor reviews the finished
change and knows nothing about the skill. `no-ai-slop` is a user-level skill in `~/.claude/skills/`, not part of
this package.

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
