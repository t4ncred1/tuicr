#!/usr/bin/env bash
# Opens tuicr in a new tab of a Herdr workspace, or focuses that workspace's
# existing tuicr tab for the same repository. Returns as soon as tuicr is
# running, so the review stays open beside a working agent (unlike
# tuicr-wrapper-herdr.sh, which waits for tuicr to exit).
#
# Usage: tuicr-herdr-tab.sh [directory] [-- tuicr-args...]
#
# An agent passes its current working directory. That matters after it moves
# to another worktree: its process keeps the launch directory as cwd, so
# anything reading the pane's cwd would open the review in the wrong checkout.
#
# Also works as a Herdr custom keybinding target, where it reviews the active
# pane's directory:
#
#   [[keys.command]]
#   key = "prefix+t"
#   type = "shell"
#   command = "/path/to/tuicr-herdr-tab.sh"
#   description = "tuicr review tab"
#
# Without tuicr args it reviews with `--branch`: the branch's commits since it
# forked plus uncommitted changes, in a session that follows new commits.
#
# Environment variables:
#   TUICR_TAB_LABEL  tab label prefix; the repository name is appended, and
#                    the full label finds an existing review tab (default: tuicr)
#   JQ_BIN           jq executable (default: jq)
set -e -u -o pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_tuicr-common.sh"

HERDR_BIN="${HERDR_BIN_PATH:-herdr}"
JQ_BIN="${JQ_BIN:-jq}"
TAB_LABEL="${TUICR_TAB_LABEL:-tuicr}"

tuicr_parse_args "$@"
if [[ $# -eq 0 && -n "${HERDR_ACTIVE_PANE_CWD:-}" ]]; then
  # Launched from a keybinding: review what the active pane is looking at.
  TUICR_TARGET_DIR="$HERDR_ACTIVE_PANE_CWD"
fi
[[ -d "$TUICR_TARGET_DIR" ]] || {
  echo "Directory not found: $TUICR_TARGET_DIR" >&2
  exit 1
}

# tuicr keys sessions on the repository root, and the directory is often a
# subdirectory of it.
repo_root=$(git -C "$TUICR_TARGET_DIR" rev-parse --show-toplevel 2>/dev/null) ||
  repo_root=$(cd "$TUICR_TARGET_DIR" && jj root 2>/dev/null) ||
  repo_root=$(cd "$TUICR_TARGET_DIR" && pwd)

# The git directory a checkout shares with all its worktrees, so an agent pane
# that started in one worktree matches a review of another.
common_git_dir() {
  git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null
}

# Which workspace to open the tab in. A keybinding names the active one. An
# agent's own HERDR_WORKSPACE_ID cannot be trusted: a Claude Code background
# session runs in a process pre-started from another pane, which hands it that
# pane's Herdr variables. So the tab goes beside the agent pane working in
# this repository; when several are, the one HERDR_PANE_ID names, then the
# focused workspace's. With no agent pane in the repository, the focused
# workspace, where the user just asked for the review.
focused_workspace=$("$HERDR_BIN" workspace list |
  "$JQ_BIN" -er '[.result.workspaces[] | select(.focused)][0].workspace_id')
workspace_id="${HERDR_ACTIVE_WORKSPACE_ID:-}"
target_git_dir=$(common_git_dir "$repo_root") || target_git_dir=""
if [[ -z "$workspace_id" && -n "$target_git_dir" ]]; then
  matches=()
  while IFS=$'\t' read -r pane ws cwd; do
    if [[ "$(common_git_dir "$cwd")" == "$target_git_dir" ]]; then
      matches+=("$pane $ws")
    fi
  done < <("$HERDR_BIN" pane list |
    "$JQ_BIN" -r '.result.panes[] | select(.agent != null)
      | [.pane_id, .workspace_id, .cwd] | @tsv')

  for match in "${matches[@]+"${matches[@]}"}"; do
    [[ "${match%% *}" == "${HERDR_PANE_ID:-}" ]] && workspace_id="${match#* }"
  done
  if [[ -z "$workspace_id" ]]; then
    for match in "${matches[@]+"${matches[@]}"}"; do
      [[ "${match#* }" == "$focused_workspace" ]] && workspace_id="$focused_workspace"
    done
  fi
  if [[ -z "$workspace_id" && ${#matches[@]} -gt 0 ]]; then
    workspace_id="${matches[0]#* }"
  fi
fi
workspace_id="${workspace_id:-$focused_workspace}"

# One tab per repository, so a review of another worktree gets its own tab
# instead of focusing the old one.
tab_label="$TAB_LABEL $(basename "$repo_root")"
existing_tab=$("$HERDR_BIN" tab list |
  "$JQ_BIN" -r --arg ws "$workspace_id" --arg label "$tab_label" \
    '[.result.tabs[] | select(.workspace_id == $ws and .label == $label)][0].tab_id // empty')
if [[ -n "$existing_tab" ]]; then
  "$HERDR_BIN" tab focus "$existing_tab" >/dev/null
  echo "Focused existing tab $existing_tab ($tab_label)"
  exit 0
fi

if ((${#TUICR_PASSTHROUGH_ARGS[@]} > 0)); then
  tuicr_args=("${TUICR_PASSTHROUGH_ARGS[@]}")
else
  tuicr_args=(--branch)
fi

pane_id=$("$HERDR_BIN" tab create --workspace "$workspace_id" --cwd "$repo_root" \
  --label "$tab_label" --focus |
  "$JQ_BIN" -er '.result.root_pane.pane_id')

# `exec` makes quitting tuicr close the tab; when tuicr fails instead (say,
# nothing to review yet), the tab waits for Enter so its error stays readable.
# The pane's interactive shell parses this line, and `exec bash -c '...'`
# reads the same in bash, zsh and fish.
"$HERDR_BIN" pane run "$pane_id" \
  "exec bash -c 'tuicr \"\$@\" || read -rp \"tuicr exited; press Enter to close\" _' tuicr$(tuicr_quote_args "${tuicr_args[@]}")" >/dev/null
echo "Opened tuicr in pane $pane_id ($tab_label): $repo_root"
