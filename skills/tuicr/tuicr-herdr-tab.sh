#!/usr/bin/env bash
# Opens tuicr in a new tab of the active Herdr workspace, or focuses the
# workspace's existing tuicr tab. Meant for a Herdr custom keybinding:
#
#   [[keys.command]]
#   key = "prefix+t"
#   type = "shell"
#   command = "/path/to/tuicr-herdr-tab.sh"
#   description = "tuicr review tab"
#
# Unlike tuicr-wrapper-herdr.sh this does not wait for tuicr to exit, so the
# review stays open beside a working agent.
#
# Environment variables:
#   TUICR_ARGS  arguments for tuicr (default: -w)
#   TUICR_TAB_LABEL  tab label used to find an existing review tab (default: tuicr)
#   JQ_BIN      jq executable (default: jq)
set -e -u -o pipefail

HERDR_BIN="${HERDR_BIN_PATH:-herdr}"
JQ_BIN="${JQ_BIN:-jq}"
TUICR_ARGS="${TUICR_ARGS:--w}"
TAB_LABEL="${TUICR_TAB_LABEL:-tuicr}"

# Set by Herdr for custom commands; absent means we were not launched by a
# keybinding.
workspace_id="${HERDR_ACTIVE_WORKSPACE_ID:?not launched from a Herdr keybinding}"
pane_cwd="${HERDR_ACTIVE_PANE_CWD:-$PWD}"

existing_tab=$("$HERDR_BIN" tab list |
  "$JQ_BIN" -r --arg ws "$workspace_id" --arg label "$TAB_LABEL" \
    '[.result.tabs[] | select(.workspace_id == $ws and .label == $label)][0].tab_id // empty')
if [[ -n "$existing_tab" ]]; then
  "$HERDR_BIN" tab focus "$existing_tab" >/dev/null
  exit 0
fi

# tuicr keys sessions on the repository root, and an agent pane often sits
# in a subdirectory.
repo_root=$(git -C "$pane_cwd" rev-parse --show-toplevel 2>/dev/null) ||
  repo_root=$(cd "$pane_cwd" && jj root 2>/dev/null) ||
  repo_root="$pane_cwd"

pane_id=$("$HERDR_BIN" tab create --workspace "$workspace_id" --cwd "$repo_root" \
  --label "$TAB_LABEL" --focus |
  "$JQ_BIN" -er '.result.root_pane.pane_id')

# `exec` makes quitting tuicr close the tab. The pane's interactive shell
# parses this line, and `exec cmd args` reads the same in bash, zsh and fish.
"$HERDR_BIN" pane run "$pane_id" "exec tuicr $TUICR_ARGS" >/dev/null
