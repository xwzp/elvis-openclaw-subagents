---
name: agent-swarm
description: Orchestrate a swarm of coding agents (Codex, Claude Code, Gemini) using git worktrees, tmux sessions, and automated monitoring. Use when delegating coding tasks to multiple parallel agents, managing feature branches with isolated worktrees, setting up automated PR review pipelines, monitoring agent progress and CI status. Triggers on "spawn agents", "agent swarm", "parallel development", "worktree agents", "coding fleet", "one-person dev team", "multi-agent coding".
metadata:
  {
    "openclaw": {
      "emoji": "🐝",
      "os": ["darwin", "linux"],
      "requires": {
        "bins": ["git", "tmux", "gh", "jq"],
        "env": []
      }
    }
  }
---

# Agent Swarm

Orchestrate multiple coding agents in parallel. Each agent gets an isolated git worktree + tmux session. A monitoring loop tracks progress through PR creation, CI checks, and multi-model code review.

## Prerequisites

- `git` with worktree support
- `tmux`
- `gh` CLI (authenticated)
- At least one of: `codex` CLI, `claude` CLI
- `jq`

## Runtime Data

All runtime data is stored under `{baseDir}/.runtime/`, organized by project name. Each project gets its own isolated directory:

```
{baseDir}/.runtime/
├── my-saas-app/               # Project name = repo basename (or --project override)
│   ├── tasks.json             # Task registry for this project
│   ├── tasks.json.lock        # File lock for concurrent access
│   ├── logs/                  # Agent output logs
│   ├── prompts/               # Saved task prompts
│   ├── learnings/             # Learning journal (JSONL)
│   └── archive/               # Archived completed tasks
└── another-project/
    ├── tasks.json
    └── ...
```

The project name defaults to the basename of `--repo`. You can override it with `--project <name>` on any script. Directories are created automatically on first use.

## Quick Reference

### Spawn an Agent

```bash
bash {baseDir}/scripts/spawn-agent.sh \
  --repo /path/to/repo \
  --task "feat-custom-templates" \
  --branch "feat/custom-templates" \
  --agent claude \
  --model "claude-opus-4-6" \
  --effort high \
  --prompt "Implement custom email templates..." \
  --description "Custom email templates for agency customer"
```

Options: `--agent codex|claude`, `--model <model>`, `--effort high|medium|low`, `--prompt-file <path>`, `--project <name>`, `--pkg-mgr pnpm|npm|yarn|bun`, `--no-notify`, `--description <text>`, `--worktree-base <dir>`

### Check All Agents

```bash
bash {baseDir}/scripts/check-agents.sh [--project <name>] [--json] [--stale-hours N]
```

Exit 0 = all good. Exit 1 = needs human attention. Updates tasks.json status automatically. Use `--json` for machine-readable output. Use `--stale-hours N` to flag agents running longer than N hours (default: 4).

### Dashboard

```bash
bash {baseDir}/scripts/status.sh [--project <name>] [--json] [--filter <status>]
```

Read-only view of all tasks with elapsed time, PR numbers, and CI status. Does not modify any state.

### Redirect an Agent

```bash
bash {baseDir}/scripts/redirect-agent.sh \
  --task "feat-custom-templates" \
  --message "Stop. Focus on the API layer first, not the UI."
```

Send mid-task instructions to a running agent via tmux without killing it.

### Respawn an Agent (Ralph Loop V2)

```bash
bash {baseDir}/scripts/respawn-agent.sh \
  --task "feat-custom-templates" \
  --prompt "IMPROVED PROMPT with more context..." \
  --reason "Agent ran out of context window"
```

Smart respawn: reuses repo, branch, agent, and model config from the original task. Increments retry counter. Logs reason to learnings.

### Review a PR

```bash
bash {baseDir}/scripts/review-pr.sh --task "feat-custom-templates"
bash {baseDir}/scripts/review-pr.sh --pr 341 --repo /path/to/repo
```

Generates an AI code review on a PR diff and posts it via `gh pr review`.

### Clean Up

```bash
bash {baseDir}/scripts/cleanup.sh [--project <name>] [--older-than N]
```

Removes worktrees and registry entries for done/merged/abandoned tasks. Archives cleaned tasks. Use `--older-than N` to only clean tasks completed more than N hours ago.

### Log a Learning

```bash
bash {baseDir}/scripts/log-learning.sh \
  --task "feat-custom-templates" \
  --outcome success \
  --notes "Including type definitions upfront improved Codex success rate"
```

Records prompt patterns and outcomes to the project's `learnings/learnings.jsonl`.

## Agent Selection

| Task Type | Agent | Why |
|-----------|-------|-----|
| Backend logic, complex bugs, multi-file refactors | Codex | Thorough reasoning across codebase |
| Frontend work, git operations, quick fixes | Claude Code | Faster, fewer permission issues |
| UI design specs | Gemini then Claude Code | Gemini designs, Claude builds |

Default: Codex for most tasks. Use Claude Code for speed-sensitive or frontend work. See `references/agent-selection.md` for detailed selection criteria.

## Task Lifecycle

1. **Scope** -- Gather context (customer data, meeting notes, existing config). Write precise prompt with all relevant file paths, schemas, requirements.
2. **Spawn** -- `spawn-agent.sh` creates worktree + tmux session + registers task.
3. **Monitor** -- `check-agents.sh` every 10 min (cron or heartbeat). No LLM calls -- pure shell checks.
4. **PR Created** -- Agent commits, pushes, opens PR via `gh pr create --fill`.
5. **Review** -- Multiple AI reviewers post comments on PR. Use `review-pr.sh` to trigger.
6. **CI** -- Lint, types, unit tests, E2E must all pass.
7. **Notify** -- Alert human ONLY when ALL checks pass.
8. **Merge** -- Human reviews (5-10 min), merges. Cleanup removes worktree.

### Definition of Done

A task is NOT done until ALL pass:
- PR created with no merge conflicts
- CI passing
- At least 2 AI code reviews passed
- Screenshots included (if UI changes)

## Mid-Task Redirection

Don't kill struggling agents. Redirect via `redirect-agent.sh` or directly via tmux:

```bash
# Wrong direction:
bash {baseDir}/scripts/redirect-agent.sh --task "feat-templates" --message "Stop. Focus on the API layer first, not the UI."

# Missing context:
bash {baseDir}/scripts/redirect-agent.sh --task "feat-templates" --message "The schema is in src/types/template.ts. Use that."
```

## Failure Handling (Ralph Loop V2)

When agents fail, don't just respawn with the same prompt. Analyze the failure and improve:

- **Agent died (no PR)** -- Respawn with improved prompt via `respawn-agent.sh` (max 3 retries)
- **CI failed** -- Read error logs, craft fix prompt, respawn or redirect
- **Review feedback** -- Send feedback to agent via `redirect-agent.sh`
- **Max retries reached** -- Mark abandoned, escalate to human
- **Learning** -- Log outcomes via `log-learning.sh` to improve future prompts

See `references/ralph-loop-v2.md` for the full self-improving respawn strategy.

## Proactive Work

Don't wait for explicit assignment. Look for work:
- Scan error tracking (Sentry) -- spawn fix agents
- Scan meeting notes -- identify feature requests -- spawn agents
- Scan git log -- update changelog and docs

## References

- **Task registry schema**: See `references/task-registry.md`
- **Complete 8-step workflow with examples**: See `references/workflow.md`
- **Prompt templates for various task types**: See `references/prompt-templates.md`
- **Agent selection guide**: See `references/agent-selection.md`
- **Self-improving respawn strategy**: See `references/ralph-loop-v2.md`
