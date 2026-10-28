#!/usr/bin/env bash
# Quits the tuicr tabs tuicr-herdr-tab.sh opened for a repository: every tab
# whose label is `<prefix>… <repo>`, so both a `tuicr pr <repo>` and a
# `tuicr local <repo>` tab close in one call.
#
# Usage: tuicr-herdr-close.sh [directory]
#
# tuicr has no signal handling, so closing the tab would skip its exit
# cleanup. Instead each tuicr gets `:w` then `:q`, only from NORMAL mode (or
# just `:q` from the commit selector, which holds nothing to save):
# a tab showing any other mode (a comment being typed, a confirm dialog) is
# left open and reported, never forced. If the save fails, `:q` refuses to
# drop unsaved comments and the tab stays open too.
#
# Prints one line per tab:
#   closed <label>
#   left open <label>: <reason>
# Exits 2 when any tab was left open.
#
# Environment variables:
#   TUICR_TAB_LABEL  tab label prefix to match (default: tuicr)
#   JQ_BIN           jq executable (default: jq)
set -e -u -o pipefail

HERDR_BIN="${HERDR_BIN_PATH:-herdr}"
JQ_BIN="${JQ_BIN:-jq}"
TAB_LABEL="${TUICR_TAB_LABEL:-tuicr}"
target_dir="${1:-.}"

[[ -d "$target_dir" ]] || {
  echo "Directory not found: $target_dir" >&2
  exit 1
}
repo_root=$(git -C "$target_dir" rev-parse --show-toplevel 2>/dev/null) ||
  repo_root=$(cd "$target_dir" && jj root 2>/dev/null) ||
  repo_root=$(cd "$target_dir" && pwd)
repo_name=$(basename "$repo_root")

tab_gone() {
  ! "$HERDR_BIN" tab get "$1" &>/dev/null
}

# The status bar sits at the bottom of the screen.
screen_tail() {
  "$HERDR_BIN" pane read "$1" --source visible --lines 3
}

# Commands go in as key presses: `pane run` delivers its text as a paste,
# which tuicr ignores outside text inputs, so only its Enter would land.
left_open=false
while IFS=$'\t' read -r tab label; do
  pane=$("$HERDR_BIN" pane list |
    "$JQ_BIN" -r --arg tab "$tab" '[.result.panes[] | select(.tab_id == $tab)][0].pane_id // empty')
  screen=$(screen_tail "$pane")
  # Keys go only to tuicr itself: an $EDITOR it spawned joins the foreground,
  # and a vim statusline can read NORMAL too. The launcher's `bash -c` stays
  # in the foreground beside tuicr.
  foreground=$("$HERDR_BIN" pane process-info --pane "$pane" |
    "$JQ_BIN" -r '[.result.process_info.foreground_processes[].name]
      | if index("tuicr") and (. - ["bash", "tuicr"] | length == 0) then "tuicr"
        else join(",") end')

  if [[ "$screen" == *"press Enter to close"* ]]; then
    # tuicr already exited with an error; the tab only holds its message.
    "$HERDR_BIN" tab close "$tab" >/dev/null
  elif [[ "$foreground" != "tuicr" ]]; then
    echo "left open $label: $foreground is running in it"
    left_open=true
    continue
  elif [[ "$screen" == *" NORMAL "* ]]; then
    # Esc first drops a half-typed file-tree filter, which also reads NORMAL.
    "$HERDR_BIN" pane send-keys "$pane" esc : w enter : q enter >/dev/null
  elif [[ "$screen" == *" SELECT "* ]]; then
    # The commit selector has nothing to save yet.
    "$HERDR_BIN" pane send-keys "$pane" : q enter >/dev/null
  else
    echo "left open $label: tuicr is not in NORMAL mode"
    left_open=true
    continue
  fi

  for _ in {1..25}; do
    tab_gone "$tab" && break
    sleep 0.2
  done
  if tab_gone "$tab"; then
    echo "closed $label"
  else
    echo "left open $label: tuicr did not quit (unsaved comments?)"
    left_open=true
  fi
done < <("$HERDR_BIN" tab list |
  "$JQ_BIN" -r --arg prefix "$TAB_LABEL" --arg repo "$repo_name" \
    '.result.tabs[] | select((.label | startswith($prefix)) and (.label | endswith(" " + $repo)))
      | [.tab_id, .label] | @tsv')

if $left_open; then
  exit 2
fi
