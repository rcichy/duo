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
                                              → LGTM: Claude tells you it is approved and what you do next;
                                                diff left unstaged
```

## Why

A model reviewing its own work shares its own blind spots. duo puts a model from a different family in the
reviewer's seat at the two points where a mistake is cheapest to catch: the plan and the diff. The rules live in
hooks rather than in the prompt, so they hold even when the agent improvises: it cannot stage or commit, every
blocking finding gets an answer, and a real disagreement goes to the human instead of looping. `/duo-stats` measures
how often the second reviewer actually changed the outcome.

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
- The loop never just goes quiet. On LGTM, and when the rounds run out, the hook blocks the stop once more, and Claude
  ends with a handoff: Cursor's verdict (at the cap: that its latest changes are unreviewed, with the last
  blockers and what it did about each), the tests it ran, Cursor's `[SHOULD]`/`[NIT]` for you to decide on, and
  the next step, which is yours: review the unstaged changes, then commit them or ask for more. The diff is
  already marked reviewed, so that last stop goes through.
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
| `PLAN CHANGES SINCE APPROVAL` | — | yes | a diff of the plan file against the approved plan, when Claude edited it after the approval (a deviation decided while implementing); counts as the deviation's stated reason |
| `GUIDE CHECK` | — | yes | `DUO_NEW_CODE_RUFF` findings on the added lines that Claude was asked to fix and kept |
| `PREVIOUS ROUND` | yes | yes | Cursor's findings from the last round of this request (including a review that only escalated) + Claude's latest reply |
| `PLAN` / `DIFF` | the plan | `git diff` + untracked files | |

### Team review guide

`$DUO_HOME/review-guide.md` (override with `DUO_REVIEW_GUIDE`) holds how the human reviewers of every repo under
`DUO_HOME` review MRs: requirements and sibling code paths, failure modes, blast radius, transactions, tests,
simplicity, logging, conventions, with repo-specific items labelled. Cursor only auto-loads `AGENTS.md`,
`CLAUDE.md` and `.cursor/rules` of the repo it runs in, so the hooks paste the guide into both prompts. Grow it
from real review threads; a missing file just drops the section.

The guide applies to new code even where the old code around it does not follow it, and that is where reviews
slip: Claude copies the pattern next to it (an untyped test beside untyped tests), and a reviewer model weighs
style low. So Cursor is told to check the guide rule by rule and to make a clear breach in new code a
`[BLOCKER]`, and rules a linter can check are checked mechanically: set `DUO_NEW_CODE_RUFF` to ruff rule codes
(e.g. `ANN001,ANN002,ANN003,ANN201,ANN202,ANN204,ANN205,ANN206` for annotations, `PLC0415` for imports at the top,
`BLE001` for `except Exception`). Before any Cursor call, the Stop hook runs ruff with those rules on the lines
the change adds (not on the old code; the repo's ruff config still decides excludes and `# noqa`) and hands
the findings to Claude, once per set of findings and without costing a round. What Claude keeps goes to Cursor
as `GUIDE CHECK`, a blocker unless Claude gave a reason.

## Files

| File | Purpose |
|---|---|
| `hooks/common.sh` | gate (`DUO_HOME` + slot switch), round counters, `duo_ask` (Cursor call), transcript context |
| `hooks/slot.sh` | which slot a directory belongs to, and where that slot's switch and aside flag live |
| `hooks/herdr-run.sh` | runs one Cursor review inside a herdr pane when `DUO_USE_HERDR=1` |
| `duo-mode.sh` | `on`/`off`/`aside`/`status` for a slot; used by the skills and the status line |
| `hooks/review-plan.sh` | `PreToolUse` on `ExitPlanMode` |
| `hooks/review-diff.sh` | `Stop` — reviews `git diff` + untracked files |
| `hooks/new-code-check.py` | ruff on the added lines only, for `DUO_NEW_CODE_RUFF` |
| `hooks/block-git-staging.sh` | `PreToolUse` on `Bash` — denies git commands that stage, commit, discard or switch away from the work while duo is on |
| `hooks/mark-aside.sh` | `UserPromptSubmit` - marks a `/btw` turn so the Stop hook skips the review |
| `skills/btw` | `/btw` - same marker as a slash command, and tells Claude to answer without implementing |
| `skills/duo-on`, `skills/duo-off` | `/duo-on` `/duo-off` — switch the current slot on/off and brief Claude on the rules |
| `skills/duo-advisor` | `/duo-advisor` — reads a finished duo session and proposes changes to duo that would have made the reviewers' comments unnecessary |
| `skills/duo-stats` | `/duo-stats [period]` — statistics of the duo sessions in a period: what Cursor's reviews changed, how much you steered, cost, merge request comments |
| `tools/duo_exchange.py` | extracts one duo session (timeline, plans, reviews, reviewer comments); used by `/duo-advisor` and `/duo-stats` |
| `tools/duo_stats.py` | counts the events of every duo session in a period, for `/duo-stats` |
| `review-guide.example.md` | starting point for your team review guide (copy to `$DUO_HOME/review-guide.md`) |
| `hooks.settings.json` | fragment merged into `~/.claude/settings.json` by the installer |
| `statusline-duo.snippet.sh` | adds ` \| DUO` to the status line while active |
| `install.sh` | idempotent installer |

## How it is scoped (important)

Hooks are registered **globally** in `~/.claude/settings.json` (Claude Code does not inherit `.claude/settings` from parent directories — verified), but every script exits immediately unless **both**:

1. the session was started in a **slot** under `DUO_HOME` (a folder of repos you choose at install time), and
2. that slot is switched on: `DUO_HOME/.claude/duo.on.d/<slot>` exists (toggled by `/duo-on` / `/duo-off`).

A slot is one git checkout: the repo the session was started in (`CLAUDE_PROJECT_DIR`), even after Claude cd's
into a sibling repo. A slot can also be a directory that is not a checkout but holds one checkout per repo (a
workspace for a task that spans several repos): Cursor then runs in that directory, and the diff review covers the
changes of every checkout in it, with paths prefixed by the checkout's directory. `DUO_HOME` itself is never such a slot.
Any directory inside a multi-repo slot belongs to it, including its checkouts: `/duo-off` and `/btw` run as plain Bash
commands, which do not get `CLAUDE_PROJECT_DIR` and start wherever Claude has cd'd to, and must still find the
slot the hooks use. `off` says so when the slot was not on, and lists where duo is on. Two clones of the same repo are two slots, so one can run a task under review while the
other runs plain Claude. The switch and the `/btw` flag live in `DUO_HOME/.claude/`, outside the checkout, so they
never show up in a reviewed diff. `duo-mode.sh status` lists the slots that are on.

So plain Claude is unaffected everywhere else, and unaffected in a slot until you opt in there.

## Install on a new machine

duo must live in `~/.config/ai/duo`: the skills, hooks and status-line snippet call it there.

```bash
git clone <this repo> ~/.config/ai/duo
```

Prerequisites: Claude Code, `jq` (`brew install jq`), on macOS `coreutils` for the per-call timeout
(`brew install coreutils`; without it only the hook timeout applies), and the Cursor CLI:

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
- symlinks `~/.claude/skills/duo-on`, `duo-off`, `btw`, `duo-advisor` and `duo-stats` to this folder (so `git pull` updates them),
- patches `~/.claude/statusline-command.sh` if it has the known shape, otherwise prints a TODO with the snippet to add.

Verify: open Claude Code inside `DUO_HOME`, run `/hooks` (three entries pointing at `~/.config/ai/duo/hooks/`), then `/duo-on` — the status line shows `DUO`.

### Instructions for Claude doing the install

1. Run `install.sh <DUO_HOME>` with the folder the user names. Do not guess the folder; ask if not given.
2. If it prints a `TODO` for the status line, edit `~/.claude/statusline-command.sh`: paste `statusline-duo.snippet.sh` before the final `echo` and append `$duo` to the echoed string. The snippet expects a variable `$dir` holding the cwd from the status-line JSON (`.cwd`).
3. Pipe-test without spending Cursor calls:
   ```bash
   echo '{"session_id":"t","cwd":"<DUO_HOME>/some-repo","tool_input":{"command":"git add ."}}' | ~/.config/ai/duo/hooks/block-git-staging.sh
   ```
   With the slot off: no output. After `duo-mode.sh on <DUO_HOME>/some-repo`: a JSON `deny`. Run `duo-mode.sh off <DUO_HOME>/some-repo` afterwards.
4. Do not commit anything in the user's repos; the whole point of duo is that the human commits.

## Usage

```
cd <DUO_HOME>/<repo>
claude
> /duo-on           # this slot only
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
| `DUO_LOG_DIR` | `~/.claude/duo-log` | call archive for `/duo-advisor`: `<session>/<n>-<hook>.prompt.md`, `.answer.md` and `.reads` (the files Cursor read; herdr runs only) for every Cursor call; empty keeps nothing. Nothing prunes it |
| `DUO_REVIEW_GUIDE` | `$DUO_HOME/review-guide.md` | team review guide pasted into both prompts |
| `DUO_NEW_CODE_RUFF` | unset | ruff rule codes checked on the lines a change adds, before the Cursor diff review (see "Team review guide"); needs `ruff` on PATH. Read from `settings.json` on every review, so a change applies to running sessions too. Docstring rules (`D…`) are not applied to test files |
| `DUO_NEW_CODE_RUFF_STRICT` | unset | codes from `DUO_NEW_CODE_RUFF` that apply even where a repo's `per-file-ignores` turn them off (a repo that exempts its tests from typing the team requires everywhere); `# noqa` and excludes still apply. Also read from `settings.json` on every review |
| `DUO_REPLY_CHARS` | `6000` | max chars of Claude's latest reply passed to the next round |
| `DUO_USE_HERDR` | `0` | `1`: when Claude runs inside [herdr](https://herdr.dev), each Cursor review runs in a herdr pane next to Claude's, showing the files it reads and its answer as they come; the hook waits for it as before. Outside herdr, or if the pane cannot be made, the call runs directly |
| `DUO_HERDR_SPLIT` | `right` | where that pane opens: `right` or `down`. One pane per Claude session, reused for every review; close it and the next review opens a new one |
| `DUO_AGENT_TIMEOUT` | `1500` | seconds per Cursor call, below the 1800 s hook timeouts, so a slow reviewer is reported; a timed-out call is not retried |

Round counters, the last review and escalation flags live in `/tmp/claude-duo-<session>-*`; delete them to reset a session.

## Uninstall

Remove the three hook entries and the `env` keys from `~/.claude/settings.json` (or restore `settings.json.bak-duo`), delete the three symlinks in `~/.claude/skills/`, and remove the "duo indicator" block from the status line script.

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

## Advisor (`/duo-advisor`)

`/duo-advisor <session>` (a session id, or a ticket key or branch in the session's directory or title) reads one duo
session after the fact. `tools/duo_exchange.py` extracts it: a timeline of the user's messages, plans, Cursor's reviews and
Claude's answers, questions and gates, plus the merge request comments autoduo fetched for the ticket
(`.autoduo/inbox/`). The advisor then traces every reviewer comment to the earliest point where duo could have
stopped it (a gap in the guide, a rule only in Claude's memory, a breach Cursor did not flag, context Cursor never
got, a finding Claude dismissed). It proposes the change at that layer: a linter rule, a guide rule, Cursor's rubric,
the prompt contents, or Claude's instructions. The report goes to `$DUO_HOME/.claude/duo-advisor/`, so later runs can
tell whether a cause keeps coming back. It applies only the proposals you pick, and commits nothing.

The call archive (`DUO_LOG_DIR`) lets the advisor see exactly what each Cursor call was given and which files it
read. A session from before the archive existed can still be analysed, from the transcript alone.

## Statistics (`/duo-stats`)

`/duo-stats [period]` (two dates, a month, or "last N days"; default the last 30 days) counts what happened in the duo
sessions of the period. `tools/duo_stats.py` counts from the transcripts; Claude then reads every review with
blockers, together with its answer, and labels each finding fixed, fixed partly, rejected or put to the user. A
transcript does not record that on its own. The report covers:
- **Cursor's effect**: reviews with blockers, findings fixed or rejected, plans revised, escalations, gate blocks.
- **Your part**: messages, plans you approved (and how long you looked first), plans you sent back, and your
  decisions: Claude's recommendation, another option, or your own words.
- **Cost**: Cursor minutes, failed reviews, round caps.
- **Outcome**: merge request comments per ticket.

It also includes a summary with no project details, safe to publish. Reports go to `$DUO_HOME/.claude/duo-stats/`.

## Prose (Claude-side)

Non-code text is not part of the Cursor loop. `/duo-on` tells Claude to run the `no-ai-slop` skill over the prose it
wrote or changed as a step of implementing, after the tests pass and before it stops, so Cursor reviews the finished
change and knows nothing about the skill. `no-ai-slop` is a user-level skill in `~/.claude/skills/`, not part of
this package.

## Status line

`statusline-duo.snippet.sh` appends ` | DUO` to your Claude Code status line while duo is on for the session's slot
(`install.sh` patches `~/.claude/statusline-command.sh` when it has the known shape, otherwise prints a TODO).

The hooks also record the last-known Cursor state per model in `~/.claude/duo-cursor-status.json`: `ok`, or a
weekly-limit flag with its reset time. Cursor publishes no usage API and its CLI has no usage command, so this is
*state at the last review*, not a live percentage; a custom status line can read the file to show it. Probing Cursor
to refresh it would itself consume usage.

## Known limits

- No diff review runs while a rebase, merge, cherry-pick or revert is in progress in a reviewed checkout: the
  half-applied tree is your operation, not Claude's change. The next stop after it ends is reviewed as usual.

- The diff review sees the **whole** uncommitted diff of the repo (of every repo, in a multi-repo slot), including your own pre-existing uncommitted work.
- Cursor sees your messages, the plan/diff, and Claude's latest reply only where it is passed on (after a review round, or an
  aside answer); never Claude's reasoning or tool output.
- Each Cursor call is a full agent run over the repo: expect 30 s – 3 min per review. Hook timeouts are 1800 s; each Cursor call is capped at `DUO_AGENT_TIMEOUT` (1500 s) when a `timeout`/`gtimeout`
  command exists.
- The plan reviewed is the plan file **this session** wrote (resolved from the transcript). If that cannot be determined the plan review is skipped rather than reviewing an unrelated plan.
- **Each Cursor call is a fresh session** — no `--resume`/`--continue`. Continuity comes from the prompt: the diff review receives the approved plan, and each round receives the previous
  findings plus Claude's reply. Anything else a reviewer must know has to be in its prompt.
- The git guard is a safeguard against mistakes, not a security boundary: it matches git commands in the Bash tool
  input, so a script or an alias that runs git can get past it.
- If Cursor errors (weekly usage limit, bad model id, not logged in) the review is skipped **fail-open** — Claude proceeds and the status message quotes Cursor's error.
- `agent` CLI flags (`-p`, `--mode ask`, `--output-format`, `--trust`) are as of Cursor CLI 2026.09; if a review returns nothing, run the `agent -p …` line from `common.sh` manually.
