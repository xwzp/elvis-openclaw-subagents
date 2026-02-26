#!/usr/bin/env bash
set -euo pipefail

# Agent Swarm: Smart respawn with improved prompt (Ralph Loop V2)
# Reuses repo, branch, agent, and model from the original task.
# Increments retry counter and logs the respawn reason.
#
# Usage:
#   respawn-agent.sh --task <id> --prompt <new_prompt> --reason <text>
#
# Options:
#   --task       Task ID to respawn (required)
#   --prompt     New/improved prompt (required unless --prompt-file)
#   --prompt-file Read new prompt from file
#   --reason     Reason for respawn (required)
#   --help       Show this help message

SWARM_DIR="${SWARM_DIR:-$HOME/.agent-swarm}"
TASKS_FILE="$SWARM_DIR/tasks.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TASK="" PROMPT="" REASON=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --task) TASK="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --prompt-file) PROMPT="$(cat "$2")"; shift 2 ;;
    --reason) REASON="$2"; shift 2 ;;
    --help|-h)
      sed -n '3,15p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$TASK" ]] && echo "ERROR: --task is required" >&2 && exit 1
[[ -z "$PROMPT" ]] && echo "ERROR: --prompt or --prompt-file is required" >&2 && exit 1
[[ -z "$REASON" ]] && echo "ERROR: --reason is required" >&2 && exit 1

# Load original task data
if [[ ! -f "$TASKS_FILE" ]]; then
  echo "ERROR: No tasks registered (tasks.json not found)" >&2
  exit 1
fi

TASK_DATA=$(jq --arg id "$TASK" '.[] | select(.id == $id)' "$TASKS_FILE")
if [[ -z "$TASK_DATA" ]]; then
  echo "ERROR: Task '$TASK' not found in registry" >&2
  exit 1
fi

# Extract original config
REPO=$(echo "$TASK_DATA" | jq -r '.repo')
BRANCH=$(echo "$TASK_DATA" | jq -r '.branch')
AGENT=$(echo "$TASK_DATA" | jq -r '.agent')
MODEL=$(echo "$TASK_DATA" | jq -r '.model')
RETRIES=$(echo "$TASK_DATA" | jq -r '.retries // 0')
MAX_RETRIES=$(echo "$TASK_DATA" | jq -r '.maxRetries // 3')

# Check retry limit
if [[ "$RETRIES" -ge "$MAX_RETRIES" ]]; then
  echo "ERROR: Task '$TASK' has reached max retries ($MAX_RETRIES)." >&2
  echo "Consider marking as abandoned or increasing maxRetries." >&2
  exit 1
fi

echo "Respawning task: $TASK (retry $((RETRIES + 1))/$MAX_RETRIES)"
echo "  Reason: $REASON"
echo "  Agent:  $AGENT ($MODEL)"
echo "  Branch: $BRANCH"

# Kill existing tmux session
TMUX_SESSION="agent-${TASK}"
tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

# Log respawn to learnings
mkdir -p "$SWARM_DIR/learnings"
LEARNING_ENTRY=$(jq -n \
  --arg task "$TASK" \
  --arg reason "$REASON" \
  --arg agent "$AGENT" \
  --arg model "$MODEL" \
  --argjson retry "$((RETRIES + 1))" \
  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{type:"respawn",task:$task,reason:$reason,agent:$agent,model:$model,retry:$retry,timestamp:$timestamp}')
echo "$LEARNING_ENTRY" >> "$SWARM_DIR/learnings/learnings.jsonl"

# Respawn via spawn-agent.sh (which handles retry counter increment)
bash "$SCRIPT_DIR/spawn-agent.sh" \
  --repo "$REPO" \
  --task "$TASK" \
  --branch "$BRANCH" \
  --agent "$AGENT" \
  --model "$MODEL" \
  --prompt "$PROMPT" \
  --description "RESPAWN ($((RETRIES + 1))/$MAX_RETRIES): $REASON"
