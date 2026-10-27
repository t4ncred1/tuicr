#!/usr/bin/env bash
# Claude Code PostToolUse hook: feeds new tuicr review comments to the agent
# while it works, so a human reviewing in a live `tuicr -w` pane can steer it
# without waiting for the turn to end.
#
# Reads the hook payload on stdin, finds the active tuicr session for the
# repository the agent is working in, and emits every comment it has not
# already delivered to this Claude session as `additionalContext`. A comment
# whose content was edited since delivery is sent again as an update.
#
# Silent (exit 0, no output) when there is no active session or nothing new,
# so it is safe to register for every tool in every project.
#
# Environment variables:
#   TUICR_BIN              tuicr executable (default: tuicr)
#   JQ_BIN                 jq executable (default: jq)
#   TUICR_HOOK_AGENT_NAME  author name the agent uses for its own replies;
#                          comments by this author are never delivered
#                          (default: Claude)
#   TUICR_HOOK_STATE_DIR   where delivered comment keys are recorded
#                          (default: ${XDG_STATE_HOME:-~/.local/state}/tuicr/claude-hook)
set -u -o pipefail

TUICR_BIN="${TUICR_BIN:-tuicr}"
JQ_BIN="${JQ_BIN:-jq}"
AGENT_NAME="${TUICR_HOOK_AGENT_NAME:-Claude}"
STATE_DIR="${TUICR_HOOK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/tuicr/claude-hook}"

# A hook must never break the agent's tool loop: any failure below means
# "nothing to report", not an error.
command -v "$TUICR_BIN" &>/dev/null || exit 0
command -v "$JQ_BIN" &>/dev/null || exit 0

payload=$(cat)
cwd=$(printf '%s' "$payload" | "$JQ_BIN" -r '.cwd // empty') || exit 0
claude_session=$(printf '%s' "$payload" | "$JQ_BIN" -r '.session_id // empty') || exit 0
[[ -n "$cwd" && -d "$cwd" && -n "$claude_session" ]] || exit 0

# `tuicr review list --repo` only matches the repository root; a
# subdirectory silently returns `[]`.
repo_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) ||
  repo_root=$(cd "$cwd" && jj root 2>/dev/null) ||
  repo_root=$(cd "$cwd" && hg root 2>/dev/null) ||
  repo_root="$cwd"

# Several active sessions on one repo (e.g. a worktree and a commit range)
# are possible; the most recently written one is where the user is typing.
slug=$("$TUICR_BIN" review list --repo "$repo_root" 2>/dev/null |
  "$JQ_BIN" -r '[.[] | select(.active and .kind == "local")]
    | sort_by(.updated_at) | last | .slug // empty') || exit 0
[[ -n "$slug" ]] || exit 0

comments=$("$TUICR_BIN" review comments --repo "$repo_root" --session "$slug" 2>/dev/null) || exit 0

mkdir -p "$STATE_DIR" || exit 0
state_file="$STATE_DIR/$claude_session"
touch "$state_file" || exit 0

new_keys=()
new_comments=()
while IFS= read -r comment; do
  [[ -n "$comment" ]] || continue
  # Keying on content as well as id resurfaces edited comments.
  key=$(printf '%s' "$comment" | "$JQ_BIN" -r '.id + ":" + .content' | sha1sum | cut -d' ' -f1)
  grep -qxF "$key" "$state_file" && continue
  new_keys+=("$key")
  new_comments+=("$comment")
done < <(printf '%s' "$comments" |
  "$JQ_BIN" -c --arg agent "$AGENT_NAME" \
    '.[] | select(.author != $agent and .lifecycle_state == "local_draft")')

((${#new_comments[@]} > 0)) || exit 0

formatted=$(printf '%s\n' "${new_comments[@]}" | "$JQ_BIN" -rs '
  .[] | "- [\(.comment_type | ascii_upcase)] id=\(.id) "
    + (if .path == null then "(review-level)"
       elif .start_line == null then "`\(.path)`"
       elif .start_line == .end_line then "`\(.path):\(.start_line)` (\(.side) side)"
       else "`\(.path):\(.start_line)-\(.end_line)` (\(.side) side)" end)
    + " by \(.author): \(.content)"')

context="The user is reviewing your changes live in tuicr (session \`$slug\`) and left new comments:

$formatted

Address ISSUE comments before continuing your current plan; weigh SUGGESTION and NOTE comments. Line numbers refer to the diff as the user saw it and may have shifted with later edits. When you have handled a comment, reply on the same location with:
  $TUICR_BIN review add --repo $repo_root --session $slug --username $AGENT_NAME --type note [--target-file <path> --line <n> --side new] \"<what you did>\""

"$JQ_BIN" -n --arg context "$context" \
  '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $context}}' || exit 0

# Record delivery only after the output was produced, so a failure above
# leaves the comments queued for the next tool call.
printf '%s\n' "${new_keys[@]}" >>"$state_file"
