#!/usr/bin/env bash
set -euo pipefail

# Agent Swarm: Check status of all running agents
# Reads tasks.json, checks tmux sessions, PRs, CI status
# Exit 0 = all good, Exit 1 = needs attention
#
# Usage:
#   check-agents.sh [--project <name>] [--json] [--stale-hours N]
#
# Options:
#   --project <name> Check only this project (default: all projects)
#   --json           Output machine-readable JSON
#   --stale-hours N  Flag agents running longer than N hours (default: 4)
#   --help           Show this help message

# Resolve runtime directory from script location
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_DIR="$SKILL_DIR/.runtime"

JSON_OUTPUT=false
STALE_HOURS=4
PROJECT=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --project) PROJECT="$2"; shift 2 ;;
    --json) JSON_OUTPUT=true; shift ;;
    --stale-hours) STALE_HOURS="$2"; shift 2 ;;
    --help|-h)
      sed -n '3,15p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Collect project directories to check
PROJECT_DIRS=()
if [[ -n "$PROJECT" ]]; then
  PROJ_DIR="$RUNTIME_DIR/$PROJECT"
  if [[ ! -d "$PROJ_DIR" ]]; then
    echo "ERROR: Project '$PROJECT' not found in $RUNTIME_DIR" >&2
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

GLOBAL_NEEDS_ATTENTION=false
GLOBAL_REPORT=""
GLOBAL_JSON_PROJECTS="[]"
NOW_S=$(date +%s)
STALE_THRESHOLD_MS=$(( STALE_HOURS * 3600 * 1000 ))

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
  REPORT=""
  JSON_TASKS="[]"

  for i in $(seq 0 $((COUNT - 1))); do
    ID=$(jq -r ".[$i].id" "$TASKS_FILE")
    STATUS=$(jq -r ".[$i].status" "$TASKS_FILE")
    TMUX_SESSION=$(jq -r ".[$i].tmuxSession" "$TASKS_FILE")
    BRANCH=$(jq -r ".[$i].branch" "$TASKS_FILE")
    WORKTREE=$(jq -r ".[$i].worktree" "$TASKS_FILE")
    REPO=$(jq -r ".[$i].repo" "$TASKS_FILE")
    RETRIES=$(jq -r ".[$i].retries // 0" "$TASKS_FILE")
    MAX_RETRIES=$(jq -r ".[$i].maxRetries // 3" "$TASKS_FILE")
    STARTED_AT=$(jq -r ".[$i].startedAt // 0" "$TASKS_FILE")

    # Skip completed/merged tasks
    if [[ "$STATUS" == "done" || "$STATUS" == "merged" ]]; then
      REPORT+="  [$ID] done\n"
      JSON_TASKS=$(echo "$JSON_TASKS" | jq --arg id "$ID" --arg s "$STATUS" '. + [{"id":$id,"status":$s}]')
      continue
    fi

    # Check tmux session
    TMUX_ALIVE=false
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
      TMUX_ALIVE=true
    fi

    # Check for stale agent
    IS_STALE=false
    if [[ "$STARTED_AT" -gt 0 ]]; then
      ELAPSED_MS=$(( NOW_S * 1000 - STARTED_AT ))
      if [[ "$ELAPSED_MS" -gt "$STALE_THRESHOLD_MS" && "$TMUX_ALIVE" == "true" ]]; then
        IS_STALE=true
      fi
    fi

    # Check for PR
    PR_NUMBER=""
    GH_DIR="$WORKTREE"
    [[ ! -d "$GH_DIR" ]] && GH_DIR="$REPO"

    if command -v gh &>/dev/null && [[ -d "$GH_DIR" ]]; then
      PR_NUMBER=$(cd "$GH_DIR" && gh pr list --head "$BRANCH" --json number --jq '.[0].number // empty' 2>/dev/null || echo "")
    fi

    # Check CI status
    CI_STATUS="unknown"
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
    REVIEW_STATUS="none"
    if [[ -n "$PR_NUMBER" && -d "$GH_DIR" ]]; then
      REVIEW_DATA=$(cd "$GH_DIR" && gh pr view "$PR_NUMBER" --json reviews 2>/dev/null || echo '{"reviews":[]}')
      APPROVED=$(echo "$REVIEW_DATA" | jq '[.reviews[] | select(.state == "APPROVED")] | length')
      CHANGES_REQ=$(echo "$REVIEW_DATA" | jq '[.reviews[] | select(.state == "CHANGES_REQUESTED")] | length')
      if [[ "$CHANGES_REQ" -gt 0 ]]; then REVIEW_STATUS="changes_requested"
      elif [[ "$APPROVED" -ge 2 ]]; then REVIEW_STATUS="approved"
      elif [[ "$APPROVED" -gt 0 ]]; then REVIEW_STATUS="in_progress"
      fi
    fi

    # Determine task status
    TASK_STATUS="$STATUS"
    ATTENTION=""

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

    # Flag stale agents
    if [[ "$IS_STALE" == "true" && "$TASK_STATUS" == "running" ]]; then
      ATTENTION="Stale: running for over ${STALE_HOURS}h. ${ATTENTION}"
      NEEDS_ATTENTION=true
    fi

    # Update task status in registry (with file locking)
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

    # Build report
    case $TASK_STATUS in
      running)          ICON="[RUN]" ;;
      pr_open)          ICON="[PR]" ;;
      ci_passed)        ICON="[CI+]" ;;
      ci_failing)       ICON="[CI-]" ;;
      review_feedback)  ICON="[REV]" ;;
      ready_to_merge)   ICON="[OK!]" ;;
      failed)           ICON="[FAIL]" ;;
      abandoned)        ICON="[DEAD]" ;;
      *)                ICON="[???]" ;;
    esac

    REPORT+="  [$ID] $ICON $TASK_STATUS"
    [[ -n "$PR_NUMBER" ]] && REPORT+=" (PR #$PR_NUMBER)"
    [[ -n "$ATTENTION" ]] && REPORT+=" -- $ATTENTION"
    REPORT+="\n"

    # Build JSON output
    JSON_TASKS=$(echo "$JSON_TASKS" | jq \
      --arg id "$ID" \
      --arg s "$TASK_STATUS" \
      --arg pr "${PR_NUMBER:-null}" \
      --arg ci "$CI_STATUS" \
      --arg rv "$REVIEW_STATUS" \
      --argjson tmux "$( [[ "$TMUX_ALIVE" == "true" ]] && echo true || echo false )" \
      --argjson stale "$( [[ "$IS_STALE" == "true" ]] && echo true || echo false )" \
      --arg att "$ATTENTION" \
      '. + [{"id":$id,"status":$s,"pr":(if $pr == "null" then null else ($pr | tonumber) end),"ci":$ci,"reviews":$rv,"tmuxAlive":$tmux,"stale":$stale,"attention":$att}]')
  done

  if [[ "$NEEDS_ATTENTION" == "true" ]]; then
    GLOBAL_NEEDS_ATTENTION=true
  fi

  GLOBAL_REPORT+="[$PROJ_NAME]\n$REPORT"
  GLOBAL_JSON_PROJECTS=$(echo "$GLOBAL_JSON_PROJECTS" | jq \
    --arg name "$PROJ_NAME" \
    --argjson tasks "$JSON_TASKS" \
    --argjson attention "$( [[ "$NEEDS_ATTENTION" == "true" ]] && echo true || echo false )" \
    '. + [{"project":$name,"tasks":$tasks,"needsAttention":$attention}]')
done

if [[ "$JSON_OUTPUT" == "true" ]]; then
  jq -n \
    --argjson projects "$GLOBAL_JSON_PROJECTS" \
    --argjson attention "$( [[ "$GLOBAL_NEEDS_ATTENTION" == "true" ]] && echo true || echo false )" \
    '{"projects":$projects,"needsAttention":$attention}'
else
  if [[ -z "$GLOBAL_REPORT" ]]; then
    echo "No active tasks."
  else
    echo -e "$GLOBAL_REPORT"
  fi
fi

if [[ "$GLOBAL_NEEDS_ATTENTION" == "true" ]]; then
  exit 1
else
  exit 0
fi
