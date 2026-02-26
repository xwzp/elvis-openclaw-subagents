#!/usr/bin/env bash
set -euo pipefail

# Agent Swarm: Clean up completed/merged/abandoned worktrees and task entries
# Archives cleaned tasks and removes associated logs and prompts
#
# Usage:
#   cleanup.sh [--older-than N]
#
# Options:
#   --older-than N  Only clean tasks completed more than N hours ago (default: 0 = all eligible)
#   --help          Show this help message

SWARM_DIR="${SWARM_DIR:-$HOME/.agent-swarm}"
TASKS_FILE="$SWARM_DIR/tasks.json"
LOCK_FILE="$SWARM_DIR/tasks.json.lock"

OLDER_THAN_HOURS=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --older-than) OLDER_THAN_HOURS="$2"; shift 2 ;;
    --help|-h)
      sed -n '3,11p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -f "$TASKS_FILE" ]]; then
  echo "No tasks file found."
  exit 0
fi

COUNT=$(jq length "$TASKS_FILE")
CLEANED=0
NOW_S=$(date +%s)
NOW_MS=$(( NOW_S * 1000 ))
THRESHOLD_MS=$(( OLDER_THAN_HOURS * 3600 * 1000 ))

# Create archive directory
mkdir -p "$SWARM_DIR/archive"

TASKS_TO_REMOVE="[]"

for i in $(seq 0 $((COUNT - 1))); do
  ID=$(jq -r ".[$i].id" "$TASKS_FILE")
  STATUS=$(jq -r ".[$i].status" "$TASKS_FILE")
  WORKTREE=$(jq -r ".[$i].worktree" "$TASKS_FILE")
  TMUX_SESSION=$(jq -r ".[$i].tmuxSession" "$TASKS_FILE")
  STARTED_AT=$(jq -r ".[$i].startedAt // 0" "$TASKS_FILE")
  COMPLETED_AT=$(jq -r ".[$i].completedAt // 0" "$TASKS_FILE")

  # Only clean up done/merged/abandoned tasks
  if [[ "$STATUS" != "done" && "$STATUS" != "merged" && "$STATUS" != "abandoned" ]]; then
    continue
  fi

  # Check age filter
  if [[ "$OLDER_THAN_HOURS" -gt 0 ]]; then
    REF_TIME="$COMPLETED_AT"
    [[ "$REF_TIME" == "0" || "$REF_TIME" == "null" ]] && REF_TIME="$STARTED_AT"
    ELAPSED_MS=$(( NOW_MS - REF_TIME ))
    if [[ "$ELAPSED_MS" -lt "$THRESHOLD_MS" ]]; then
      continue
    fi
  fi

  # Archive the task entry
  ARCHIVE_FILE="$SWARM_DIR/archive/${ID}.json"
  jq --arg id "$ID" '.[] | select(.id == $id)' "$TASKS_FILE" > "$ARCHIVE_FILE"
  echo "Archived: $ID -> $ARCHIVE_FILE"

  # Kill tmux session if still alive
  tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

  # Remove worktree
  if [[ -d "$WORKTREE" ]]; then
    echo "Removing worktree: $WORKTREE"
    MAIN_REPO=$(git -C "$WORKTREE" rev-parse --git-common-dir 2>/dev/null | sed 's|/\.git$||' || true)
    if [[ -n "$MAIN_REPO" && -d "$MAIN_REPO" ]]; then
      git -C "$MAIN_REPO" worktree remove "$WORKTREE" --force 2>/dev/null || rm -rf "$WORKTREE"
    else
      rm -rf "$WORKTREE"
    fi
  fi

  # Clean up logs
  rm -f "$SWARM_DIR/logs/${ID}.log"
  rm -f "$SWARM_DIR/logs/${ID}-redirects.log"

  # Clean up prompt
  rm -f "$SWARM_DIR/prompts/${ID}.md"

  TASKS_TO_REMOVE=$(echo "$TASKS_TO_REMOVE" | jq --arg id "$ID" '. + [$id]')
  CLEANED=$((CLEANED + 1))
  echo "Cleaned: $ID"
done

# Remove cleaned entries from registry (with file locking)
if [[ "$CLEANED" -gt 0 ]]; then
  (
    flock -w 10 200 || { echo "ERROR: Could not acquire lock" >&2; exit 1; }

    TEMP_FILE=$(mktemp)
    jq --argjson ids "$TASKS_TO_REMOVE" \
      '[.[] | select(.id as $id | $ids | index($id) | not)]' \
      "$TASKS_FILE" > "$TEMP_FILE" && mv "$TEMP_FILE" "$TASKS_FILE"

  ) 200>"$LOCK_FILE"

  echo "Cleaned $CLEANED task(s)"
else
  echo "Nothing to clean."
fi
