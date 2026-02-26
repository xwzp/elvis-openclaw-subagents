#!/usr/bin/env bash
set -euo pipefail

# Agent Swarm: Clean up completed/merged/abandoned worktrees and task entries
# Archives cleaned tasks and removes associated logs and prompts
#
# Usage:
#   cleanup.sh [--project <name>] [--older-than N]
#
# Options:
#   --project <name> Clean only this project (default: all projects)
#   --older-than N   Only clean tasks completed more than N hours ago (default: 0 = all eligible)
#   --help           Show this help message

# Resolve runtime directory from script location
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_DIR="$SKILL_DIR/.runtime"

OLDER_THAN_HOURS=0
PROJECT=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --project) PROJECT="$2"; shift 2 ;;
    --older-than) OLDER_THAN_HOURS="$2"; shift 2 ;;
    --help|-h)
      sed -n '3,13p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Collect project directories
PROJECT_DIRS=()
if [[ -n "$PROJECT" ]]; then
  PROJ_DIR="$RUNTIME_DIR/$PROJECT"
  if [[ ! -d "$PROJ_DIR" ]]; then
    echo "No data for project '$PROJECT'."
    exit 0
  fi
  PROJECT_DIRS+=("$PROJ_DIR")
else
  if [[ ! -d "$RUNTIME_DIR" ]]; then
    echo "No projects found."
    exit 0
  fi
  for d in "$RUNTIME_DIR"/*/; do
    [[ -d "$d" ]] && PROJECT_DIRS+=("$d")
  done
fi

if [[ ${#PROJECT_DIRS[@]} -eq 0 ]]; then
  echo "No projects found."
  exit 0
fi

NOW_S=$(date +%s)
NOW_MS=$(( NOW_S * 1000 ))
THRESHOLD_MS=$(( OLDER_THAN_HOURS * 3600 * 1000 ))
TOTAL_CLEANED=0

for PROJ_DIR in "${PROJECT_DIRS[@]}"; do
  PROJ_NAME="$(basename "$PROJ_DIR")"
  SWARM_DIR="$PROJ_DIR"
  TASKS_FILE="$SWARM_DIR/tasks.json"
  LOCK_FILE="$SWARM_DIR/tasks.json.lock"

  if [[ ! -f "$TASKS_FILE" ]]; then
    continue
  fi

  COUNT=$(jq length "$TASKS_FILE")
  CLEANED=0

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

    # Kill tmux session if still alive
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

    # Remove worktree
    if [[ -d "$WORKTREE" ]]; then
      echo "[$PROJ_NAME] Removing worktree: $WORKTREE"
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
    echo "[$PROJ_NAME] Cleaned: $ID"
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

    TOTAL_CLEANED=$((TOTAL_CLEANED + CLEANED))
  fi
done

if [[ "$TOTAL_CLEANED" -gt 0 ]]; then
  echo "Cleaned $TOTAL_CLEANED task(s) total"
else
  echo "Nothing to clean."
fi
