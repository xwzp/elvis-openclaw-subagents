#!/usr/bin/env bash
set -euo pipefail

# Agent Swarm: Send mid-task instructions to a running agent via tmux
#
# Usage:
#   redirect-agent.sh --task <id> --message <text>
#
# Options:
#   --task     Task ID to redirect (required)
#   --message  Instructions to send (required)
#   --help     Show this help message

SWARM_DIR="${SWARM_DIR:-$HOME/.agent-swarm}"
TASKS_FILE="$SWARM_DIR/tasks.json"

TASK="" MESSAGE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --task) TASK="$2"; shift 2 ;;
    --message) MESSAGE="$2"; shift 2 ;;
    --help|-h)
      sed -n '3,11p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$TASK" ]] && echo "ERROR: --task is required" >&2 && exit 1
[[ -z "$MESSAGE" ]] && echo "ERROR: --message is required" >&2 && exit 1

# Verify task exists
if [[ ! -f "$TASKS_FILE" ]]; then
  echo "ERROR: No tasks registered (tasks.json not found)" >&2
  exit 1
fi

TASK_EXISTS=$(jq --arg id "$TASK" '[.[] | select(.id == $id)] | length' "$TASKS_FILE")
if [[ "$TASK_EXISTS" == "0" ]]; then
  echo "ERROR: Task '$TASK' not found in registry" >&2
  exit 1
fi

# Check tmux session
TMUX_SESSION="agent-${TASK}"
if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
  echo "ERROR: tmux session '$TMUX_SESSION' is not running" >&2
  echo "The agent may have already finished or crashed." >&2
  exit 1
fi

# Send message via tmux
tmux send-keys -t "$TMUX_SESSION" "$MESSAGE" Enter

# Log the redirect
mkdir -p "$SWARM_DIR/logs"
REDIRECT_LOG="$SWARM_DIR/logs/${TASK}-redirects.log"
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $MESSAGE" >> "$REDIRECT_LOG"

echo "Message sent to agent '$TASK' (session: $TMUX_SESSION)"
echo "Logged to: $REDIRECT_LOG"
