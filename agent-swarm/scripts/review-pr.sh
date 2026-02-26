#!/usr/bin/env bash
set -euo pipefail

# Agent Swarm: Trigger AI code review on a PR
# Gets PR diff, generates review with Claude, posts via gh pr review
#
# Usage:
#   review-pr.sh --task <id>
#   review-pr.sh --pr <number> --repo <path>
#
# Options:
#   --task    Task ID (looks up PR number from registry)
#   --pr      PR number (used with --repo)
#   --repo    Path to repository (used with --pr)
#   --model   Model to use for review (default: claude-sonnet-4-5)
#   --help    Show this help message

SWARM_DIR="${SWARM_DIR:-$HOME/.agent-swarm}"
TASKS_FILE="$SWARM_DIR/tasks.json"

TASK="" PR_NUMBER="" REPO="" MODEL="claude-sonnet-4-5"

while [[ $# -gt 0 ]]; do
  case $1 in
    --task) TASK="$2"; shift 2 ;;
    --pr) PR_NUMBER="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --help|-h)
      sed -n '3,14p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Resolve task to PR number and repo
if [[ -n "$TASK" ]]; then
  if [[ ! -f "$TASKS_FILE" ]]; then
    echo "ERROR: No tasks registered" >&2
    exit 1
  fi

  TASK_DATA=$(jq --arg id "$TASK" '.[] | select(.id == $id)' "$TASKS_FILE")
  if [[ -z "$TASK_DATA" ]]; then
    echo "ERROR: Task '$TASK' not found" >&2
    exit 1
  fi

  PR_NUMBER=$(echo "$TASK_DATA" | jq -r '.pr // empty')
  REPO=$(echo "$TASK_DATA" | jq -r '.repo')
  WORKTREE=$(echo "$TASK_DATA" | jq -r '.worktree')
  BRANCH=$(echo "$TASK_DATA" | jq -r '.branch')

  # If no PR number in registry, try to find it
  if [[ -z "$PR_NUMBER" ]]; then
    GH_DIR="$WORKTREE"
    [[ ! -d "$GH_DIR" ]] && GH_DIR="$REPO"
    PR_NUMBER=$(cd "$GH_DIR" && gh pr list --head "$BRANCH" --json number --jq '.[0].number // empty' 2>/dev/null || echo "")
  fi

  if [[ -z "$PR_NUMBER" ]]; then
    echo "ERROR: No PR found for task '$TASK'" >&2
    exit 1
  fi

  # Use worktree if available, else repo
  [[ -d "$WORKTREE" ]] && REPO="$WORKTREE"
elif [[ -n "$PR_NUMBER" && -n "$REPO" ]]; then
  : # Both provided directly
else
  echo "ERROR: Use --task <id> or --pr <number> --repo <path>" >&2
  exit 1
fi

# Resolve repo path
REPO="$(cd "$REPO" && pwd)"

echo "Reviewing PR #$PR_NUMBER in $REPO with $MODEL..."

# Get PR diff
DIFF=$(cd "$REPO" && gh pr diff "$PR_NUMBER" 2>/dev/null)
if [[ -z "$DIFF" ]]; then
  echo "ERROR: Could not get diff for PR #$PR_NUMBER" >&2
  exit 1
fi

# Get PR description for context
PR_INFO=$(cd "$REPO" && gh pr view "$PR_NUMBER" --json title,body --jq '"\(.title)\n\n\(.body)"' 2>/dev/null || echo "")

# Generate review with Claude
REVIEW_PROMPT="You are a thorough code reviewer. Review this pull request diff.

## PR Info
$PR_INFO

## Diff
\`\`\`diff
$DIFF
\`\`\`

## Review Guidelines
Focus on:
1. Logic errors, edge cases, off-by-one errors
2. Security issues (injection, auth bypass, data leaks)
3. Performance concerns (N+1 queries, memory leaks, unnecessary allocations)
4. Error handling gaps
5. Missing tests for critical paths

Be specific. Reference file names and line numbers. Only flag real issues — avoid stylistic nitpicks.

Output your review as a concise, actionable list. Start with a one-line summary verdict: APPROVE, REQUEST_CHANGES, or COMMENT."

REVIEW=$(echo "$REVIEW_PROMPT" | claude --model "$MODEL" --dangerously-skip-permissions -p - 2>/dev/null)

if [[ -z "$REVIEW" ]]; then
  echo "ERROR: Failed to generate review" >&2
  exit 1
fi

# Determine review action from the first line
REVIEW_ACTION="--comment"
FIRST_LINE=$(echo "$REVIEW" | head -1 | tr '[:lower:]' '[:upper:]')
if echo "$FIRST_LINE" | grep -q "APPROVE"; then
  REVIEW_ACTION="--approve"
elif echo "$FIRST_LINE" | grep -q "REQUEST_CHANGES"; then
  REVIEW_ACTION="--request-changes"
fi

# Post review
cd "$REPO" && gh pr review "$PR_NUMBER" $REVIEW_ACTION --body "$REVIEW"

echo ""
echo "Review posted on PR #$PR_NUMBER ($REVIEW_ACTION)"
