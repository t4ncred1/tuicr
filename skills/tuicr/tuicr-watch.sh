#!/usr/bin/env bash
# Watches the repo's active tuicr session and prints one line per open review
# thread, so an agent can run it as a background monitor and be woken by each
# new piece of feedback even while it sits idle.
#
# A thread is a comment plus its replies. It is open while its last entry (the
# comment itself, or its newest reply) is not the agent's. The agent closes a
# thread by answering it with `tuicr review add --reply-to <id>`; the user
# reopens it by replying again. Each opening is reported once: the reported
# key is the thread id plus its last entry's id and content, so a new user
# reply or an edited comment is reported again, and nothing else is.
#
# Usage: tuicr-watch.sh [--reset] [--once] [--session <slug>] [directory]
#   --reset    forget what was already reported, so every open thread is
#              printed again (use when a fresh agent session starts watching)
#   --once     exit after the first poll that reports a thread, printing every
#              thread open at that moment. An agent runs it as a background
#              command, which wakes it only on exit and never times out, so
#              watching costs nothing while the user is quiet; it starts the
#              watcher again after answering. Nothing is missed in between:
#              unreported threads are printed on the next start.
#   --session  watch exactly this session, e.g. a PR review's
#              `gh:owner/repo/pr/N`; without it the watcher follows the
#              repository's most recently written active local session
#   directory  repository to watch (default: current directory)
#
# Output lines (stdout is the event stream; keep it to these):
#   tuicr: watching session <slug>
#   tuicr: open thread <id> <location> - @<author>: <text>
#   tuicr: open thread <id> <location> - @<author>: <text> (re @<reviewer>: <their comment>)
#   tuicr: error: <message>
#
# The `(re …)` form marks a comment answering a forge review thread and
# quotes the comment that opened it.
#
# Environment variables:
#   TUICR_BIN              tuicr executable (default: tuicr)
#   JQ_BIN                 jq executable (default: jq)
#   TUICR_WATCH_AGENT      author name the agent replies with (default: Claude)
#   TUICR_WATCH_INTERVAL   seconds between polls (default: 2)
#   TUICR_WATCH_TYPES      comma-separated comment type ids to report, such as
#                          `claude`; threads of other types (`none` for
#                          untyped) stay private. Unset reports every type.
#   TUICR_WATCH_STATE_DIR  where reported keys are recorded
#                          (default: ${XDG_STATE_HOME:-~/.local/state}/tuicr/watch)
set -u -o pipefail

TUICR_BIN="${TUICR_BIN:-tuicr}"
JQ_BIN="${JQ_BIN:-jq}"
AGENT_NAME="${TUICR_WATCH_AGENT:-Claude}"
INTERVAL="${TUICR_WATCH_INTERVAL:-2}"
WATCH_TYPES="${TUICR_WATCH_TYPES:-}"
STATE_DIR="${TUICR_WATCH_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/tuicr/watch}"

reset=false
once=false
session=""
while (($# > 0)); do
  case "$1" in
    --reset) reset=true ;;
    --once) once=true ;;
    --session)
      session="${2:-}"
      shift
      ;;
    *) break ;;
  esac
  shift
done
target_dir="${1:-$PWD}"

fail() {
  printf 'tuicr: error: %s\n' "$*"
  exit 1
}

command -v "$TUICR_BIN" &>/dev/null || fail "$TUICR_BIN not found on PATH"
command -v "$JQ_BIN" &>/dev/null || fail "$JQ_BIN not found on PATH"
[[ -d "$target_dir" ]] || fail "directory not found: $target_dir"
[[ -z "$session" || "$session" != --* ]] || fail "--session needs a session slug"

# `tuicr review list --repo` only matches the repository root.
repo_root=$(git -C "$target_dir" rev-parse --show-toplevel 2>/dev/null) ||
  repo_root=$(cd "$target_dir" && jj root 2>/dev/null) ||
  repo_root=$(cd "$target_dir" && hg root 2>/dev/null) ||
  repo_root=$(cd "$target_dir" && pwd)

mkdir -p "$STATE_DIR" || fail "cannot create $STATE_DIR"
state_file="$STATE_DIR/$(printf '%s\n%s\n%s' "$repo_root" "$AGENT_NAME" "$session" | sha1sum | cut -d' ' -f1)"
$reset && : >"$state_file"
touch "$state_file" || fail "cannot write $state_file"

# One object per open thread: the key that identifies this opening, and the
# line to print. `location` matches what `tuicr review comments` reports.
open_threads_filter='
  .[]
  | select($types == "" or (.comment_type as $type | $types | split(",") | index($type)))
  | (if (.replies // []) | length > 0 then .replies[-1] else . end) as $last
  | select($last.author != $agent)
  | {
      key: (.id + ":" + ($last.id // .id) + ":" + $last.content),
      line: ("tuicr: open thread \(.id) \(.location) - @\($last.author): "
        + ($last.content | gsub("[\r\n]+"; " ") | .[0:300])
        + (.reply_to_thread.comments[0] // null
          | if . == null then ""
            else " (re @\(.author): \(.body | gsub("[\r\n]+"; " ") | .[0:200]))"
            end))
    }'

current_slug=""
while true; do
  if [[ -n "$session" ]]; then
    slug="$session"
  else
    # The most recently written active session is where the user is typing.
    slug=$("$TUICR_BIN" review list --repo "$repo_root" 2>/dev/null |
      "$JQ_BIN" -r '[.[] | select(.active and .kind == "local")]
        | sort_by(.updated_at) | last | .slug // empty') || slug=""
  fi

  if [[ -n "$slug" ]]; then
    if [[ "$slug" != "$current_slug" ]]; then
      current_slug="$slug"
      printf 'tuicr: watching session %s\n' "$slug"
    fi

    reported=0
    if comments=$("$TUICR_BIN" review comments --repo "$repo_root" --session "$slug" 2>/dev/null); then
      while IFS= read -r thread; do
        [[ -n "$thread" ]] || continue
        key=$(printf '%s' "$thread" | "$JQ_BIN" -r '.key' | sha1sum | cut -d' ' -f1)
        grep -qxF "$key" "$state_file" && continue
        printf '%s\n' "$(printf '%s' "$thread" | "$JQ_BIN" -r '.line')"
        # Recorded after printing: a crash in between re-reports, never drops.
        printf '%s\n' "$key" >>"$state_file"
        reported=$((reported + 1))
      done < <(printf '%s' "$comments" |
        "$JQ_BIN" -c --arg agent "$AGENT_NAME" --arg types "$WATCH_TYPES" \
          "$open_threads_filter" 2>/dev/null)
    fi
    if $once && ((reported > 0)); then
      exit 0
    fi
  fi

  sleep "$INTERVAL"
done
