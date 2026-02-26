# Agent Swarm: Complete 8-Step Workflow

## Step 1: Scope the Task

When a task comes in (feature request, bug report, customer need):

1. **Gather context** -- Check meeting notes, customer data, existing code, prod database
2. **Scope the work** -- Break into concrete, agent-sized tasks (one PR per task)
3. **Write the prompt** -- Include all relevant context:
   - What to build/fix (specific acceptance criteria)
   - Relevant file paths and entry points
   - Database schema or API specs if needed
   - Customer-specific requirements
   - Test expectations
   - Definition of done

**Key insight:** The orchestrator has business context the coding agents don't. The prompt quality determines success rate.

### Prompt Template

```
## Task
[Clear description of what to build/fix]

## Context
- [Customer/business context]
- [Relevant past decisions]

## Files to Focus On
- src/[relevant files]
- tests/[relevant test files]

## Requirements
1. [Specific requirement]
2. [Another requirement]

## Testing
- [ ] Unit tests for [what]
- [ ] E2E test for [flow]

## When Done
1. Commit all changes
2. Push to branch
3. Run: gh pr create --fill
```

See `references/prompt-templates.md` for task-type-specific templates.

## Step 2: Spawn the Agent

```bash
bash {baseDir}/scripts/spawn-agent.sh \
  --repo /path/to/repo \
  --task "feat-custom-templates" \
  --branch "feat/custom-templates" \
  --agent codex \
  --prompt "$(cat prompt.md)"
```

### Parallel Agents

Spawn independent tasks simultaneously:

```bash
bash {baseDir}/scripts/spawn-agent.sh --repo $REPO --task "fix-auth-bug" --branch "fix/auth-timeout" --agent codex --prompt "..."
bash {baseDir}/scripts/spawn-agent.sh --repo $REPO --task "fix-billing" --branch "fix/billing-calc" --agent codex --prompt "..."
bash {baseDir}/scripts/spawn-agent.sh --repo $REPO --task "ui-polish" --branch "feat/ui-polish" --agent claude --prompt "..."
```

### Resource Limits

- 16GB RAM: max 4-5 parallel agents
- 64GB+ RAM: 8-10 parallel agents
- Each agent needs its own `node_modules` + build tooling in memory

## Step 3: Monitoring

Run `check-agents.sh` every 10 minutes via cron or heartbeat.

```bash
# Cron setup (every 10 minutes)
*/10 * * * * bash {baseDir}/scripts/check-agents.sh

# Or use the dashboard for a quick look
bash {baseDir}/scripts/status.sh
```

The check script is 100% deterministic -- no LLM calls. It checks:
- Is the tmux session still alive?
- Has a PR been opened on the tracked branch?
- What's the CI status? (via `gh pr checks`)
- Any review comments needing attention?

Use `--stale-hours N` to flag agents running too long:
```bash
bash {baseDir}/scripts/check-agents.sh --stale-hours 2
```

### Failure Recovery

**Agent died without PR:**
```bash
bash {baseDir}/scripts/respawn-agent.sh \
  --task "same-task-id" \
  --prompt "IMPROVED PROMPT with more context" \
  --reason "Agent ran out of context window"
```

**Agent going wrong direction:**
```bash
bash {baseDir}/scripts/redirect-agent.sh \
  --task "feat-templates" \
  --message "Stop. Focus on the API layer first, not the UI."
```

**Agent needs more context:**
```bash
bash {baseDir}/scripts/redirect-agent.sh \
  --task "feat-templates" \
  --message "Check src/types/template.ts for the schema. The customer's existing config format is JSON with these fields: name, subject, body, variables."
```

**Agent ran out of context window:**
```bash
bash {baseDir}/scripts/redirect-agent.sh \
  --task "feat-templates" \
  --message "Focus only on these three files: src/api/templates.ts, src/services/template-service.ts, tests/templates.test.ts. Ignore everything else."
```

## Step 4: Agent Creates PR

The agent commits, pushes, and opens a PR via `gh pr create --fill`. The spawn script includes a post-completion hook that handles this automatically.

**Important:** A PR alone is NOT done. Do NOT notify the human at this point.

## Step 5: Automated Code Review

Trigger reviews from multiple AI models. Each catches different things:

- **Codex Reviewer** -- Edge cases, logic errors, race conditions. Low false positive rate. Most thorough.
- **Gemini Code Assist** -- Free. Catches security issues, scalability problems. Suggests specific fixes.
- **Claude Code Reviewer** -- Overly cautious. Skip unless marked critical. Validates other reviewers' findings.

### Setting Up Reviewers

- **Gemini Code Assist**: Install via GitHub Marketplace (free)
- **CodeRabbit**: Install via GitHub Marketplace
- **Manual review via script**:
  ```bash
  bash {baseDir}/scripts/review-pr.sh --task "feat-templates"
  ```

## Step 6: CI Pipeline

Automated tests must all pass:
- Lint and TypeScript checks
- Unit tests
- E2E tests
- Playwright tests against preview environment

**UI rule:** If PR changes any UI, require a screenshot in PR description. Otherwise CI should fail. This shortens review time dramatically.

## Step 7: Human Review

NOW notify the human: "PR #341 ready for review."

By this point:
- CI passed
- AI reviewers approved
- Screenshots show UI changes
- Edge cases documented in review comments

Human review takes 5-10 minutes. Many PRs can merge based on screenshots alone.

## Step 8: Merge + Cleanup

After merge:
1. PR merges to main
2. Log the learning: `bash {baseDir}/scripts/log-learning.sh --task "feat-templates" --outcome success --notes "..."`
3. Run cleanup: `bash {baseDir}/scripts/cleanup.sh`
4. Or set up daily cron: `0 2 * * * bash {baseDir}/scripts/cleanup.sh --older-than 24`

## The Self-Improving Loop (Ralph Loop V2)

When agents succeed, log the pattern:
- "This prompt structure works for billing features"
- "Codex needs type definitions upfront"
- "Always include test file paths in the prompt"

When agents fail, analyze why and respawn with improved prompts:
- Failed due to missing context? Include more context
- Wrong approach? Be more specific about the expected solution
- Ran out of context? Scope tasks smaller

```bash
# On success
bash {baseDir}/scripts/log-learning.sh --task "$ID" --outcome success --notes "Prompt structure with file paths upfront works well for API features"

# On failure + respawn
bash {baseDir}/scripts/respawn-agent.sh --task "$ID" --prompt "IMPROVED PROMPT" --reason "Missing type definitions caused wrong implementation"
```

Over time, prompt quality improves and success rate goes up. See `references/ralph-loop-v2.md` for the full strategy.
