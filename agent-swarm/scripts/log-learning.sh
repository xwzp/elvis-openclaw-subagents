#!/usr/bin/env bash
set -euo pipefail

# Agent Swarm: Record prompt patterns and outcomes for continuous improvement
#
# Usage:
#   log-learning.sh --task <id> --outcome <success|failure> --notes <text>
#
# Options:
#   --task     Task ID (required)
#   --outcome  success or failure (required)
#   --notes    What was learned (required)
#   --help     Show this help message

SWARM_DIR="${SWARM_DIR:-$HOME/.agent-swarm}"
TASKS_FILE="$SWARM_DIR/tasks.json"

TASK="" OUTCOME="" NOTES=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --task) TASK="$2"; shift 2 ;;
    --outcome) OUTCOME="$2"; shift 2 ;;
    --notes) NOTES="$2"; shift 2 ;;
    --help|-h)
      sed -n '3,12p' "$0" | sed 's/^# \?//'
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
  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{type:"learning",task:$task,outcome:$outcome,notes:$notes,agent:$agent,model:$model,description:$description,retries:$retries,timestamp:$timestamp}')

echo "$ENTRY" >> "$LEARNINGS_FILE"

echo "Learning recorded for task '$TASK' ($OUTCOME)"
echo "  Notes: $NOTES"
echo "  Saved to: $LEARNINGS_FILE"
