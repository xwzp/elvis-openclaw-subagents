#!/usr/bin/env bash
set -euo pipefail

# Agent Swarm: Dashboard view of all tasks
# Read-only — does not modify any state
#
# Usage:
#   status.sh [--json] [--filter <status>]
#
# Options:
#   --json            Output machine-readable JSON
#   --filter <status> Show only tasks with this status
#   --help            Show this help message

SWARM_DIR="${SWARM_DIR:-$HOME/.agent-swarm}"
TASKS_FILE="$SWARM_DIR/tasks.json"

JSON_OUTPUT=false
FILTER_STATUS=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --json) JSON_OUTPUT=true; shift ;;
    --filter) FILTER_STATUS="$2"; shift 2 ;;
    --help|-h)
      sed -n '3,12p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -f "$TASKS_FILE" ]]; then
  if [[ "$JSON_OUTPUT" == "true" ]]; then
    echo '{"tasks":[],"summary":{"total":0}}'
  else
    echo "No tasks registered."
  fi
  exit 0
fi

COUNT=$(jq length "$TASKS_FILE")
if [[ "$COUNT" == "0" ]]; then
  if [[ "$JSON_OUTPUT" == "true" ]]; then
    echo '{"tasks":[],"summary":{"total":0}}'
  else
    echo "No tasks."
  fi
  exit 0
fi

NOW_S=$(date +%s)
NOW_MS=$(( NOW_S * 1000 ))

# Collect stats
TOTAL=0 RUNNING=0 PR_OPEN=0 CI_PASS=0 CI_FAIL=0 REVIEW=0 READY=0 DONE=0 FAILED=0 ABANDONED=0

format_duration() {
  local ms=$1
  local secs=$(( ms / 1000 ))
  local mins=$(( secs / 60 ))
  local hours=$(( mins / 60 ))
  mins=$(( mins % 60 ))

  if [[ "$hours" -gt 0 ]]; then
    echo "${hours}h ${mins}m"
  elif [[ "$mins" -gt 0 ]]; then
    echo "${mins}m"
  else
    echo "${secs}s"
  fi
}

# Header
if [[ "$JSON_OUTPUT" == "false" ]]; then
  echo "=== Agent Swarm Dashboard ==="
  echo ""
  printf "%-28s %-14s %-8s %-10s %-10s %s\n" "TASK" "STATUS" "AGENT" "PR" "ELAPSED" "DESCRIPTION"
  printf "%-28s %-14s %-8s %-10s %-10s %s\n" "----" "------" "-----" "--" "-------" "-----------"
fi

JSON_TASKS="[]"

for i in $(seq 0 $((COUNT - 1))); do
  ID=$(jq -r ".[$i].id" "$TASKS_FILE")
  STATUS=$(jq -r ".[$i].status" "$TASKS_FILE")
  AGENT=$(jq -r ".[$i].agent // \"-\"" "$TASKS_FILE")
  PR=$(jq -r ".[$i].pr // \"-\"" "$TASKS_FILE")
  DESC=$(jq -r ".[$i].description // \"-\"" "$TASKS_FILE")
  STARTED_AT=$(jq -r ".[$i].startedAt // 0" "$TASKS_FILE")
  COMPLETED_AT=$(jq -r ".[$i].completedAt // 0" "$TASKS_FILE")

  # Apply filter
  if [[ -n "$FILTER_STATUS" && "$STATUS" != "$FILTER_STATUS" ]]; then
    continue
  fi

  # Calculate elapsed time
  if [[ "$COMPLETED_AT" -gt 0 ]]; then
    ELAPSED_MS=$(( COMPLETED_AT - STARTED_AT ))
  elif [[ "$STARTED_AT" -gt 0 ]]; then
    ELAPSED_MS=$(( NOW_MS - STARTED_AT ))
  else
    ELAPSED_MS=0
  fi
  ELAPSED_STR=$(format_duration "$ELAPSED_MS")

  # Check tmux
  TMUX_SESSION="agent-${ID}"
  TMUX_ALIVE=false
  if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    TMUX_ALIVE=true
  fi

  # Truncate description for display
  DESC_SHORT="$(echo "$DESC" | head -c 40)"

  # PR display
  PR_DISPLAY="$PR"
  [[ "$PR" == "null" || "$PR" == "-" ]] && PR_DISPLAY="-"
  [[ "$PR_DISPLAY" != "-" ]] && PR_DISPLAY="#$PR_DISPLAY"

  # Count stats
  TOTAL=$((TOTAL + 1))
  case $STATUS in
    running)         RUNNING=$((RUNNING + 1)) ;;
    pr_open)         PR_OPEN=$((PR_OPEN + 1)) ;;
    ci_passed)       CI_PASS=$((CI_PASS + 1)) ;;
    ci_failing)      CI_FAIL=$((CI_FAIL + 1)) ;;
    review_feedback) REVIEW=$((REVIEW + 1)) ;;
    ready_to_merge)  READY=$((READY + 1)) ;;
    done|merged)     DONE=$((DONE + 1)) ;;
    failed)          FAILED=$((FAILED + 1)) ;;
    abandoned)       ABANDONED=$((ABANDONED + 1)) ;;
  esac

  if [[ "$JSON_OUTPUT" == "true" ]]; then
    JSON_TASKS=$(echo "$JSON_TASKS" | jq \
      --arg id "$ID" \
      --arg s "$STATUS" \
      --arg agent "$AGENT" \
      --arg pr "$PR_DISPLAY" \
      --arg elapsed "$ELAPSED_STR" \
      --argjson elapsed_ms "$ELAPSED_MS" \
      --argjson tmux "$( [[ "$TMUX_ALIVE" == "true" ]] && echo true || echo false )" \
      --arg desc "$DESC" \
      '. + [{"id":$id,"status":$s,"agent":$agent,"pr":$pr,"elapsed":$elapsed,"elapsedMs":$elapsed_ms,"tmuxAlive":$tmux,"description":$desc}]')
  else
    printf "%-28s %-14s %-8s %-10s %-10s %s\n" "$ID" "$STATUS" "$AGENT" "$PR_DISPLAY" "$ELAPSED_STR" "$DESC_SHORT"
  fi
done

# Summary
if [[ "$JSON_OUTPUT" == "true" ]]; then
  jq -n \
    --argjson tasks "$JSON_TASKS" \
    --argjson total "$TOTAL" \
    --argjson running "$RUNNING" \
    --argjson pr_open "$PR_OPEN" \
    --argjson ci_passed "$CI_PASS" \
    --argjson ci_failing "$CI_FAIL" \
    --argjson review_feedback "$REVIEW" \
    --argjson ready "$READY" \
    --argjson done "$DONE" \
    --argjson failed "$FAILED" \
    --argjson abandoned "$ABANDONED" \
    '{tasks:$tasks,summary:{total:$total,running:$running,pr_open:$pr_open,ci_passed:$ci_passed,ci_failing:$ci_failing,review_feedback:$review_feedback,ready_to_merge:$ready,done:$done,failed:$failed,abandoned:$abandoned}}'
else
  echo ""
  echo "--- Summary ---"
  echo "Total: $TOTAL | Running: $RUNNING | PR Open: $PR_OPEN | CI+: $CI_PASS | CI-: $CI_FAIL"
  echo "Review: $REVIEW | Ready to Merge: $READY | Done: $DONE | Failed: $FAILED | Abandoned: $ABANDONED"
fi
