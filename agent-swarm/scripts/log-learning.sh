#!/usr/bin/env bash
set -euo pipefail

# Agent Swarm: Record prompt patterns and outcomes for continuous improvement
#
# Usage:
#   log-learning.sh --task <id> --outcome <success|failure> --notes <text> [--project <name>]
#
# Options:
#   --task     Task ID (required)
#   --outcome  success or failure (required)
#   --notes    What was learned (required)
#   --project  Project name (auto-detected from task if omitted)
#   --help     Show this help message

# Resolve runtime directory from script location
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_DIR="$SKILL_DIR/.runtime"

TASK="" OUTCOME="" NOTES="" PROJECT=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --task) TASK="$2"; shift 2 ;;
    --outcome) OUTCOME="$2"; shift 2 ;;
    --notes) NOTES="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --help|-h)
      sed -n '3,14p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$TASK" ]] && echo "ERROR: --task is required" >&2 && exit 1
[[ -z "$OUTCOME" ]] && echo "ERROR: --outcome is required (success or failure)" >&2 && exit 1
[[ -z "$NOTES" ]] && echo "ERROR: --notes is required" >&2 && exit 1

if [[ "$OUTCOME" != "success" && "$OUTCOME" != "failure" ]]; then
  echo "ERROR: --outcome must be 'success' or 'failure'" >&2
  exit 1
fi

# Resolve project from task ID if not specified
if [[ -z "$PROJECT" ]]; then
  for proj_dir in "$RUNTIME_DIR"/*/; do
    [[ ! -d "$proj_dir" ]] && continue
    tf="$proj_dir/tasks.json"
    if [[ -f "$tf" ]] && jq -e --arg id "$TASK" '.[] | select(.id == $id)' "$tf" &>/dev/null; then
      PROJECT="$(basename "$proj_dir")"
      break
    fi
  done
fi

if [[ -z "$PROJECT" ]]; then
  echo "ERROR: Task '$TASK' not found in any project. Use --project to specify." >&2
  exit 1
fi

SWARM_DIR="$RUNTIME_DIR/$PROJECT"
TASKS_FILE="$SWARM_DIR/tasks.json"

# Extract task metadata if available
AGENT="" MODEL="" DESCRIPTION="" RETRIES=0
if [[ -f "$TASKS_FILE" ]]; then
  TASK_DATA=$(jq --arg id "$TASK" '.[] | select(.id == $id)' "$TASKS_FILE" 2>/dev/null || echo "")
  if [[ -n "$TASK_DATA" ]]; then
    AGENT=$(echo "$TASK_DATA" | jq -r '.agent // ""')
    MODEL=$(echo "$TASK_DATA" | jq -r '.model // ""')
    DESCRIPTION=$(echo "$TASK_DATA" | jq -r '.description // ""')
    RETRIES=$(echo "$TASK_DATA" | jq -r '.retries // 0')
  fi
fi

# Write learning entry
mkdir -p "$SWARM_DIR/learnings"
LEARNINGS_FILE="$SWARM_DIR/learnings/learnings.jsonl"

ENTRY=$(jq -n \
  --arg task "$TASK" \
  --arg outcome "$OUTCOME" \
  --arg notes "$NOTES" \
  --arg agent "$AGENT" \
  --arg model "$MODEL" \
  --arg description "$DESCRIPTION" \
  --argjson retries "$RETRIES" \
  --arg project "$PROJECT" \
  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{type:"learning",task:$task,project:$project,outcome:$outcome,notes:$notes,agent:$agent,model:$model,description:$description,retries:$retries,timestamp:$timestamp}')

echo "$ENTRY" >> "$LEARNINGS_FILE"

echo "Learning recorded for task '$TASK' in project '$PROJECT' ($OUTCOME)"
echo "  Notes: $NOTES"
echo "  Saved to: $LEARNINGS_FILE"
