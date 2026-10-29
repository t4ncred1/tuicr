---
name: tuicr
description: Use tuicr's review CLI to read, add, and reply to comments in active TUI review sessions, watch a live review so new feedback arrives while you work or sit idle, and launch tuicr in cmux, tmux, Zellij, or Herdr when a user needs an interactive review pane.
---

# tuicr Review Workflow

Use `tuicr review` as the default agent interface. The TUI is where the human
reviews code; the CLI is how the agent discovers active sessions, reads user
comments, and, only when appropriate, adds agent-authored comments.

## Core Rule

First decide which workflow the user is asking for:

1. **User-led review of agent-generated changes**
   - The user wants to inspect the patch and write comments in tuicr.
   - Your job is to open or find the session, then retrieve the user's comments
     with `tuicr review comments` when they say comments are ready. If you are
     explicitly waiting while the user reviews, poll the same command
     periodically and look for new comment IDs.
   - Do not add your own review comments, do not preemptively review your own
     patch, and do not impersonate the user's comments.

2. **Agent review of an AI-generated patch**
   - The user wants you to understand, critique, or summarize a patch.
   - You may inspect the patch and propose findings.
   - If you can confidently identify this workflow and the target session, add
     findings directly with `tuicr review add` and an explicit `--username`
     identifying the agent. Ask first when the workflow or session is ambiguous.

If the user's intent is ambiguous, ask which workflow they want.

## Attach To A Session

1. Determine the repository directory from the user's request, current working
   directory, or recent file operations. Ask if it is ambiguous.

2. List persisted sessions:

   ```bash
   tuicr review list --repo /path/to/repo   # checkout + its repo's PR sessions
   tuicr review list --repo owner/repo      # all sessions for a forge repo
   tuicr review list --all                  # every session across all repos
   ```

   `--repo` is a selector: a checkout path also surfaces PR sessions for that
   checkout's `origin` repo, and a forge coordinate like `owner/repo` matches
   local and PR sessions by owner/repo. Each row carries a `kind` (`local` or
   `pr`) and a usable `slug`. Use `--all` when you don't know the repo.

   `[]` with exit 0 also means "not a repo root" — a subdirectory returns it
   too. Pass the root, then `--all`, before concluding nothing is open.

3. Choose the session:
   - If the CLI clearly reports exactly one relevant active session with
     `"active": true`, attach to it.
   - If multiple sessions are active, or the correct session is not clear, ask
     the user which slug to use. One repo can hold a worktree and a
     commit-range session at once, and adding to the wrong one exits 0.
   - If the user provided a slug or session JSON path, use it directly.
   - For a PR review, pass the PR slug from the listing (e.g.
     `gh:owner/repo/pr/N`) to `--session`; it is self-contained and needs no
     `--repo`.
   - If there is no active session, start or wait for one as described below.
   - Until active-session discovery is formalized as a stable protocol, treat
     `"active": true` as a convenience signal. If slug resolution fails, ask the
     user for the slug or repo path used by the session.

The CLI works even if the agent is not running inside tmux, Zellij, or Herdr,
so do not require a multiplexer just to connect to an existing active session.

## Start A Session

When the user needs an interactive tuicr pane and no active session exists:

| Environment | Action |
|-------------|--------|
| `$CMUX_WORKSPACE_ID` is set | Run `tuicr-wrapper-cmux.sh /path/to/repo -- <scope>` |
| `$TMUX` is set | Run `tuicr-wrapper.sh /path/to/repo -- <scope>` |
| `$ZELLIJ` is set | Run `tuicr-wrapper-zellij.sh /path/to/repo -- <scope>` |
| `$HERDR_ENV` is `1` | Run `tuicr-wrapper-herdr.sh /path/to/repo -- <scope>` |
| None is set | Tell the user you are waiting for them to start `tuicr` in the repo, then attach with `tuicr review list` after they say it is ready |

`<scope>` is `--branch` for everything on the current branch (its commits
since it forked plus uncommitted changes, followed as new commits land), `-w`
for uncommitted working-tree changes only, or `-r <revset>` for a commit
range — always pass one explicitly so the user is never left to pick
staged/unstaged/commit-range manually in the TUI.

If more than one multiplexer marker is set, prefer the innermost multiplexer if
that is clear; otherwise ask. cmux hosts a Ghostty terminal, so `$TERM_PROGRAM`
reads `ghostty` inside cmux — check `$CMUX_WORKSPACE_ID`, not the terminal name.

tuicr supports both git and Jujutsu (jj) repositories, and jj workspaces may
have no `.git` directory at all. Do not pre-check the directory with
`git rev-parse` or refuse to launch because git does not recognize it; always
run the wrapper and let it validate the repository.

Wrapper paths are relative to this skill directory:

```bash
<skill-directory>/tuicr-wrapper-cmux.sh /path/to/repo -- -w
<skill-directory>/tuicr-wrapper.sh /path/to/repo -- -w
<skill-directory>/tuicr-wrapper-zellij.sh /path/to/repo -- -w
<skill-directory>/tuicr-wrapper-herdr.sh /path/to/repo -- -w
```

The Herdr wrapper requires `jq` to read pane IDs and completion results from
Herdr's JSON responses.

Every wrapper accepts pass-through tuicr arguments after `--`, which is how
you scope the review instead of leaving the scope selector for the user to
fill in — for example `-- -w` for uncommitted working-tree changes or
`-- -r <revset>` for a commit range. Always pass one of these explicitly when
launching a review pane.

If your tool supports command timeouts, use a long timeout, such as 10 minutes,
because the tmux, Zellij, and Herdr wrappers wait for the TUI to exit. The cmux
wrapper is the exception: it returns as soon as the pane is running and prints
the new surface ref between `=== TUICR SURFACE ===` markers. Capture that ref —
it is how you close the pane later with `cmux close-surface --surface <ref>`.
Once the TUI creates its active session, use
`tuicr review list --repo /path/to/repo` to capture the slug. If your
environment cannot run another command while a blocking wrapper is waiting,
read the comments after the user exits tuicr.

## Reconstruct The Diff

To review a patch yourself, rebuild the diff the user sees. The slug's source
segment says which:

| Slug segment | Diff |
|--------------|------|
| `worktree/<head>`, `staged-and-unstaged/<head>` | `git diff HEAD` |
| `staged/<head>` | `git diff --cached` |
| `unstaged/<head>` | `git diff` |
| `commits/<base>..<head>` | `git diff <base>~1..<head>` |
| `pr/<n>` | `gh pr diff <n>` |
| `pristine` | none; every tracked file shown in full |
| `branch` | `git diff <fork-point>`, where the fork point is the `git merge-base HEAD <ref>` nearest to HEAD among `main`/`master` (local and remote) |

Range endpoints are inclusive and printed oldest-first, so `<base>` without
`~1` drops the first commit. Check the file count against the listing row's
`file_count`; a mismatch means every line number you derive will be wrong.

## Read User Comments

This is the main review loop for user-led review.

There is no push stream from tuicr to the agent. Read comments by running the
CLI on demand. After the user says comments are ready, or after the TUI exits,
run:

```bash
tuicr review comments --repo /path/to/repo --session <slug>
```

The command emits JSON. Each comment includes fields like:

- `id`
- `location`
- `path`
- `start_line`
- `end_line`
- `side`
- `comment_type`
- `author`
- `lifecycle_state`
- `content`

Treat these comments as the user's review feedback:

- `issue`: blocking problem to fix first
- `suggestion`: consider implementing or explain why not
- `note`: answer or acknowledge
- `ask`: a question only. Answer it in its thread and leave the code as it
  is. When the answer points to a fix, describe it and add that the user can
  comment with type `claude` to have it made.
- `praise`: no action required

If you are waiting during an active review, poll this command about every 30
seconds and compare comment IDs with the previous result. Read immediately when
the user says comments are ready. Stop polling once the user says the review is
done or your tooling would block other work.

An empty result does not by itself mean the review didn't happen. On exit,
tuicr always prints a line like `tuicr-summary: reviewed 3/3 files, 0 comments
added` to stderr (visible in the pane's scrollback), and `tuicr review list`
reports the same `reviewed_count`/`file_count` for the session. If
`reviewed_count` equals `file_count`, zero comments is a legitimate "nothing to
flag" outcome — treat the review as complete, don't ask the user to confirm.
Only ask whether the user saved comments in the intended session, or whether
another active session should be selected, when `reviewed_count` is less than
`file_count` (the user quit before reviewing everything) or you can't find a
`tuicr-summary:` line at all. If the review may have continued while you were
working, rerun `tuicr review comments` before claiming completion.

## Add Agent Comments

Only add comments when the workflow allows it and, for agent-authored review,
after the user approves writing them into tuicr.

Defaults:

- Prefer line comments when a specific file and line are known.
- Use file comments for file-scoped feedback.
- Use review-level comments only for whole-review summaries.
- Use `--type issue` for problems by default.
- Use `suggestion`, `note`, or `praise` when that better matches the intent.
- Pass `--username` so agent comments are visually distinguishable.

Examples:

```bash
tuicr review add --repo /path/to/repo --session <slug> \
  --target-file src/main.rs \
  --line 42 \
  --side new \
  --type issue \
  --username "Codex" \
  "Handle the empty case here."
```

```bash
tuicr review add --repo /path/to/repo --session <slug> \
  --target-file src/main.rs \
  --type suggestion \
  --username "Codex" \
  "Consider splitting this file-level concern into a helper."
```

Omit `--target-file` for a review-level comment. Add `--end-line` for a range
comment. Use `--side old` for removed lines and `--side new` for added or
unchanged lines in the new file.

For structured input, use `--input` with literal JSON, `@path/to/file.json`, or
`-` for stdin. Supported target types are `review`, `file`, `line`, and
`line_range`. One object per call — an array is a parse error. The file key is
`file`, not `path`. `target.type` is inferred from the fields present:

```bash
tuicr review add --session <slug> --username "Codex" --input \
  '{"file":"src/main.rs","line":42,"side":"new","comment_type":"issue","content":"Handle the empty case."}'
```

Then verify. A line outside the diff stores, prints back, and exits 0, but
never renders — invisible to the user, successful-looking to you. Re-read
`tuicr review comments` and check each `start_line` exists on the side you gave
(`new` for added or unchanged, `old` for removed). Check `author` to distinguish
your comments from the user's, and keep the returned `id`s to identify the exact
comments in later reads.

## Reply To The User's Comments

When you act on a user comment, answer it in its thread rather than adding a
new comment beside it:

```bash
tuicr review add --repo /path/to/repo --session <slug> \
  --username "Claude" \
  --reply-to <comment-id> \
  "Done: the empty case now returns early."
```

Replies show inside the comment's box in the TUI, carry no location or type of
their own, and are never posted to a forge. In `tuicr review comments` each
comment lists its thread under `replies`, oldest first. A thread whose last
entry is yours is answered; one whose last entry is the user's (the comment
itself, or a reply to you) is still waiting.

## Watch A Live Review

A live review keeps tuicr open beside you while you work: the user comments,
you act on each comment and answer it in its thread.

To open tuicr for it under Herdr (`$HERDR_ENV` is `1`), run the tab launcher
with your **current working directory**, not the repository you started in —
after you move to another worktree, that is the checkout holding your changes:

```bash
<skill-directory>/tuicr-herdr-tab.sh "$PWD"
```

It returns immediately, opens a `tuicr <repo>` tab in the user's workspace (or
focuses the one already open for that repository), and reviews with
`--branch`: every commit on your branch since it forked plus uncommitted
changes, in one session tied to the branch. Commits you make later join the
review when the user reloads, and their comments stay put, so commit freely.
Pass `-- --branch=<base>` when the branch forked from something other than
`main` or `master`, or `-- <tuicr-args>` for another scope. tuicr refuses to
start while the branch has nothing to review, so open it once you have
changes. If you move to another
worktree mid-review, run it again for the new directory. Outside Herdr, use the
launchers under "Start A Session".

When the review is over, `<skill-directory>/tuicr-herdr-close.sh "$PWD"`
saves and quits every tuicr tab open for that repository. It never forces a
tab: one with a comment being typed or an editor open is reported as
`left open <label>: <reason>` and stays, for the user to finish.

Then run `tuicr-watch.sh` (in this skill directory) with `--once` as a
background command that notifies you when it exits (in Claude Code, Bash with
`run_in_background`). It waits silently until a thread opens, prints every
thread open at that moment, and exits, so waiting costs nothing while the
user is quiet. Start it with `--reset` when you begin watching, so every
thread already open is reported once:

```bash
<skill-directory>/tuicr-watch.sh --reset --once "$PWD"
```

After answering the threads it reported, start it again **without**
`--reset`: the watcher remembers what it reported, so only new activity comes
through, and nothing that arrived in between is missed. Prefer this to a
long-running monitor (Claude Code's `Monitor` tool): a monitor times out
after at most 30 minutes, and every re-arm wakes you for nothing. Without
`--once` the watcher runs forever and prints each event as it happens, for
tools that stream output.

When you move to another worktree, stop the watcher and start it again with
`--reset` for the new directory.

It polls the repo's active local session and prints one line per event. To
watch a pull request review instead, pass its slug: `--session
gh:owner/repo/pr/N` (a PR session is never picked automatically, so a branch
review and a PR review can be open side by side).

- `tuicr: watching session <slug>` — a session is open; use this slug.
- `tuicr: open thread <id> <location> - @<author>: <text>` — a thread now
  waits on you: a new comment, an edited one, or a reply to your answer. The
  text is cut at 300 characters; read the full thread with
  `tuicr review comments --session <slug>`.
- The same line ending in `(re @<reviewer>: <their comment>)` — the comment
  answers a forge review thread (its `reply_to_thread`): the quoted reviewer
  comment is what is being asked, the user's text is their instruction about
  it.
- `tuicr: error: <message>` — the watcher has stopped; fix the cause and
  start it again.

With `--once`, the output you get on exit starts with the `watching session`
line, so every batch names the session to answer in.

Handle each open thread like a user comment (ISSUE first), then answer it with
`--reply-to <id>` as above. Your reply closes the thread, so it is not
reported again until the user responds. Pass `--username` matching
`TUICR_WATCH_AGENT` (default `Claude`), or your replies will not count as
answers.

Set `TUICR_WATCH_TYPES` to a comma-separated list of comment type ids (for
example `claude`) when the user keeps some comments to themselves: threads of
other types are never reported, and untyped comments count as type `none`.
Treat those threads as private when you read the session directly too.

The watcher stays silent while no tuicr session is open, and picks a session
up as soon as one starts. Stop it when the user is done reviewing.

## Legacy Export Output

Older wrapper-driven flows may emit:

```text
=== TUICR INSTRUCTIONS ===
...
=== END TUICR INSTRUCTIONS ===
```

If present, process those instructions. Otherwise prefer
`tuicr review comments`; it is the primary source of review feedback. If the
wrapper mentions clipboard export, ask the user to paste it only when the CLI
comments are unavailable.

## Multiplexer Tips

cmux:

- Switch panes: click the pane, or `cmux focus-pane --pane <ref>`
- Close tuicr: press `q`; the pane closes itself. Force it with `cmux close-surface --surface <ref>`
- List panes: `cmux list-panes`
- Read a pane without focusing it: `cmux read-screen --surface <ref>`

tmux:

- Switch panes: `Ctrl-b` then arrow keys
- Close tuicr: press `q`
- Resize panes: `Ctrl-b` then `Ctrl-arrow`
- Zoom pane: `Ctrl-b` then `z`

zellij:

- Switch panes: `Alt` + arrow keys
- Close tuicr: press `q`
- Resize panes: `Ctrl-n`, then arrow keys
- Toggle fullscreen: `Alt-f`
- Cycle stacked panes: `Alt` + `[` / `]`

Herdr:

- Select a pane: click it in the Herdr UI
- Close tuicr: press `q`; the wrapper then closes the review pane

## Error Handling

| Situation | Action |
|-----------|--------|
| Multiple plausible active sessions | Ask which session slug to use |
| No active session, cmux/tmux/Zellij/Herdr available | Start a new tuicr pane with the matching wrapper |
| No active session, no multiplexer | Tell the user you are waiting for them to start `tuicr` |
| cmux wrapper printed no surface ref | Run `cmux list-panes` to find the pane, or ask the user to start `tuicr` themselves |
| `tuicr` not installed | Tell the user to install tuicr |
| Not a repository | Ask for the correct repo directory |
| Comments are empty, but `reviewed_count` == `file_count` | Treat as a completed review with nothing to flag — don't ask |
| Comments are empty and `reviewed_count` < `file_count` | Confirm the selected session or ask the user to save/add comments |

## When Not To Use

- The user only wants raw `git diff` output.
- The user explicitly asks for a non-tuicr review workflow.
- The task is remote PR review and no tuicr PR session is involved.
