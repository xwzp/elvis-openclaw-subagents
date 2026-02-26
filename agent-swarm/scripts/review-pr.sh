#!/usr/bin/env bash
set -euo pipefail

# Agent Swarm: Trigger AI code review on a PR
# Dispatches a single reviewer (codex, claude, or gemini) to review a PR diff
# OpenClaw calls this script once per reviewer it wants to dispatch
#
# Usage:
#   review-pr.sh --task <id> --reviewer <codex|claude|gemini> [options]
#   review-pr.sh --pr <number> --repo <path> --reviewer <codex|claude|gemini> [options]
#
# Options:
#   --task       Task ID (looks up PR number from registry)
#   --pr         PR number (used with --repo)
#   --repo       Path to repository (used with --repo)
#   --project    Project name (auto-detected from task if omitted)
#   --reviewer   Reviewer to use: codex, claude, gemini (required)
#   --model      Model override (defaults: codex→gpt-5.2-codex, claude→claude-sonnet-4-6, gemini→gemini-2.5-pro)
#   --focus      Review focus area: general, security, performance, logic (default: general)
#   --prompt     Custom review prompt (overrides built-in prompt)
#   --prompt-file Read custom review prompt from file
#   --no-post    Print review to stdout instead of posting to GitHub
#   --help       Show this help message

# Resolve runtime directory from script location
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_DIR="$SKILL_DIR/.runtime"

TASK="" PR_NUMBER="" REPO="" PROJECT="" REVIEWER="" MODEL=""
FOCUS="general" CUSTOM_PROMPT="" NO_POST=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --task) TASK="$2"; shift 2 ;;
    --pr) PR_NUMBER="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --reviewer) REVIEWER="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --focus) FOCUS="$2"; shift 2 ;;
    --prompt) CUSTOM_PROMPT="$2"; shift 2 ;;
    --prompt-file) CUSTOM_PROMPT="$(cat "$2")"; shift 2 ;;
    --no-post) NO_POST=true; shift ;;
    --help|-h)
      sed -n '3,23p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Validate reviewer
[[ -z "$REVIEWER" ]] && echo "ERROR: --reviewer is required (codex, claude, or gemini)" >&2 && exit 1

case $REVIEWER in
  codex|claude|gemini) ;;
  *) echo "ERROR: --reviewer must be codex, claude, or gemini" >&2; exit 1 ;;
esac

# Set default model per reviewer
if [[ -z "$MODEL" ]]; then
  case $REVIEWER in
    codex)  MODEL="gpt-5.2-codex" ;;
    claude) MODEL="claude-sonnet-4-6" ;;
    gemini) MODEL="gemini-2.5-pro" ;;
  esac
fi

# --- Resolve PR number and repo path ---

if [[ -n "$TASK" ]]; then
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
    echo "ERROR: Task '$TASK' not found in any project" >&2
    exit 1
  fi

  TASKS_FILE="$RUNTIME_DIR/$PROJECT/tasks.json"
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

REPO="$(cd "$REPO" && pwd)"

# --- Get PR data ---

echo "Reviewing PR #$PR_NUMBER with $REVIEWER ($MODEL), focus: $FOCUS..."

DIFF=$(cd "$REPO" && gh pr diff "$PR_NUMBER" 2>/dev/null)
if [[ -z "$DIFF" ]]; then
  echo "ERROR: Could not get diff for PR #$PR_NUMBER" >&2
  exit 1
fi

PR_INFO=$(cd "$REPO" && gh pr view "$PR_NUMBER" --json title,body --jq '"\(.title)\n\n\(.body)"' 2>/dev/null || echo "")

# --- Build review prompt ---

if [[ -n "$CUSTOM_PROMPT" ]]; then
  REVIEW_PROMPT="$CUSTOM_PROMPT

## PR Info
$PR_INFO

## Diff
\`\`\`diff
$DIFF
\`\`\`"
else
  # Focus-specific guidelines
  case $FOCUS in
    security)
      FOCUS_GUIDELINES="Focus exclusively on security:
1. Injection vulnerabilities (SQL, command, XSS, SSTI)
2. Authentication and authorization bypass
3. Data leaks (PII exposure, secrets in code, verbose errors)
4. Insecure cryptography or random number generation
5. SSRF, path traversal, open redirects
6. Dependency vulnerabilities"
      ;;
    performance)
      FOCUS_GUIDELINES="Focus exclusively on performance:
1. N+1 queries and unnecessary database calls
2. Memory leaks and unbounded allocations
3. Missing pagination on list endpoints
4. Unnecessary synchronous I/O in hot paths
5. Missing caching opportunities
6. Algorithmic complexity issues (O(n^2) where O(n) is possible)"
      ;;
    logic)
      FOCUS_GUIDELINES="Focus exclusively on correctness:
1. Logic errors and off-by-one mistakes
2. Race conditions and concurrency issues
3. Unhandled edge cases (null, empty, boundary values)
4. Incorrect state transitions
5. Missing error handling for failure paths
6. Type mismatches and implicit conversions"
      ;;
    *)
      FOCUS_GUIDELINES="Focus on:
1. Logic errors, edge cases, off-by-one errors
2. Security issues (injection, auth bypass, data leaks)
3. Performance concerns (N+1 queries, memory leaks)
4. Error handling gaps
5. Missing tests for critical paths"
      ;;
  esac

  REVIEW_PROMPT="You are a thorough code reviewer. Review this pull request diff.

## PR Info
$PR_INFO

## Diff
\`\`\`diff
$DIFF
\`\`\`

## Review Guidelines
$FOCUS_GUIDELINES

Be specific. Reference file names and line numbers. Only flag real issues — avoid stylistic nitpicks.

Output your review as a concise, actionable list. Start with a one-line summary verdict: APPROVE, REQUEST_CHANGES, or COMMENT."
fi

# --- Execute review ---

case $REVIEWER in
  claude)
    REVIEW=$(echo "$REVIEW_PROMPT" | claude --model "$MODEL" --dangerously-skip-permissions -p - 2>/dev/null)
    ;;
  codex)
    REVIEW=$(codex --model "$MODEL" --dangerously-bypass-approvals-and-sandbox "$REVIEW_PROMPT" 2>/dev/null)
    ;;
  gemini)
    REVIEW=$(gemini -m "$MODEL" "$REVIEW_PROMPT" 2>/dev/null)
    ;;
esac

if [[ -z "$REVIEW" ]]; then
  echo "ERROR: $REVIEWER failed to generate review" >&2
  exit 1
fi

# --- Output ---

if [[ "$NO_POST" == "true" ]]; then
  echo "$REVIEW"
else
  # Determine review action from the first line
  REVIEW_ACTION="--comment"
  FIRST_LINE=$(echo "$REVIEW" | head -1 | tr '[:lower:]' '[:upper:]')
  if echo "$FIRST_LINE" | grep -q "APPROVE"; then
    REVIEW_ACTION="--approve"
  elif echo "$FIRST_LINE" | grep -q "REQUEST_CHANGES"; then
    REVIEW_ACTION="--request-changes"
  fi

  # Post review with reviewer tag
  TAGGED_REVIEW="**[$REVIEWER review ($MODEL) — focus: $FOCUS]**

$REVIEW"

  cd "$REPO" && gh pr review "$PR_NUMBER" $REVIEW_ACTION --body "$TAGGED_REVIEW"

  echo ""
  echo "Review posted on PR #$PR_NUMBER by $REVIEWER ($REVIEW_ACTION)"
fi
