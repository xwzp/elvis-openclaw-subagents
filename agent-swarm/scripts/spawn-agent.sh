#!/usr/bin/env bash
set -euo pipefail

# Agent Swarm: Spawn a coding agent in an isolated git worktree + tmux session
#
# Usage:
#   spawn-agent.sh --repo <path> --task <id> --branch <name> --prompt <text> [options]
#
# Options:
#   --repo          Path to the main git repository (required)
#   --task          Unique task identifier (required)
#   --branch        Git branch name (required)
#   --agent         Agent type: codex or claude (default: codex)
#   --model         Model to use (auto-detected from agent type if omitted)
#   --effort        Reasoning effort: high, medium, low (default: high)
#   --prompt        Task prompt (required unless --prompt-file)
#   --prompt-file   Read prompt from file
#   --description   Short description of the task (defaults to first 200 chars of prompt)
#   --project       Project name (defaults to basename of --repo)
#   --pkg-mgr       Package manager: pnpm, npm, yarn, bun (auto-detected)
#   --no-notify     Don't notify on completion
#   --worktree-base Base directory for worktrees (default: repo parent dir)
#   --help          Show this help message

# Resolve runtime directory from script location
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_DIR="$SKILL_DIR/.runtime"

show_help() {
  sed -n '3,22p' "$0" | sed 's/^# \?//'
  exit 0
}

# Parse arguments
REPO="" TASK="" BRANCH="" AGENT="claude" MODEL="" EFFORT="high"
PROMPT="" DESCRIPTION="" PROJECT="" NOTIFY=true PKG_MGR="" WORKTREE_BASE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --repo) REPO="$2"; shift 2 ;;
    --task) TASK="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --agent) AGENT="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --effort) EFFORT="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --prompt-file) PROMPT="$(cat "$2")"; shift 2 ;;
    --description) DESCRIPTION="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --no-notify) NOTIFY=false; shift ;;
    --pkg-mgr) PKG_MGR="$2"; shift 2 ;;
    --worktree-base) WORKTREE_BASE="$2"; shift 2 ;;
    --help|-h) show_help ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Validate required params
[[ -z "$REPO" ]] && echo "ERROR: --repo is required" >&2 && exit 1
[[ -z "$TASK" ]] && echo "ERROR: --task is required" >&2 && exit 1
[[ -z "$BRANCH" ]] && echo "ERROR: --branch is required" >&2 && exit 1
[[ -z "$PROMPT" ]] && echo "ERROR: --prompt or --prompt-file is required" >&2 && exit 1

# Resolve paths
REPO="$(cd "$REPO" && pwd)"
REPO_NAME="$(basename "$REPO")"
WORKTREE_BASE="${WORKTREE_BASE:-$(dirname "$REPO")}"
WORKTREE_PATH="$WORKTREE_BASE/${TASK}"
TMUX_SESSION="agent-${TASK}"

# Resolve project name (default to repo basename)
PROJECT="${PROJECT:-$REPO_NAME}"
SWARM_DIR="$RUNTIME_DIR/$PROJECT"

# Default description to first 200 chars of prompt
if [[ -z "$DESCRIPTION" ]]; then
  DESCRIPTION="$(echo "$PROMPT" | head -c 200)"
fi

# Detect package manager
if [[ -z "$PKG_MGR" ]]; then
  if [[ -f "$REPO/pnpm-lock.yaml" ]]; then PKG_MGR="pnpm"
  elif [[ -f "$REPO/yarn.lock" ]]; then PKG_MGR="yarn"
  elif [[ -f "$REPO/bun.lockb" ]]; then PKG_MGR="bun"
  elif [[ -f "$REPO/package.json" ]]; then PKG_MGR="npm"
  else PKG_MGR=""
  fi
fi

# Set default model
if [[ -z "$MODEL" ]]; then
  case $AGENT in
    codex) MODEL="gpt-5.2-codex" ;;
    claude) MODEL="claude-opus-4-6" ;;
    *) MODEL="gpt-5.2-codex" ;;
  esac
fi

# Create project directories
mkdir -p "$SWARM_DIR"/{logs,prompts,learnings,archive}

# Save full prompt
PROMPT_FILE="$SWARM_DIR/prompts/${TASK}.md"
echo "$PROMPT" > "$PROMPT_FILE"

# Create worktree
echo "Creating worktree: $WORKTREE_PATH (branch: $BRANCH)"
cd "$REPO"

if git worktree list | grep -q "$WORKTREE_PATH"; then
  echo "Worktree already exists, reusing"
else
  git fetch origin main 2>/dev/null || true
  git worktree add "$WORKTREE_PATH" -b "$BRANCH" origin/main 2>/dev/null || \
    git worktree add "$WORKTREE_PATH" "$BRANCH" 2>/dev/null || \
    git worktree add "$WORKTREE_PATH" -b "$BRANCH" HEAD
fi

# Install dependencies
cd "$WORKTREE_PATH"
if [[ -n "$PKG_MGR" ]]; then
  echo "Installing dependencies with $PKG_MGR..."
  $PKG_MGR install 2>/dev/null || echo "WARN: Dependency install failed, continuing anyway"
fi

# Build agent command with post-completion hook
LOG_FILE="$SWARM_DIR/logs/${TASK}.log"
POST_HOOK='git add -A && git commit -m "agent: complete task" --allow-empty 2>/dev/null; git push -u origin HEAD 2>/dev/null && gh pr create --fill 2>/dev/null || true'

case $AGENT in
  codex)
    AGENT_CMD="codex --model $MODEL -c \"model_reasoning_effort=$EFFORT\" --dangerously-bypass-approvals-and-sandbox \"$PROMPT\" 2>&1 | tee \"$LOG_FILE\"; $POST_HOOK"
    ;;
  claude)
    AGENT_CMD="claude --model $MODEL --dangerously-skip-permissions -p \"$PROMPT\" 2>&1 | tee \"$LOG_FILE\"; $POST_HOOK"
    ;;
  *)
    echo "ERROR: Unknown agent type: $AGENT (use codex or claude)" >&2
    exit 1
    ;;
esac

# Kill existing tmux session if any
tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

# Spawn tmux session
echo "Spawning $AGENT agent in tmux session: $TMUX_SESSION"
tmux new-session -d -s "$TMUX_SESSION" -c "$WORKTREE_PATH" "bash -c '$AGENT_CMD; echo \"=== AGENT FINISHED ===\"; sleep 86400'"

# Register task (with file locking)
TASKS_FILE="$SWARM_DIR/tasks.json"
LOCK_FILE="$SWARM_DIR/tasks.json.lock"

(
  flock -w 10 200 || { echo "ERROR: Could not acquire lock on tasks.json" >&2; exit 1; }

  if [[ ! -f "$TASKS_FILE" ]]; then
    echo "[]" > "$TASKS_FILE"
  fi

  # Remove existing entry for this task (if respawning)
  TEMP_FILE=$(mktemp)
  OLD_RETRIES=$(jq --arg id "$TASK" '[.[] | select(.id == $id) | .retries][0] // 0' "$TASKS_FILE")
  jq --arg id "$TASK" '[.[] | select(.id != $id)]' "$TASKS_FILE" > "$TEMP_FILE" && mv "$TEMP_FILE" "$TASKS_FILE"

  # Add new entry
  NOW_MS=$(($(date +%s) * 1000))
  TEMP_FILE=$(mktemp)
  jq --arg id "$TASK" \
     --arg tmux "$TMUX_SESSION" \
     --arg agent "$AGENT" \
     --arg model "$MODEL" \
     --arg desc "$DESCRIPTION" \
     --arg repo "$REPO" \
     --arg wt "$WORKTREE_PATH" \
     --arg branch "$BRANCH" \
     --argjson started "$NOW_MS" \
     --argjson notify "$NOTIFY" \
     --argjson retries "$OLD_RETRIES" \
     '. + [{
       id: $id,
       tmuxSession: $tmux,
       agent: $agent,
       model: $model,
       description: $desc,
       repo: $repo,
       worktree: $wt,
       branch: $branch,
       startedAt: $started,
       status: "running",
       retries: $retries,
       maxRetries: 3,
       notifyOnComplete: $notify,
       pr: null
     }]' "$TASKS_FILE" > "$TEMP_FILE" && mv "$TEMP_FILE" "$TASKS_FILE"

) 200>"$LOCK_FILE"

echo ""
echo "Agent spawned successfully"
echo "   Project:      $PROJECT"
echo "   Task ID:      $TASK"
echo "   Description:  $DESCRIPTION"
echo "   Agent:        $AGENT ($MODEL)"
echo "   tmux:         $TMUX_SESSION"
echo "   Worktree:     $WORKTREE_PATH"
echo "   Branch:       $BRANCH"
echo "   Log:          $LOG_FILE"
echo "   Prompt saved: $PROMPT_FILE"
