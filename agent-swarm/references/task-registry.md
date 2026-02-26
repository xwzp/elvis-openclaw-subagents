# Task Registry Schema

Tasks are tracked in `{baseDir}/.runtime/<project>/tasks.json`. Each project has its own isolated registry.

## Schema

### Running Task

```json
{
  "id": "feat-custom-templates",
  "tmuxSession": "agent-feat-custom-templates",
  "agent": "codex",
  "model": "gpt-5.2-codex",
  "description": "Implement custom email templates for agency customer",
  "repo": "/absolute/path/to/my-project",
  "worktree": "/path/to/feat-custom-templates",
  "branch": "feat/custom-templates",
  "startedAt": 1740268800000,
  "status": "running",
  "retries": 0,
  "maxRetries": 3,
  "notifyOnComplete": true,
  "pr": null
}
```

### Completed Task

After merge, task gets additional fields:

```json
{
  "id": "feat-custom-templates",
  "status": "done",
  "pr": 341,
  "completedAt": 1740275400000,
  "checks": {
    "prCreated": true,
    "ciPassed": true,
    "reviewsPassed": true
  }
}
```

## Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique task identifier, used in tmux session name |
| `tmuxSession` | string | tmux session name (`agent-<id>`) |
| `agent` | string | `codex` or `claude` |
| `model` | string | Model used (e.g. `gpt-5.2-codex`, `claude-opus-4-6`) |
| `description` | string | Short description of the task |
| `repo` | string | Absolute path to main repository |
| `worktree` | string | Absolute path to git worktree |
| `branch` | string | Git branch name |
| `startedAt` | number | Unix timestamp in milliseconds |
| `status` | string | Current task status (see below) |
| `retries` | number | Number of respawns so far |
| `maxRetries` | number | Max respawn attempts (default 3) |
| `notifyOnComplete` | boolean | Whether to notify human when ready |
| `pr` | number\|null | PR number once created |
| `completedAt` | number\|null | Completion timestamp in milliseconds |
| `checks` | object\|null | Check results after completion |

## Status Values

| Status | Meaning | Action |
|--------|---------|--------|
| `running` | Agent active in tmux | Wait |
| `pr_open` | PR created, awaiting CI/review | Wait |
| `ci_passed` | CI green, awaiting reviews | Wait |
| `ci_failing` | CI failed | Read errors, respawn or redirect |
| `review_feedback` | Changes requested in review | Send feedback to agent |
| `ready_to_merge` | All checks passed | **Notify human** |
| `done` | Merged | Cleanup eligible |
| `merged` | Merged (alias) | Cleanup eligible |
| `failed` | Agent died, can retry | Respawn with improved prompt |
| `abandoned` | Max retries reached | Escalate to human |

## File Locking

All scripts use `flock` on `<project_dir>/tasks.json.lock` for safe concurrent access. This prevents corruption when multiple scripts (spawn, check, cleanup) access the same project's registry simultaneously.
