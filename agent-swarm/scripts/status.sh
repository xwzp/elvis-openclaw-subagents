#!/usr/bin/env bash
set -euo pipefail

# Agent Swarm: Check all agent states, update tasks.json, display dashboard
# For each active task: checks tmux session, PR, CI, reviews — writes back to tasks.json
# Exit 0 = all good, Exit 1 = needs attention
#
# Usage:
#   status.sh [--project <name>] [--json] [--filter <status>] [--stale-hours N]
#
# Options:
#   --project <name>  Scope to one project (default: all projects)
#   --json            Output machine-readable JSON
#   --filter <status> Show only tasks with this status
#   --stale-hours N   Flag agents running longer than N hours (default: 4)
#   --help            Show this help message

# Resolve runtime directory from script location
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_DIR="$SKILL_DIR/.runtime"

JSON_OUTPUT=false
FILTER_STATUS=""
STALE_HOURS=4
PROJECT=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --project) PROJECT="$2"; shift 2 ;;
    --json) JSON_OUTPUT=true; shift ;;
    --filter) FILTER_STATUS="$2"; shift 2 ;;
    --stale-hours) STALE_HOURS="$2"; shift 2 ;;
    --help|-h)
      sed -n '3,16p' "$0" | sed 's/^# \?//'
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
    echo "ERROR: Project '$PROJECT' not found" >&2
    exit 1
  fi
  PROJECT_DIRS+=("$PROJ_DIR")
else
  if [[ ! -d "$RUNTIME_DIR" ]]; then
    if [[ "$JSON_OUTPUT" == "true" ]]; then
      echo '{"projects":[],"needsAttention":false}'
    else
      echo "No projects found."
    fi
    exit 0
  fi
  for d in "$RUNTIME_DIR"/*/; do
    [[ -d "$d" ]] && PROJECT_DIRS+=("$d")
  done
fi

if [[ ${#PROJECT_DIRS[@]} -eq 0 ]]; then
  if [[ "$JSON_OUTPUT" == "true" ]]; then
    echo '{"projects":[],"needsAttention":false}'
  else
    echo "No projects found."
  fi
  exit 0
fi

NOW_S=$(date +%s)
NOW_MS=$(( NOW_S * 1000 ))
STALE_THRESHOLD_MS=$(( STALE_HOURS * 3600 * 1000 ))

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

GLOBAL_NEEDS_ATTENTION=false
GLOBAL_JSON_PROJECTS="[]"

for PROJ_DIR in "${PROJECT_DIRS[@]}"; do
  PROJ_NAME="$(basename "$PROJ_DIR")"
  SWARM_DIR="$PROJ_DIR"
  TASKS_FILE="$SWARM_DIR/tasks.json"
  LOCK_FILE="$SWARM_DIR/tasks.json.lock"

  if [[ ! -f "$TASKS_FILE" ]]; then
    continue
  fi

  COUNT=$(jq length "$TASKS_FILE")
  [[ "$COUNT" == "0" ]] && continue

  NEEDS_ATTENTION=false
  JSON_TASKS="[]"

  # Stats
  TOTAL=0 RUNNING=0 PR_OPEN=0 CI_PASS=0 CI_FAIL=0 REVIEW=0 READY=0 DONE=0 FAILED=0 ABANDONED=0

  # Print project header
  if [[ "$JSON_OUTPUT" == "false" ]]; then
    echo "=== $PROJ_NAME ==="
    echo ""
    printf "  %-26s %-14s %-8s %-8s %-8s %-10s %s\n" "TASK" "STATUS" "AGENT" "PR" "CI" "ELAPSED" "ATTENTION"
    printf "  %-26s %-14s %-8s %-8s %-8s %-10s %s\n" "----" "------" "-----" "--" "--" "-------" "---------"
  fi

  for i in $(seq 0 $((COUNT - 1))); do
    ID=$(jq -r ".[$i].id" "$TASKS_FILE")
    STATUS=$(jq -r ".[$i].status" "$TASKS_FILE")
    TMUX_SESSION=$(jq -r ".[$i].tmuxSession" "$TASKS_FILE")
    AGENT=$(jq -r ".[$i].agent // \"-\"" "$TASKS_FILE")
    BRANCH=$(jq -r ".[$i].branch" "$TASKS_FILE")
    WORKTREE=$(jq -r ".[$i].worktree" "$TASKS_FILE")
    REPO=$(jq -r ".[$i].repo" "$TASKS_FILE")
    RETRIES=$(jq -r ".[$i].retries // 0" "$TASKS_FILE")
    MAX_RETRIES=$(jq -r ".[$i].maxRetries // 3" "$TASKS_FILE")
    STARTED_AT=$(jq -r ".[$i].startedAt // 0" "$TASKS_FILE")
    COMPLETED_AT=$(jq -r ".[$i].completedAt // 0" "$TASKS_FILE")

    # --- Refresh external state for active tasks ---

    TMUX_ALIVE=false
    IS_STALE=false
    PR_NUMBER=""
    CI_STATUS="-"
    REVIEW_STATUS="none"
    TASK_STATUS="$STATUS"
    ATTENTION=""

    if [[ "$STATUS" == "done" || "$STATUS" == "merged" || "$STATUS" == "abandoned" ]]; then
      # Terminal states — no refresh needed
      TASK_STATUS="$STATUS"
    else
      # Check tmux session
      if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        TMUX_ALIVE=true
      fi

      # Check stale
      if [[ "$STARTED_AT" -gt 0 ]]; then
        ELAPSED_CHECK=$(( NOW_S * 1000 - STARTED_AT ))
        if [[ "$ELAPSED_CHECK" -gt "$STALE_THRESHOLD_MS" && "$TMUX_ALIVE" == "true" ]]; then
          IS_STALE=true
        fi
      fi

      # Check for PR
      GH_DIR="$WORKTREE"
      [[ ! -d "$GH_DIR" ]] && GH_DIR="$REPO"

      if command -v gh &>/dev/null && [[ -d "$GH_DIR" ]]; then
        PR_NUMBER=$(cd "$GH_DIR" && gh pr list --head "$BRANCH" --json number --jq '.[0].number // empty' 2>/dev/null || echo "")
      fi

      # Check CI status
      if [[ -n "$PR_NUMBER" && -d "$GH_DIR" ]]; then
        CI_RAW=$(cd "$GH_DIR" && gh pr checks "$PR_NUMBER" --json state 2>/dev/null || echo "[]")
        if echo "$CI_RAW" | jq -e 'length > 0' &>/dev/null; then
          FAILING=$(echo "$CI_RAW" | jq '[.[] | select(.state == "FAILURE")] | length')
          PENDING=$(echo "$CI_RAW" | jq '[.[] | select(.state == "PENDING" or .state == "IN_PROGRESS")] | length')
          if [[ "$FAILING" -gt 0 ]]; then CI_STATUS="failing"
          elif [[ "$PENDING" -gt 0 ]]; then CI_STATUS="pending"
          else CI_STATUS="passing"
          fi
        fi
      fi

      # Check review status
      if [[ -n "$PR_NUMBER" && -d "$GH_DIR" ]]; then
        REVIEW_DATA=$(cd "$GH_DIR" && gh pr view "$PR_NUMBER" --json reviews 2>/dev/null || echo '{"reviews":[]}')
        APPROVED=$(echo "$REVIEW_DATA" | jq '[.reviews[] | select(.state == "APPROVED")] | length')
        CHANGES_REQ=$(echo "$REVIEW_DATA" | jq '[.reviews[] | select(.state == "CHANGES_REQUESTED")] | length')
        if [[ "$CHANGES_REQ" -gt 0 ]]; then REVIEW_STATUS="changes_requested"
        elif [[ "$APPROVED" -ge 2 ]]; then REVIEW_STATUS="approved"
        elif [[ "$APPROVED" -gt 0 ]]; then REVIEW_STATUS="in_progress"
        fi
      fi

      # Determine new status
      if [[ "$TMUX_ALIVE" == "false" && -z "$PR_NUMBER" ]]; then
        if [[ "$RETRIES" -lt "$MAX_RETRIES" ]]; then
          ATTENTION="Agent died. Needs respawn (retry $((RETRIES+1))/$MAX_RETRIES)"
          TASK_STATUS="failed"
        else
          ATTENTION="Agent died. Max retries reached."
          TASK_STATUS="abandoned"
        fi
        NEEDS_ATTENTION=true
      elif [[ -n "$PR_NUMBER" ]]; then
        if [[ "$CI_STATUS" == "failing" ]]; then
          ATTENTION="CI failing on PR #$PR_NUMBER"
          TASK_STATUS="ci_failing"
          NEEDS_ATTENTION=true
        elif [[ "$REVIEW_STATUS" == "changes_requested" ]]; then
          ATTENTION="Changes requested on PR #$PR_NUMBER"
          TASK_STATUS="review_feedback"
          NEEDS_ATTENTION=true
        elif [[ "$CI_STATUS" == "passing" && "$REVIEW_STATUS" == "approved" ]]; then
          ATTENTION="PR #$PR_NUMBER ready to merge!"
          TASK_STATUS="ready_to_merge"
          NEEDS_ATTENTION=true
        elif [[ "$CI_STATUS" == "passing" ]]; then
          TASK_STATUS="ci_passed"
        else
          TASK_STATUS="pr_open"
        fi
      elif [[ "$TMUX_ALIVE" == "true" ]]; then
        TASK_STATUS="running"
      fi

      # Flag stale
      if [[ "$IS_STALE" == "true" && "$TASK_STATUS" == "running" ]]; then
        ATTENTION="Stale: running for over ${STALE_HOURS}h. ${ATTENTION}"
        NEEDS_ATTENTION=true
      fi

      # Write updated status back to tasks.json
      (
        flock -w 10 200 || { echo "ERROR: Could not acquire lock" >&2; continue; }

        TEMP_FILE=$(mktemp)
        if [[ -n "$PR_NUMBER" ]]; then
          jq --arg id "$ID" --arg status "$TASK_STATUS" --argjson pr "$PR_NUMBER" \
            '(.[] | select(.id == $id)) |= (.status = $status | .pr = $pr)' \
            "$TASKS_FILE" > "$TEMP_FILE" && mv "$TEMP_FILE" "$TASKS_FILE"
        else
          jq --arg id "$ID" --arg status "$TASK_STATUS" \
            '(.[] | select(.id == $id)).status = $status' \
            "$TASKS_FILE" > "$TEMP_FILE" && mv "$TEMP_FILE" "$TASKS_FILE"
        fi
      ) 200>"$LOCK_FILE"
    fi

    # --- Display ---

    # Apply filter
    if [[ -n "$FILTER_STATUS" && "$TASK_STATUS" != "$FILTER_STATUS" ]]; then
      continue
    fi

    # Elapsed time
    if [[ "$COMPLETED_AT" -gt 0 ]]; then
      ELAPSED_MS=$(( COMPLETED_AT - STARTED_AT ))
    elif [[ "$STARTED_AT" -gt 0 ]]; then
      ELAPSED_MS=$(( NOW_MS - STARTED_AT ))
    else
      ELAPSED_MS=0
    fi
    ELAPSED_STR=$(format_duration "$ELAPSED_MS")

    # PR display
    PR_DISPLAY="-"
    [[ -n "$PR_NUMBER" ]] && PR_DISPLAY="#$PR_NUMBER"

    # Count stats
    TOTAL=$((TOTAL + 1))
    case $TASK_STATUS in
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
        --arg s "$TASK_STATUS" \
        --arg agent "$AGENT" \
        --arg pr "${PR_NUMBER:-}" \
        --arg ci "$CI_STATUS" \
        --arg rv "$REVIEW_STATUS" \
        --argjson tmux "$( [[ "$TMUX_ALIVE" == "true" ]] && echo true || echo false )" \
        --argjson stale "$( [[ "$IS_STALE" == "true" ]] && echo true || echo false )" \
        --arg elapsed "$ELAPSED_STR" \
        --argjson elapsed_ms "$ELAPSED_MS" \
        --arg att "$ATTENTION" \
        '. + [{"id":$id,"status":$s,"agent":$agent,"pr":(if $pr == "" then null else ($pr | tonumber) end),"ci":$ci,"reviews":$rv,"tmuxAlive":$tmux,"stale":$stale,"elapsed":$elapsed,"elapsedMs":$elapsed_ms,"attention":$att}]')
    else
      printf "  %-26s %-14s %-8s %-8s %-8s %-10s %s\n" "$ID" "$TASK_STATUS" "$AGENT" "$PR_DISPLAY" "$CI_STATUS" "$ELAPSED_STR" "$ATTENTION"
    fi
  done

  if [[ "$NEEDS_ATTENTION" == "true" ]]; then
    GLOBAL_NEEDS_ATTENTION=true
  fi

  if [[ "$JSON_OUTPUT" == "true" ]]; then
    GLOBAL_JSON_PROJECTS=$(echo "$GLOBAL_JSON_PROJECTS" | jq \
      --arg name "$PROJ_NAME" \
      --argjson tasks "$JSON_TASKS" \
      --argjson total "$TOTAL" \
      --argjson running "$RUNNING" \
      --argjson done "$DONE" \
      --argjson failed "$FAILED" \
      --argjson attention "$( [[ "$NEEDS_ATTENTION" == "true" ]] && echo true || echo false )" \
      '. + [{"project":$name,"tasks":$tasks,"summary":{"total":$total,"running":$running,"done":$done,"failed":$failed},"needsAttention":$attention}]')
  else
    echo ""
    echo "  Total: $TOTAL | Running: $RUNNING | PR Open: $PR_OPEN | CI+: $CI_PASS | CI-: $CI_FAIL"
    echo "  Review: $REVIEW | Ready: $READY | Done: $DONE | Failed: $FAILED | Abandoned: $ABANDONED"
    echo ""
  fi
done

if [[ "$JSON_OUTPUT" == "true" ]]; then
  jq -n \
    --argjson projects "$GLOBAL_JSON_PROJECTS" \
    --argjson attention "$( [[ "$GLOBAL_NEEDS_ATTENTION" == "true" ]] && echo true || echo false )" \
    '{"projects":$projects,"needsAttention":$attention}'
fi

if [[ "$GLOBAL_NEEDS_ATTENTION" == "true" ]]; then
  exit 1
else
  exit 0
fi
